"""Fine-tune the active zero-shot NLI model on IPBES-derived training data.

Standalone script, not run on RunPod -- meant to run entirely LOCALLY. The
training set here is small (low hundreds of rows), so this is not the
compute-scale case RunPod's GPU pool exists for; RunPod is only actually
needed later, for serving the result at inference scale.

Runs on CPU, not Apple Silicon MPS, despite MPS being available on this
machine -- TrainingArguments(use_cpu=True) below forces this deliberately.
Confirmed directly (isolated A/B, same model/data/max_length=512/
batch_size=16) that MPS silently produces grad_norm == 0.0 at this real
sequence length + batch size while CPU does not, and CPU was also the
faster of the two in that same test -- see the comment on `training_args`
below.

The training data itself IS wired into _targets.R (`nli_training_data`,
`R/build_nli_training_data.R`) and lives in
output/nli_training/granularity=<g>/nli_config=<cfg>/assessment=<id>/ --
the same hive-partitioning scheme output/nli_scores_evidence and friends
already use. This script reads that parquet dataset directly (pooling
across every partition currently on disk by default; see FILTERS below to
restrict to one), not a separate CSV export. See TD_NLI_training.qmd for
the full training-data design.

Usage (from the repo root, so its relative output/ paths resolve):
    python scripts/training/train_nli.py [--nli-config <name>] [--downsample-seed <int>]

--nli-config restricts training to that one nli_config partition (same as
setting FILTERS = {"nli_config": "<name>"} below) -- this is how
R/build_nli_finetuned_model.R invokes this script when a config's own
train: true is set in input/config.yaml, so the fine-tuned model produced
is unambiguously tied to one specific (granularity, nli_config) combination
rather than silently pooling whatever else happens to be on disk.

--downsample-seed, if given, caps every label class down to the smallest
class's count (seeded, reproducible) before training -- for class balance
once multiple assessments are pooled and one (e.g. a keypaper-only
assessment) contributes far more SUPPORTS/NOT_ENOUGH_INFO than REFUTES.
Omit (the default, and every existing config's own downsample_seed: null)
to train on the full filtered set as-is.

Writes run_results.json into its own output_dir (see build_run_id() below)
with the classification_report, label/keypaper composition, and the full
per-step loss/eval_loss history -- read by
R/build_nli_finetuned_model_qa_data.R for the QA report. Also prints a
final "RUN_DIR:<path>" line as the last line of output, which is how the R
wrapper recovers the exact (timestamped) output_dir this run created.

Before running for real, smoke-test that the model loads at all:
    python -c "
    from transformers import AutoModelForSequenceClassification
    AutoModelForSequenceClassification.from_pretrained(
        'MoritzLaurer/bge-m3-zeroshot-v2.0-c', num_labels=3,
        ignore_mismatched_sizes=True)
    "
bge-m3-zeroshot-v2.0-c's fine-tuning API has NOT been verified against its
model card -- this script assumes the same generic
AutoModelForSequenceClassification(ignore_mismatched_sizes=True) recipe that
worked for the previously-active deberta-v3-large-zeroshot-v2.0 transfers
unchanged. If the smoke test above fails, check the model card for a
different required class or head-reinitialization approach before assuming
anything below needs to change.
"""

import argparse
import json
import os
from datetime import datetime

import pandas as pd
import torch
from datasets import Dataset
from sklearn.metrics import classification_report
from transformers import (
    AutoModelForSequenceClassification,
    AutoTokenizer,
    Trainer,
    TrainingArguments,
)

