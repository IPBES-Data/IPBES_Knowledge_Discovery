"""Fine-tune the active zero-shot NLI model on IPBES-derived training data.

Standalone script, not run on RunPod -- meant to run entirely LOCALLY (CPU or
Apple Silicon MPS). The training set here is small (low hundreds of rows),
so this is not the compute-scale case RunPod's GPU pool exists for; RunPod
is only actually needed later, for serving the result at inference scale.

The training data itself IS wired into _targets.R (`nli_training_data`,
`R/build_nli_training_data.R`) and lives in
output/nli_training/granularity=<g>/nli_config=<cfg>/assessment=<id>/ --
the same hive-partitioning scheme output/nli_scores_evidence and friends
already use. This script reads that parquet dataset directly (pooling
across every partition currently on disk by default; see FILTERS below to
restrict to one), not a separate CSV export. See TD_NLI_training.qmd for
the full training-data design.

Usage (from the repo root, so its relative output/ paths resolve):
    python scripts/training/train_nli.py

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
OUTPUT_DIR = "output/nli_training/finetuned"
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


def build_premise(row):
    if PREMISE_MODE == "quote" and isinstance(row.get("quote"), str) and row["quote"].strip():
        return row["quote"]
    title = row["title"] if isinstance(row.get("title"), str) else ""
    abstract = row["abstract"] if isinstance(row.get("abstract"), str) else ""
    return f"{title}. {abstract}" if abstract else title


def main():
    # pandas' pyarrow engine auto-discovers the granularity=/nli_config=/
    # assessment= hive partitions and exposes them as regular columns.
    df = pd.read_parquet(DATA_PATH)
    for col, val in FILTERS.items():
        df = df[df[col] == val]
    df["premise"] = df.apply(build_premise, axis=1)
    df["label_id"] = df["label"].map(LABEL2ID)

    print(f"[train_nli] {len(df)} rows, premise mode = {PREMISE_MODE!r}, filters = {FILTERS!r}")
    print(df[["granularity", "nli_config", "assessment"]].drop_duplicates())
    print(df["label"].value_counts())

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
    # is False), and Trainer picks up MPS/CPU automatically via device_map
    # defaults. Nothing else in this loop is CUDA-specific.
    args = TrainingArguments(
        output_dir=OUTPUT_DIR,
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
        args=args,
        train_dataset=dataset["train"],
        eval_dataset=dataset["test"],
    )

    trainer.train()

    best_dir = f"{OUTPUT_DIR}/best"
    trainer.save_model(best_dir)
    tokenizer.save_pretrained(best_dir)
    print(f"[train_nli] saved fine-tuned model to {best_dir}")

    preds = trainer.predict(dataset["test"])
    pred_labels = preds.predictions.argmax(axis=1)
    true_labels = dataset["test"]["labels"]
    print(
        classification_report(
            true_labels, pred_labels, target_names=list(LABEL2ID.keys())
        )
    )


if __name__ == "__main__":
    main()