MODEL_ID = "MoritzLaurer/bge-m3-zeroshot-v2.0-c"
DATA_PATH = "output/nli_training"
# NOT output/nli_training/finetuned -- that would nest the saved model INSIDE
# the same root DATA_PATH's pd.read_parquet() recursively scans, and a
# checkpoint's config.json/*.safetensors are not parquet ("Could not read
# schema from .../config.json ... Parquet magic bytes not found"), breaking
# every future read of the training data once a model has been saved once.
# Confirmed directly (this exact error) after the first real training run.
#
# Each run gets its own nested, hive-style, content-described path under
# this root (see build_run_id() below) rather than a fixed path -- confirmed
# directly that trainer.save_model()/tokenizer.save_pretrained() silently
# overwrite whatever's already at a given path with no versioning of their
# own, and that re-running on a DIFFERENT-sized dataset produces different
# checkpoint-<step> numbers, leaving the old ones as orphaned, never-cleaned
# leftovers alongside the new ones -- a fixed shared path made both of these
# silent data-loss/clutter risks. e.g.
# output/nli_training_finetuned/KP=GA1_IAS/citing=GA1/downsample_seed=none/date=2026.09.01_14_23/.
# The very first (GA1-only, pre-downsample_seed, flat-named) run was moved
# by hand into output/nli_training_finetuned/20260901_092416__KP_GA1__CITING_GA1/
# before this hierarchical scheme existed.
OUTPUT_ROOT = "output/nli_training_finetuned"
LABEL2ID = {"SUPPORTS": 0, "REFUTES": 1, "NOT_ENOUGH_INFO": 2}
ID2LABEL = {v: k for k, v in LABEL2ID.items()}

# Restrict to one partition if you want a single granularity/nli_config
# combination rather than pooling across everything currently on disk --
# e.g. FILTERS = {"granularity": "atomic_bm"}. Empty dict = no filter, use
# every partition found under DATA_PATH.
FILTERS: dict = {}

# "full" (title + abstract, matching what the deployed pipeline actually
# shows the model at inference time) vs "quote" (just the verbatim quote the
# LLM cited -- the minimal grounded text, avoids noise from an otherwise
# off-topic abstract, but doesn't match the real inference-time premise
# shape). Not settled which is better -- TD_NLI_training.qmd flags this as
# worth comparing empirically rather than assuming one is correct. Change
# this to "quote" to try the other variant; NOT_ENOUGH_INFO rows have no
# quote by construction, so "quote" mode falls back to title+abstract for
# those regardless.
PREMISE_MODE = "full"


def _json_default(obj):
    """json.dump default= hook: trainer.state.log_history/best_metric can
    contain numpy float32/float64 scalars (from torch tensor .item() calls
    upstream), which json.dumps() cannot serialise natively -- confirmed
    directly ("Object of type float32 is not JSON serializable")."""
    import numpy as np

    if isinstance(obj, np.floating):
        return float(obj)
    if isinstance(obj, np.integer):
        return int(obj)
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON serializable")


def build_run_id(df, downsample_seed):
    """A real, nested hive-style path describing what actually went into this
    run -- e.g. "KP=GA1_IAS/citing=GA1/downsample_seed=none/date=2026.09.01_14_23"
    -- rather than one flat directory name. Computed from `df` AFTER filters
    (and, for KP=/citing=, before downsampling) are applied, so it reflects
    exactly what this run actually trained on, not just what's on disk in
    general. `downsample_seed` is its own segment (not folded into KP=/
    citing=) since it's an orthogonal choice about how those same rows get
    used, not about which rows exist -- "none" (not the Python None/empty
    string) keeps it a valid, greppable hive segment either way.
    """
    kp_assessments = sorted(df.loc[df["keypaper"], "assessment"].unique())
    citing_assessments = sorted(df.loc[~df["keypaper"], "assessment"].unique())
    kp_tag = "_".join(kp_assessments) if kp_assessments else "NONE"
    citing_tag = "_".join(citing_assessments) if citing_assessments else "NONE"
    seed_tag = "none" if downsample_seed is None else str(downsample_seed)
    date_tag = datetime.now().strftime("%Y.%m.%d_%H_%M")
    return os.path.join(
        f"KP={kp_tag}", f"citing={citing_tag}",
        f"downsample_seed={seed_tag}", f"date={date_tag}",
    )


def build_premise(row):
    if PREMISE_MODE == "quote" and isinstance(row.get("quote"), str) and row["quote"].strip():
        return row["quote"]
    title = row["title"] if isinstance(row.get("title"), str) else ""
    abstract = row["abstract"] if isinstance(row.get("abstract"), str) else ""
    return f"{title}. {abstract}" if abstract else title


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--nli-config", default=None,
        help='Restrict training to this one nli_config partition (adds {"nli_config": value} to FILTERS).',
    )
    p.add_argument(
        "--downsample-seed", type=int, default=None,
        help=(
            "If set, downsample every label class down to the smallest "
            "class's count (seeded, reproducible) before training, for "
            "class balance. Omit for no downsampling (train on the full "
            "filtered set as-is)."
        ),
    )
    return p.parse_args()


def main():
    args = parse_args()
    filters = dict(FILTERS)
    if args.nli_config:
        filters["nli_config"] = args.nli_config

    # pandas' pyarrow engine auto-discovers the granularity=/nli_config=/
    # assessment=/keypaper= hive partitions and exposes them as regular
    # columns. keypaper comes back as the literal partition-directory string
    # "true"/"false" (category dtype), not a native bool -- confirmed
    # directly -- so it's converted here to let FILTERS = {"keypaper": True}
    # work the way it reads.
    df = pd.read_parquet(DATA_PATH)
    df["keypaper"] = df["keypaper"].astype(str).map({"true": True, "false": False})
    for col, val in filters.items():
        df = df[df[col] == val]

    # KP=/citing= describe which rows EXIST; downsample_seed= (below) is an
    # orthogonal choice about how they get USED -- compute the run_id from
    # the pre-downsampling df so the KP=/citing= segments still show
    # everything that was actually available, not just what training ends
    # up seeing after balancing.
    output_dir = os.path.join(OUTPUT_ROOT, build_run_id(df, args.downsample_seed))
    # Explicit, even though Trainer's own checkpointing would create this
    # nested path on demand -- run_results.json (written at the very end)
    # needs it to exist regardless of whether training reaches a checkpoint.
    os.makedirs(output_dir, exist_ok=True)
    print(f"[train_nli] output_dir = {output_dir}")

    print(f"[train_nli] {len(df)} rows before downsampling, premise mode = {PREMISE_MODE!r}, filters = {filters!r}")
    print(df[["granularity", "nli_config", "assessment"]].drop_duplicates())
    print(df["label"].value_counts())
    print(df["keypaper"].value_counts())

    if args.downsample_seed is not None:
        # Every label class capped at the smallest class's count -- real
        # need once multiple assessments are pooled and a keypaper-only one
        # contributes far more SUPPORTS/NOT_ENOUGH_INFO than REFUTES (a
        # keypaper chain rarely produces REFUTES at all), which would
        # otherwise bias an unweighted cross-entropy loss toward the
        # majority classes -- confirmed directly this session as a real,
        # not just theoretical, risk (872/181/872 on the real GA1+IAS pool).
        # GroupBy.sample(), not .apply(lambda g: g.sample(...)) -- confirmed
        # directly that on this installed pandas (3.0.5), .groupby("label")
        # .apply() DROPS the "label" column from what it hands to the
        # lambda by default (a real pandas 2.2+ behavior change), silently
        # producing a downsampled frame with no label column at all.
        # GroupBy.sample() doesn't have this problem -- it's a groupby
        # method in its own right, not a generic apply().
        min_count = df["label"].value_counts().min()
        df = df.groupby("label", group_keys=False).sample(
            n=min_count, random_state=args.downsample_seed
        ).reset_index(drop=True)
        print(f"[train_nli] downsampled to {min_count} rows/class (seed={args.downsample_seed}), {len(df)} rows total")
        print(df["label"].value_counts())

    df["premise"] = df.apply(build_premise, axis=1)
    df["label_id"] = df["label"].map(LABEL2ID)

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)

    def tokenize(batch):
        return tokenizer(
            batch["premise"],
            batch["hypothesis"],
            truncation=True,
            max_length=512,
            padding="max_length",
        )

    dataset = Dataset.from_pandas(df[["premise", "hypothesis", "label_id"]])
    dataset = dataset.rename_column("label_id", "labels")
    dataset = dataset.map(tokenize, batched=True)
    dataset = dataset.train_test_split(test_size=0.15, seed=42)

    model = AutoModelForSequenceClassification.from_pretrained(
        MODEL_ID,
        num_labels=3,
        id2label=ID2LABEL,
        label2id=LABEL2ID,
        ignore_mismatched_sizes=True,  # classifier head is re-initialised
    )

    # No CUDA on this machine -- fp16 stays off (torch.cuda.is_available()
    # is False). use_cpu=True forces CPU rather than letting Trainer pick up
    # MPS automatically: confirmed directly (isolated A/B on this exact
    # model/data/max_length=512/batch_size=16) that MPS silently produces
    # grad_norm == 0.0 (a hard zero, not just small) at this real sequence
    # length + batch size, while CPU gives a normal, non-zero grad_norm on
    # the identical batch -- this is what produced the first run's frozen
    # eval_loss (~ln(3), i.e. the model never moved from its random head
    # init) and near-chance classification_report. CPU was also faster in
    # that same A/B (19s/step vs MPS's 58s/step), so this isn't even a
    # speed/correctness tradeoff here -- MPS is worse on both counts for
    # this workload. Revisit if a future torch/MPS release fixes this.
    # Named training_args, not args -- `args` is already this function's
    # parsed CLI namespace (args.downsample_seed etc.), read again further
    # below when building run_results.json; reusing the name would silently
    # shadow it.
    training_args = TrainingArguments(
        output_dir=output_dir,
        use_cpu=True,
        num_train_epochs=3,
        per_device_train_batch_size=16,
        per_device_eval_batch_size=32,
        eval_strategy="epoch",
        save_strategy="epoch",
        load_best_model_at_end=True,
        metric_for_best_model="eval_loss",
        fp16=torch.cuda.is_available(),
        logging_steps=20,
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=dataset["train"],
        eval_dataset=dataset["test"],
    )

    trainer.train()

    best_dir = f"{output_dir}/best"
    trainer.save_model(best_dir)
    tokenizer.save_pretrained(best_dir)
    print(f"[train_nli] saved fine-tuned model to {best_dir}")

    preds = trainer.predict(dataset["test"])
    pred_labels = preds.predictions.argmax(axis=1)
    true_labels = dataset["test"]["labels"]
    report_text = classification_report(
        true_labels, pred_labels, target_names=list(LABEL2ID.keys())
    )
    report_dict = classification_report(
        true_labels, pred_labels, target_names=list(LABEL2ID.keys()), output_dict=True
    )
    print(report_text)

    # Persisted for R/build_nli_finetuned_model_qa_data.R -- everything the
    # QA report needs, in one place, rather than re-deriving it from
    # checkpoint-*/trainer_state.json (which only has the loss curve, not
    # the classification_report) or re-parsing console output (fragile --
    # confirmed directly this session that tqdm's carriage-return animation
    # mangles plain print() lines when output is captured non-interactively).
    results = {
        "run_id": os.path.basename(output_dir),
        "timestamp": datetime.now().isoformat(),
        "model_id": MODEL_ID,
        "premise_mode": PREMISE_MODE,
        "filters": filters,
        "downsample_seed": args.downsample_seed,
        "n_rows_total": len(df),
        "n_rows_train": len(dataset["train"]),
        "n_rows_eval": len(dataset["test"]),
        # .value_counts() values are numpy int64, not JSON-serialisable --
        # confirmed directly, cast to plain int explicitly rather than
        # relying on json.dump's default encoder.
        "label_counts": {str(k): int(v) for k, v in df["label"].value_counts().items()},
        "keypaper_counts": {str(k): int(v) for k, v in df["keypaper"].value_counts().items()},
        "assessments": sorted(df["assessment"].unique().tolist()),
        "granularity": sorted(df["granularity"].unique().tolist()),
        "nli_config": sorted(df["nli_config"].unique().tolist()),
        "classification_report": report_dict,
        "log_history": trainer.state.log_history,
        "best_metric": trainer.state.best_metric,
        "best_model_checkpoint": trainer.state.best_model_checkpoint,
    }
    with open(os.path.join(output_dir, "run_results.json"), "w") as f:
        json.dump(results, f, indent=2, default=_json_default)

    # Sentinel file, not stdout-parsing -- R/build_nli_finetuned_model.R runs
    # this script with stdout streamed live to the console (so a ~25min run
    # isn't silent), which means R never captures stdout as a string to grep
    # in the first place. This fixed-path file is what it reads afterward to
    # recover this run's own timestamped output_dir.
    with open(os.path.join(OUTPUT_ROOT, ".last_run_dir.txt"), "w") as f:
        f.write(output_dir)
    print(f"[train_nli] RUN_DIR:{output_dir}")


if __name__ == "__main__":
    main()
