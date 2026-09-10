# Git LFS: mechanics, hosting, and a triage strategy for large output trees

Status: **reference + not-yet-decided strategy, nothing configured.** No `git
lfs track` has been run, `.gitattributes` is still the default
`* text=auto`, and `output/*` is currently entirely gitignored except
`output/reports/` and `output/README.md` (see `.gitignore:60-63`) — so
whatever gets decided here is a from-scratch tracking decision, not a
conversion of already-committed history. `git lfs migrate import` (§9 below)
is therefore **not needed** for this repo; a plain `git lfs track` +
`git add` is enough once a decision is made.

Originally written as project-agnostic reference notes from a chat about LFS
mechanics; the "worked example" in §7 turned out to be *this* repo's own
`output/` tree (measured live during the snowball-unification work, see the
conversation this was pulled from). The section below applies those findings
here specifically; §1 onward is the unedited reference material.

## Applied to this repo

**Verified `.pt` vs `.safetensors` hypothesis (§7's "probably the same
models twice" guess) — confirmed, with a repo-specific detail the guess
didn't have:**

```
output/nli_training_finetuned/KP=GA1_IAS/citing=GA1/downsample_seed=13/
  date=2026.09.01_11_30/        ← training run 1
    checkpoint-29/  optimizer.pt (4.23G)  model.safetensors (2.12G)  scheduler.pt  rng_state.pth  trainer_state.json  config.json
    checkpoint-58/  optimizer.pt (4.23G)  model.safetensors (2.12G)  ...
    checkpoint-87/  optimizer.pt (4.23G)  model.safetensors (2.12G)  ...
    best/                       model.safetensors (2.12G)  tokenizer.json  ...  (no optimizer.pt)
  date=2026.09.01_13_20/        ← training run 2 (same seed, same KP/citing config, ~2h later)
    checkpoint-89/ 178/ 267/    (same shape as run 1)
    best/
```

- Every `optimizer.pt` is **exactly** 4.23 GB, every `model.safetensors` at
  the same checkpoint is **exactly** 2.12 GB — a clean ~2.0× ratio, consistent
  with AdamW's two per-parameter moment buffers stored separately from the
  weights themselves (the doc guessed "checkpoint ≈ 3× exported weights"
  assuming the moments are *added onto* the weights; here they're a fully
  separate file at ~2× the weights alone — same conclusion, different
  accounting).
- `optimizer.pt`/`scheduler.pt`/`rng_state.pth` are **pure training-resume
  state** — meaningless without the `Trainer` that produced them, unneeded
  for inference, and only useful if you specifically want to resume an
  interrupted `checkpoint-NN` mid-epoch. `best/` has no `optimizer.pt` at
  all, which is itself the tell: it's the one checkpoint meant to be *used*,
  not resumed from.
- **There are two full training runs** (`11_30` and `13_20`, same
  hyperparameters, ~2h apart) sitting side by side. Before doing anything
  LFS-related, worth checking `run_results.json` in each to see whether
  `13_20` superseded `11_30` (a restart after a bad run, a hyperparameter
  tweak) — if so, the entire `11_30/` subtree (≈21 GB: 3× optimizer.pt +
  3× checkpoint model.safetensors + 1× best/model.safetensors) may be
  deletable outright, independent of any LFS decision. That alone would cut
  `output/nli_training_finetuned/` from 42 GB to ~21 GB before even applying
  §5's `*.pt`/checkpoint-vs-best triage.

**Relation to the parquet over-partitioning discussion earlier in this
session:** §7's finding that 2,265 of 3,818 parquet files are under 100 KB
matches exactly what was traced to `output/nli_scores_evidence_keypaper`
(1,276 files, avg 6 KB, partitioned down to `claim_id` level) and
`output/nli_ready_evidence_keypaper` (343 files, avg 25 KB). §7's
"coalesce into partitioned datasets at ~128-512 MB per file" recommendation
is the *storage-layer* version of that discussion; the *resumability-safe*
way to actually do it (without breaking `score_one_claim()`'s per-claim skip
logic or duplicating data) is the tmp-scratch-then-single-compaction design
worked out separately — not repeated here, but the two should be implemented
together rather than this doc's generic "coalesce" advice being done
naively (a naive coalesce would break the per-claim_id resumability check
`score_one_claim.R` depends on).

**`output/snowball/` is the one dataset already in good shape** — the
snowball-unification refactor (this session) took it from many small
per-(km,bm) files to 21 large files (6 MB – 4.43 GB, avg 600 MB), which is
exactly the LFS-friendly shape §5 recommends. Its outlier — GA1's
`nodes/relation=citing` at 4.43 GB — is only a problem for GitHub-hosted
LFS (§3's 2 GB/4 GB/5 GB caps); with self-hosted LFS (the plan discussed for
this repo) it's a non-issue.

### Concrete next steps (not yet done)

**Decided so far:** self-hosted backend, `rudolfs` the leading candidate but
not finalised. **All parquet databases** go into LFS. Parquet consolidation
was split off into its own piece of work and is **already implemented** (see
below), so the tree will be in the right shape before any LFS import.

- [ ] Decide the self-hosted LFS backend — see **Part II** below for the
      file-based (`lfs-folderstore`) option, which is probably the right
      *first* phase, and the decision points measured against this machine in
      "Backend decision, with this machine's actual numbers" immediately
      below.
- [ ] **Ordering constraint — do not stage parquet before the backend
      exists.** With no `lfs.url` set, LFS falls back to
      `<git-remote-url>/info/lfs`, i.e. GitHub, and
      `output/snowball/nodes/assessment=GA1/relation=citing/part-0.parquet`
      is **4.43 GB** — over both the 2 GB Free/Pro and 4 GB Team per-file cap
      (VA's is 2.45 GB; 21.33 GB total also exceeds the 10 GiB Free/Pro
      allowance). Because LFS uploads run in the **pre-push hook**, that
      failure aborts the *entire* push, ordinary non-LFS commits included.
- [ ] Budget the local disk: the LFS cache is a full second copy, so tracking
      ~21 GB of parquet costs roughly **42 GB** on top of the existing 65 GB
      `output/` tree.
- [ ] Safe to prepare any time (backend-agnostic): add
      `*.parquet filter=lfs diff=lfs merge=lfs -text` to `.gitattributes`
      (inert until files are actually added), and work out the replacement
      `.gitignore` recipe — `output/**`, then `!output/**/`,
      `!output/**/*.parquet`, `!output/README.md`, `!output/reports/**`,
      while still ignoring `output/llm_verification/raw*/` (215k JSON cache),
      `output/nli_training_finetuned/` (42 GB), `*.html`, `*.rds`. **Verify
      with `git check-ignore -v` / `git status --ignored`** rather than
      assuming: `**` interacting with directory un-ignoring is easy to get
      subtly wrong.
- [ ] Then, once the backend exists: set `git config lfs.url` in **untracked
      `.git/config`** (never a committed `.lfsconfig` — a versioned endpoint
      means anyone checking out an old commit gets an unreachable URL), flip
      the `.gitignore`, `git add`, push. No history rewrite is needed:
      nothing under `output/` has ever been committed, so
      `git lfs migrate import` does not apply.
- [ ] Check `run_results.json` in both `nli_training_finetuned` run
      directories to see if `date=2026.09.01_11_30` is superseded by
      `date=2026.09.01_13_20`; if so, delete the superseded run's directory
      outright (≈21 GB, and no LFS needed for data you're not keeping).
- [ ] Re-verify all pricing/quota figures in §3 before relying on them
      (the doc's own caveat — mid-2026 figures) — moot if going fully
      self-hosted, but relevant if any forge-hosted endpoint is still on the
      table.

### Backend decision, with this machine's actual numbers

Measured 2026-09-10, so the Part II trade-offs can be judged against reality
rather than in the abstract:

- **`git-lfs` 3.8.0 is already installed**; `cargo` 1.92.0 is present (so
  `cargo install rudolfs` is available whenever wanted).
  **`lfs-folderstore` is not installed** and has no Homebrew formula — it
  would have to be built from source, and Part II's own caveat about it being
  lightly maintained applies.
- **The endpoint currently resolves to GitHub** —
  `git lfs env` reports
  `Endpoint=https://github.com/IPBES-Data/IPBES_BM_Fact_Checker.git/info/lfs`.
  So the "don't stage parquet before a backend exists" warning above is live,
  not theoretical: with no `lfs.url` set, a push goes straight at GitHub and
  its 2 GB per-file cap.
- **The internal disk is nearly full: 80 GiB free of 926 GiB (92% used).**
  A folderstore on the internal disk would mean ~21 GB store **plus** this
  repo's own `.git/lfs/objects` (~21 GB) = ~42 GB, more than half the
  remaining headroom — on the same volume that already holds the 65 GB
  `output/` tree and needs room for snowball temp workspaces (18 GB observed
  today). **The store should live on the external array, not the internal
  disk.**
- **The external array has 850 GiB free** (one APFS container shared by
  `/Volumes/GitHub`, `/Volumes/Archive`, `/Volumes/openalex`,
  `/Volumes/rkrug_external`, `/Volumes/IPBES_Backup`, …). Plenty of room, and
  Part II's shared-store-root argument has real force here: `/Volumes/openalex`
  and the sibling `Categorisation_Literature` project mean cross-project
  object dedup is worth something.
- **The deciding question, for this repo:** Part II frames it as *"will anyone
  other than you need to fetch these objects?"* The remote is
  **`IPBES-Data/IPBES_BM_Fact_Checker` — an organisation repo**, which points
  toward eventually yes. folderstore fundamentally cannot serve a second
  person (its config names a local binary path and requires the same volume
  mounted at the same path), so if collaborator access is ever wanted, that is
  the argument for going to `rudolfs` sooner rather than later. If the parquet
  is genuinely only versioned working state for one person, folderstore is
  much less to go wrong.
- **Durability is the open question**, not capacity: whether the external
  array is itself in a backup set. There are Time Machine volumes and an
  `/Volumes/IPBES_Backup`, but Part II §6 is emphatic — during the folderstore
  phase the store is the *only* copy of the content, and it is the
  highest-priority thing on that volume to back up.

### Parquet consolidation — implemented, pending verification

Done as a separate piece of work (it stands on its own: fewer, larger parquet
files are better for the pipeline regardless of LFS). Measured per-file
overhead was **~4.4 KB** — an 8-row `nli_scores_evidence_keypaper` file is
~4,700 B (~590 B/row) versus 42 B/row asymptotic in a 39,760-row file — so
most of that dataset was footer/schema/column-stats rather than data.
`claim_id` was verified to be used as a filter predicate **nowhere** in the
codebase, so dropping it as a partition level costs no query performance.

Projected effect: **3,818 → ~1,461 parquet files**, median 64.8 KB → ~1.4 MB,
total size essentially unchanged (~21.3 GB). Files under 100 KB drop from
2,265 to ~316.

Still to do before that lands: run the one-time migration
(`R/migrate_nli_scores_consolidate.R`, `dry_run = TRUE` first) and the
cutover verification — both deliberately deferred until the in-flight
`tar_make("snowball_parquet")` finishes.

---

## 1. How LFS stores things

Three distinct locations:

| Location | Contents |
|---|---|
| Working tree | The real file, as normal |
| Git object database | A ~130-byte **pointer file** (committed) |
| Local LFS cache | `.git/lfs/objects/ab/cd/abcd…` — content-addressed by SHA-256 |
| Remote LFS server | The authoritative copy of every pushed version |

A pointer file contains only the OID and size — **no URL, no host, no path**:

```
version https://git-lfs.github.com/spec/v1
oid sha256:4d7a2146...e2393
size 41288203
```

The commit records *what* the content is, never *where* it lives. This is the
single most useful property of the design: you can relocate the object store
at any time without touching history.

### Versioning behaviour

Fully versioned — each commit references the OID of that version's content, so
checking out an old commit fetches the old object. But:

- **No delta compression.** Ten commits touching a 500 MB file = 5 GB on the
  server. Push a 500 MB file, change one byte, push again — 1 GB stored.
- **No deduplication across objects.** Each version is stored whole.
- **Lazy fetching.** A clone pulls only objects needed for the checked-out
  commit, not all history.
- **Asymmetric pruning.** `git lfs prune` cleans the local cache easily.
  Removing objects from the *server* is painful — on GitHub it effectively
  means rewriting history and contacting support.

### Where the objects actually are

Contrary to intuition, the **remote holds every version**; locally you
normally have only a subset.

```bash
git lfs env                # show the resolved endpoint
git lfs ls-files           # '*' = object present locally, '-' = pointer only
git lfs fetch --all        # pull every version of every object
git lfs prune              # drop local objects not needed by recent commits
git lfs fsck               # verify integrity
```

The one case where a version exists *only* locally is before you push.
`git lfs push` runs via the pre-push hook — if `git lfs install` was never run
in a clone, you can push pointers referencing objects nobody can resolve.

---

## 2. Where the LFS server lives

Endpoint discovery, in order of precedence:

1. **Default:** `<git-remote-url>/info/lfs`
2. **Override:** `lfs.url` in a committed `.lfsconfig`, or in untracked
   `.git/config`

So the repo can live on GitHub while the bytes live anywhere.

### Options, roughly ascending in robustness

**Folder as a store (no server).** `lfs-folderstore` is a custom transfer
agent that copies objects to a directory — including a mounted network share.

```ini
[lfs "customtransfer.lfs-folder"]
  path = /usr/local/bin/lfs-folderstore
  args = "/Volumes/DAS/git-lfs-store"
[lfs]
  standalonetransferagent = lfs-folder
```

No daemon, no auth. Every machine needs the agent and the share at the same
path; `git lfs lock` doesn't work. Lightly maintained — verify it builds.

**SSH transfer.** Git LFS 3.0+ can move objects over plain SSH via a
`git-lfs-transfer` helper installed on the remote. No HTTP service needed, but
the helper isn't part of the git-lfs package.

**Self-hosted server.**
- `rudolfs` — Rust, single binary or Docker (<10 MB image). S3 or local-disk
  backend, plus a configurable local disk cache in front of S3. Optional
  xchacha20 encryption at rest. **No client authentication** — needs Tailscale
  or an authenticating reverse proxy. If the encryption key changes or is
  lost, all objects become garbage.
- `giftless` — Python/WSGI, pluggable storage (local FS, S3, GCS, Azure Blob),
  JWT auth built in.

**Object storage behind a shim.** S3/R2/B2 alone cannot serve LFS — the client
needs a batch API (`POST /objects/batch`) returning per-object transfer URLs.
`git-lfs-s3-proxy` (twilligon / milkey-mouse) is a Cloudflare Worker/Pages
deployment that implements it and hands back presigned URLs. Downloads go
direct to the bucket, not through the Worker.

- Caveat: the S3 key goes in the endpoint URL. "Publicly cloneable" therefore
  means distributing a **read-only, rotatable** key. Never put a read-write
  key anywhere near a commit.

**A forge that hosts LFS natively.** Gitea/Forgejo have it built in (local
disk, MinIO/S3, or Azure Blob; each object stored once regardless of how many
branches reference it). GitLab self-managed has no storage limit.

**Another forge's endpoint while the repo stays on GitHub.** Works — create a
mirror project, point `lfs.url` at its `/info/lfs`. Three reasons to be
lukewarm: cloners' credentials are scoped to the *Git* host and may prompt or
fail; using host B purely as a blob store is what quotas exist to prevent;
and you inherit that host's quota walls anyway.

---

## 3. Costs (as of mid-2026 — verify before relying on these)

### GitHub

Free allowances are **per account**, not per repo:

| Plan | Storage | Bandwidth/month | Max file size |
|---|---|---|---|
| Free / Pro | 10 GiB | 10 GiB | 2 GB |
| Team | 250 GiB | 250 GiB | 4 GB |
| Enterprise Cloud | 250 GiB | 250 GiB | 5 GB |

Files above 5 GB are rejected outright. The old $5 data packs are gone;
billing is metered. Published third-party figures: **~$0.07/GiB-month
storage**, **~$0.0875/GiB downloaded**. GitHub's own docs don't print rates —
use <https://github.com/pricing/calculator?feature=lfs>.

Three traps:

1. **Storage counts every version ever pushed**, regardless of when.
2. **Bandwidth is billed per download, every time.** CI counts. A 50 GB
   checkout cloned 20×/month → 1 TB → ~$87/month on top of storage.
   Mitigate with `GIT_LFS_SKIP_SMUDGE=1` in jobs that don't need the files.
3. **Deleting objects mid-month doesn't recalculate** that month's storage.

Without a payment method: exceeding storage → you can still clone (pointers
only) but can't push; exceeding bandwidth → LFS disabled until next month.
Usage always bills to the **repository owner**, including from forks.

### Cloudflare R2

Free tier ~10 GB storage, **unlimited egress**, 1M Class A (write) and 10M
Class B (read) operations per month. Beyond that, **~$0.015/GB-month**.

Free egress is the decisive difference: it removes the CI-clone bill entirely,
which for repeatedly-fetched artifacts is usually the dominant cost. R2 also
has no per-file cap in the range that matters here.

Note the operation counts if you have many objects — LFS does one operation
per object, so a full push of 225k objects burns 225k Class A ops.

### Others

- **GitLab.com** — repo + LFS share one quota: 10 GiB per project on Free,
  500 GiB per project on Premium/Ultimate. Over the limit the project goes
  read-only rather than billing you. Self-managed: no limit.
- **Azure DevOps** — LFS storage free, no published cap, but only for repos
  hosted there. No SSH for LFS-tracked repos; 1-hour upload limit.
- **Self-hosted** — no per-GB fees, but you own durability (see §6).
- **Backblaze B2 / Wasabi / GCS / DO Spaces** — all work behind the S3 proxy;
  egress isn't free but is cheap.

---

## 4. Relocating the object store

Because pointers carry no location, migration is a pure copy. No history
rewrite, no new commits, all historical versions keep resolving.

```bash
git lfs fetch --all                            # 1. get every version locally
git lfs fsck                                   #    verify before relying on it
git config lfs.url https://new-endpoint/...    # 2. repoint
git lfs push --all origin                      # 3. upload everything
```

`git lfs push --all` sends all objects referenced by all refs — but only those
present in the local cache, hence step 1. If the source is a folder store,
copy it into `.git/lfs/objects/` (the `ab/cd/abcd…` layout) first.

### Two planning points

**Don't commit `.lfsconfig` with a private URL.** It's versioned like any
file, so anyone checking out an *old* commit gets the old endpoint back and
fails against a host they can't reach. Keep private endpoints in untracked
`.git/config`. Then the private phase leaves no trace in history.

**The bill is deferred, not avoided.** Pushing to a metered host later uploads
every version you accumulated, and you pay for the whole history at once.
Decide *before* the local phase whether all those versions are ones you'd want
to publish — local pruning is easy, remote pruning is not.

### Who gets the data

- **Private/local store:** only you. A stranger cloning from GitHub gets
  commits fine, then LFS fails — pointer files or a missing-object error.
- **Public endpoint:** transparent. `git clone` resolves via the smudge
  filter; nobody needs to know LFS is involved.

---

## 5. Deciding what belongs in LFS

### The two-line test

1. **Would I lose anything I couldn't rebuild?** If it regenerates
   deterministically from something already versioned, gitignore it.
2. **Does it delta?** Internally-compressed formats (parquet, safetensors,
   most images/video) can't be delta-compressed by Git — that's LFS's job
   description. Plain text deltas well and belongs in ordinary Git.

Content that fails *both* (large, undeltable, regenerable) belongs in neither:
use content-addressed backup or a data repository instead.

### Tracking mechanics

```bash
git lfs track "*.parquet"     # quote it, or the shell globs
git lfs track "output/**"     # ** matches at any depth
```

This writes to `.gitattributes`, which you commit:

```gitattributes
output/**        filter=lfs diff=lfs merge=lfs -text
output/README.md !filter !diff !merge text          # later lines override
```

- **`.gitattributes` matches paths, not sizes.** Track by extension —
  stable across rebuilds — rather than generating patterns from
  `find -size +1M`, which isn't.
- **Order matters.** Files already committed as ordinary blobs stay that way;
  the attribute only applies going forward. To convert history:
  `git lfs migrate import --include="*.parquet"` (rewrites commits —
  coordinate if shared). For files present but uncommitted:
  `git add --renormalize .`
- **Verify** with `git lfs ls-files`.

### LFS is wrong for many small files

Each object is a separate batch-API entry and a separate transfer. A few
hundred large files is the sweet spot; hundreds of thousands of small ones
makes clones take hours. At the default batch size of 100 and 8 concurrent
transfers, 225k objects means ~2,250 batch calls and 225k individual fetches.

An LFS pointer is ~130 bytes. Files averaging a few hundred bytes gain
nothing from being replaced by one.

---

## 6. Durability warning for self-hosted stores

Once `lfs.url` points at your own disk, the Git repo contains **pointers to
bytes that exist in exactly one place**. Lose the store and history is
unrecoverable: commits remain, content is gone, clones error on missing
objects.

- A single JBOD volume is not a backup.
- Verify the object store is genuinely in the backup set, not merely appearing
  to be covered in a UI.
- Periodically `git lfs fsck` against a fresh clone to confirm objects
  actually resolve.
- Three copies, one offsite.

---

## 7. Worked example: a 64 GB / 225k-file `output/` tree

### Size distribution

| Bucket | Files | Size |
|---|---|---|
| <1 KB | 215,768 | 69.9 MB |
| 1–10 KB | 1,360 | 7.3 MB |
| 10–100 KB | 1,213 | 53.3 MB |
| 100 KB–1 MB | 929 | 254.4 MB |
| 1–10 MB | 558 | 2,130.7 MB |
| 10–100 MB | 189 | 4,983.4 MB |
| 100 MB–1 GB | 24 | 6,106.4 MB |
| >1 GB | 17 | 52,209.8 MB |

Cumulative coverage by threshold:

| Threshold | Files | Bytes captured |
|---|---|---|
| >1 GB | 17 | 79.3% |
| >100 MB | 41 | 88.6% |
| >10 MB | 230 | 96.2% |
| >1 MB | 788 | 99.4% |
| everything | 225,313 | 100% |

**95.8% of items are 0.1% of bytes.** Thresholding at 1 MB gives 99.4% of the
volume in 788 objects — a 285× reduction in object count for 0.6% of data.

### By extension — the decisive view

| Extension | Files | Size | Nature |
|---|---|---|---|
| `.json` | 215,732 | 102 MB | resumable cache |
| `.parquet` | 3,818 | 21.33 GB | the actual data tables |
| `.pt` | 12 | 25.38 GB | PyTorch checkpoints (6 weights + 6 configs) |
| `.safetensors` | 8 | 16.92 GB | exported model weights |
| `.rds` | 48 | 168 MB | cached R data |
| `.html` | 59 | 324 MB | rendered reports/widgets |

### Findings

**The 215,732 JSON files are a cache.** Caches are never versioned —
gitignore, and 95.7% of the file count disappears. Note also: 215k files ×
4 KB minimum block ≈ 880 MB of filesystem overhead to store 102 MB of
content. Consolidating to one JSONL/Parquet helps the pipeline, but isn't
needed for Git.

**`.pt` vs `.safetensors` are probably the same models twice.** 6 weight files
averaging ~4.2 GB vs 8 averaging ~2.1 GB is the signature of `.pt`
checkpoints carrying optimizer state (Adam keeps two moments per parameter,
so a full checkpoint ≈ 3× exported weights). If so, that 25.38 GB is
resume-only state for finished runs — 40% of the tree, with no downstream
consumer. If they're genuine duplicate serialisations, keep safetensors (no
pickle risk, mmap-able, faster load). *(See "Applied to this repo" above —
confirmed: it's training-resume state, not duplicate exports, and it's
specifically `optimizer.pt`/`scheduler.pt`/`rng_state.pth` at ~2× the
corresponding `model.safetensors`.)*

**Parquet is over-sharded.** 2,265 of 3,818 files are under 100 KB. Parquet
has fixed per-file overhead (footer, schema, row-group metadata) and loses
most of its columnar advantage at that size — readers spend more time opening
files than reading. Coalesce into partitioned datasets at ~128–512 MB per
file.

**HTML widgets don't delta** despite being nominally text — data is embedded
as base64 or inline JSON, so each rebuild is a fresh copy. And they regenerate
from parquet + Rmd/Qmd. Gitignore, treat the source as the artifact. Exception:
a rendered report circulated to reviewers where exact bytes matter — pin that
one file, ideally as a release asset.

**Watch for outliers as diagnostics.** In a cache where 215,699 of 215,731
entries are <1 KB, two files at 10–100 MB indicate an error dump, an
appending retry loop, or a response returned as a whole document instead of a
record. A directory of 6 files totalling 0 B is failed-run residue.

### Resulting configuration

```gitignore
# caches — regenerable, never versioned
output/llm_verification/
*.rds

# checkpoints — restic / Hugging Face, tracked by revision ID
*.pt
*.safetensors

# rendered outputs — regenerable from source
*.html
```

```gitattributes
*.parquet filter=lfs diff=lfs merge=lfs -text
```

Result: LFS holds ~21 GB in ~1,500 objects (after coalescing), and the plain
Git repo is a few tens of MB.

### Cost comparison for this tree

| Option | Verdict |
|---|---|
| Everything on GitHub LFS, Free/Pro | **Blocked** — 3 GB files exceed the 2 GB cap |
| Everything on GitHub LFS, ignoring cap | ~$4/mo storage + ~$5 per full clone |
| Everything on GitHub LFS, Team | Fits allowances; $0 until ~4 full clones/month |
| Everything on R2 via proxy | ~$0.89/mo, free egress at any clone count |
| **Parquet only, on R2** | Inside the free tier or close to it |

---

## 8. Alternatives to LFS for the excluded tiers

- **`restic`** — R2/B2 for large regenerable blobs. Chunk-level
  deduplication, so a re-run that changes part of a matrix costs the changed
  chunks rather than another full copy. Plus encryption, prune-by-policy,
  integrity checks — all things LFS deliberately lacks. Record the snapshot ID
  in the repo.
- **Hugging Face Hub** for publishable model weights. It *is* git+LFS
  underneath, free for public models, with a model card and revision history
  designed for exactly this.
- **Zenodo** for released data that should be citable. A DOI'd deposit gives
  permanence guarantees and a provenance chain no LFS server has. Coexists
  happily with LFS: LFS for working state, Zenodo for frozen versions.
- **DVC / git-annex** if you want reproducible large-artifact tracking with
  the store outside the forge.
- **GitHub Releases** for one-off distributables — unlimited total size and
  bandwidth, though each file still obeys the plan's LFS per-file cap.

---

## 9. Setup checklist

```bash
git lfs install                            # per-clone; installs the hooks
git lfs track "*.parquet"
git add .gitattributes && git commit -m "Track parquet with LFS"

# converting an existing history
git lfs migrate import --include="*.parquet"

# private-phase endpoint (untracked — not in .lfsconfig)
git config lfs.url https://lfs.internal.example/repo

# verification
git lfs ls-files
git lfs fsck
git lfs env
```

If a large fraction of the tree is about to become gitignored anyway, starting
the repo clean is often less work than migrating a history you're about to
gut.

---

## 10. Sources

- <https://docs.github.com/en/billing/concepts/product-billing/git-lfs>
- <https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github>
- <https://github.com/pricing/calculator?feature=lfs>
- <https://docs.gitlab.com/user/storage_usage_quotas>
- <https://github.com/jasonwhite/rudolfs>
- <https://github.com/datopian/giftless>
- <https://github.com/twilligon/git-lfs-s3-proxy>

Pricing and quotas change — re-verify anything cost-relevant before acting on
it.

---
---

# Part II — File-based Git LFS setup (`lfs-folderstore`)

Part I (above) covers what belongs in LFS and what it costs on hosted
services. Part II covers the concrete **file-based** local setup: a folder as
the object store, no server, plus the migration path to `rudolfs` + R2 if and
when it's needed.

Assumes the tracking decision from Part I: `*.parquet` only, ~21 GB in ~1,500
objects after coalescing shards. **That coalescing prerequisite is already
satisfied** — see "Parquet consolidation" above; the tree is at 2,127 files
and lands at ~1,461 after the last rebuild.

## II.1 Why file-based first

`lfs-folderstore` is a **custom transfer agent**, not a server. git-lfs hands
it each object and it copies to/from a directory you name — which can be a
mounted volume or share.

- Nothing to run. No daemon, no port, no TLS, no auth story.
- Objects are plain files in the standard `ab/cd/abcd…` content-addressed
  layout, so you can `shasum`, `rsync`, and inspect them with ordinary tools.
- Transfers are filesystem copies rather than HTTP — faster for multi-GB
  files than a local daemon.
- Migration to a real LFS server later is free, because pointers record only
  the OID and size, never a location.

### What it doesn't give you

- **No shareability.** The config names a *local binary path*, so it can't
  meaningfully be committed. Anyone else wanting the objects must install the
  agent and mount the same volume at the same path.
- **No `git lfs lock` support.**
- **No durability of its own.** During this phase the store is the only copy
  of the content (see II.6).
- Lightly maintained project — verify it builds before relying on it.

**The deciding question:** will anyone other than you need to fetch these
objects? If yes, skip to II.7 and go straight to rudolfs or the Cloudflare
proxy. If no, this setup is less to go wrong. *(For this repo, see "Backend
decision, with this machine's actual numbers" above — the remote is an
organisation repo, which leans toward yes.)*

## II.2 Disk layout

One shared store root for all projects, not a folder per project:

```
/Volumes/LFS/
  store/          ← shared folderstore root, all projects
```

**Why shared rather than per-project:** objects are content-addressed, so
identical content across repos deduplicates automatically — but only *within
a root*. Separate roots store the same OpenAlex snapshot or NLI evidence
table once per project. Given overlap between projects, one root is the
cheaper choice.

| | One shared root | Folder per project |
|---|---|---|
| Deduplication | across all projects | none |
| Blast radius of a mistake | all projects | one project |
| Retiring a project | can't, cleanly | `rm -rf` the folder |
| Sizing | one pool | guess per project |

Neither direction locks you in: splitting a shared root means copying out the
OIDs a repo references (`git lfs ls-files -l`), and merging roots is safe by
definition because collisions are identical content.

### On a dedicated partition

Workable but of questionable value. It buys a hard ceiling preventing LFS
from eating the volume — which has some merit, since LFS stores only grow and
never expire. It costs a size guess you can't revise without repartitioning,
on a JBOD setup where you'd rather move space freely. The store is one
directory either way, so the partition adds a constraint without adding a
capability.

### No `cache/` directory during this phase

With folderstore, cache and store are both directories on the same volume, so
every object would exist twice on the same disk (~42 GB for 21 GB of parquet)
while buying nothing — a cache's purpose is to sit in front of something
slower or remote. **Leave `lfs.storage` unset here.** Set it when you move to
rudolfs + R2, where local disk genuinely fronts remote storage.

Each repo's own `.git/lfs/objects` will still duplicate against the store.
That's unavoidable; just don't add a third copy.

## II.3 Installation and configuration

```bash
brew install git-lfs         # already present here: git-lfs 3.8.0
git lfs install              # per clone — installs the pre-push hook
# install lfs-folderstore to /usr/local/bin (build from source)
```

Per repository — these three lines are **per repo**, not global:

```bash
git config lfs.customtransfer.lfs-folder.path /usr/local/bin/lfs-folderstore
git config lfs.customtransfer.lfs-folder.args "/Volumes/LFS/store"
git config lfs.standalonetransferagent lfs-folder
```

Keep these in `.git/config` (which is what plain `git config` writes) —
**never** in a committed `.lfsconfig`. A committed machine-specific binary
path can't be satisfied by any other clone, and old commits would keep
resurrecting it after migration.

Tracking:

```bash
git lfs track "*.parquet"        # quote it, or the shell globs
git add .gitattributes
git commit -m "Track parquet with LFS"
```

Useful global settings regardless of backend:

```bash
git config --global lfs.concurrenttransfers 64
```

### What these settings do and don't cover

| Setting | Scope | Covers |
|---|---|---|
| `customtransfer` + `standalonetransferagent` | per repo | where objects are kept (the store) |
| `lfs.storage` | per machine (`--global`) | the working cache each repo reads from |

The three-line config above is **store only**. It does not create or manage a
cache. That's `lfs.storage`, deliberately left unset in this phase.

## II.4 Verification

```bash
git lfs env                  # confirm the resolved agent/endpoint
git lfs ls-files             # '*' = object present locally, '-' = pointer only
git lfs ls-files -l          # with OIDs — use this to identify a repo's objects
git lfs fsck                 # integrity check
```

After first use, check where objects actually land — git-lfs versions differ
on whether a configured path is used directly or gets a subdirectory. Look at
the filesystem rather than assuming.

## II.5 Things to settle before accumulating history

**Object count.** Folderstore doesn't care whether you have 1,500 objects or
225,000 — it's a filesystem copy. But rudolfs and R2 both do, and every
version created during this phase is a version you'll later upload. Coalesce
the sub-100 KB parquet shards into partitioned datasets (~128–512 MB per
file) *before the first commit*, or you'll pay to migrate a history of a
shape you'd already decided against. **Already done here** — see the
consolidation section above.

**Files already committed as ordinary blobs** stay that way — `.gitattributes`
only applies going forward.

```bash
git lfs migrate import --include="*.parquet"   # rewrites history
git add --renormalize .                        # for uncommitted files
```

*Not needed in this repo:* nothing under `output/` has ever been committed.

**Don't run `git lfs prune`** while the store is local-only. It only removes
objects it can confirm exist on a remote, so on a local store it will refuse
to remove nearly anything anyway — and if a cache is ever shared between
repos, prune scans only the current repo's refs and can delete objects other
repos still need.

## II.6 Durability — the one real weakness

During this phase the Git repo contains **pointers to bytes that exist in
exactly one place**. Lose the store and history is unrecoverable: commits
remain, content is gone, clones error on missing objects.

- A single JBOD volume is not a backup.
- Verify the store is genuinely in the backup set, not merely appearing
  covered in a UI.
- Periodically `git lfs fsck` against a **fresh clone** — the only way to
  confirm objects actually resolve.
- Three copies, one offsite.

The store is the highest-priority thing on that volume to back up, precisely
because it has no upstream copy.

## II.7 Migration to rudolfs + R2

Free with respect to history: pointers carry only OID and size, so this is a
copy of content-addressed blobs between two stores using the same SHA-256
addressing.

Note the direction-specific wrinkle: folderstore is a transfer agent, not a
server, so `git lfs push --all` doesn't apply to it. Populate the local cache
first, then push from there.

```bash
# 1. pull every version into .git/lfs/objects via the folder agent
git lfs fetch --all
git lfs fsck                       # verify before trusting it

# 2. stand up rudolfs, then swap the config
git config --unset lfs.customtransfer.lfs-folder.path
git config --unset lfs.customtransfer.lfs-folder.args
git config --unset lfs.standalonetransferagent
git config lfs.url http://homeserver.local:8080/api/my-org/my-project

# 3. upload
git lfs push --all origin
git lfs fsck                       # verify again against the new endpoint
```

The folder store stays untouched throughout, so it's the fallback if step 3
fails. Don't delete it until a fresh clone against rudolfs resolves
everything.

### Running rudolfs

No Homebrew formula — the project ships to crates.io, AUR, and Docker Hub.
(`cargo` 1.92.0 is already installed here.)

**Native binary (preferred on a macOS home server):**

```bash
brew install rust
cargo install rudolfs

# local disk backend
export RUDOLFS_KEY=$(openssl rand -hex 32)
rudolfs --port 8080 local --path=/Volumes/LFS/store

# S3/R2 backend with cache
rudolfs --cache-dir /Volumes/LFS/cache \
        --host 0.0.0.0:8080 \
        --max-cache-size 500GiB \
        --key $KEY \
        s3 --bucket my-lfs-bucket
```

Fits launchd, avoids keeping Docker resident, gives the cache direct
filesystem access.

**Docker (the documented production path):** `.env` next to
`docker-compose.yml`:

```
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=us-east-1
LFS_ENCRYPTION_KEY=...
LFS_S3_BUCKET=my-lfs-bucket
LFS_MAX_CACHE_SIZE=10GB
```

```bash
docker compose up -d                                 # S3
docker compose -f docker-compose.minio.yml up -d     # MinIO
docker compose -f docker-compose.local.yml up -d     # local disk
```

Cache lives in a Docker volume named `rudolfs_data`.

### Gotchas

- **Bind address:** `--host localhost:8080` binds loopback only. Use
  `--port 8080` or `--host 0.0.0.0:8080`.
- **The encryption key is load-bearing.** If it changes, or encryption is
  enabled/disabled after objects exist, every existing object becomes garbage
  and clients fail SHA-256 verification. Password manager before you start —
  or skip `--key` entirely and don't change your mind.
- **URL shape is specific:** `/api/<org>/<project>`, with `api` literal.
  Separate paths = separate namespaces; the same path shared between two
  repos = shared objects (deliberate dedup, at the cost of independent
  retirement).
- **No client authentication at all.** The README's own "Non-Features"
  section says it's for trusted internal networks. Needs Tailscale or an
  authenticating reverse proxy.
- Keep the rudolfs URL in untracked `.git/config` too, for the same reason as
  the folderstore config.
- **Unresolved:** whether rudolfs accepts a custom S3 endpoint for R2
  (`*.r2.cloudflarestorage.com`). The README documents only AWS credential
  discovery. **Check this before migrating, not during.** If it doesn't, the
  fallbacks are the MinIO compose shape (another service to run) or
  `git-lfs-s3-proxy` on Cloudflare — same fetch → repoint → push sequence, so
  nothing about the folderstore phase is wasted either way.

### Set the client cache at this point

```bash
git config --global lfs.storage /Volumes/LFS/cache
```

Now it earns its place: local disk fronting remote storage, only cold objects
crossing the network. Note it's **per-machine** (`--global` is the point), and
migration isn't automatic — existing clones keep using their own
`.git/lfs/objects` for objects already there. Copy them over (identical
layout) or let them re-fetch.

## II.8 Honest comparison

### folderstore vs. rudolfs (local backend)

| | folderstore | rudolfs (local) |
|---|---|---|
| Running process | none | daemon + port |
| Client setup | agent + share at identical path | just a URL |
| Remote access | needs the volume mounted | works over the network |
| `git lfs lock` | unsupported | supported |
| Objects on disk | plain files, standard layout | own layout, encrypted if `--key` |
| Backup/verify | rsync, restic, `shasum` directly | its own structure |
| Transfer speed | filesystem copy | HTTP over loopback/LAN |
| Maintenance | zero | uptime, TLS, auth |

For a single user on one machine, folderstore wins on nearly every axis. The
one real exception is shareability: a URL is portable, a local binary path
isn't.

### Does rudolfs make cache/storage handling *easier*?

Not straightforwardly. There are two distinct caches:

- **Client-side** (`lfs.storage`) — identical under both options. Same
  settings, same manual prune, same absence of automatic eviction. Rudolfs
  changes nothing here.
- **Server-side** (`--cache-dir`, `--max-cache-size`) — rudolfs's own cache
  between clients and S3. Size-capped, evicting, corruption-detecting. This
  is what folderstore has no equivalent of.

So rudolfs adds a self-managing cache layer; it does not simplify the client
cache. For one person on one machine the total is **harder**, not easier: a
daemon, a destructive-if-lost key, a bind gotcha, a specific URL shape, no
built-in auth, and an unresolved R2 endpoint question.

**Rudolfs earns its keep for durability + network access**, not for cache
management:

- objects durable off-machine without hand-scripted sync
- bounded cache rather than one that grows until noticed
- a URL instead of a mounted share plus installed agent

## II.9 Client cache behaviour (either phase)

Once `lfs.storage` is set, git-lfs owns that directory entirely — writes on
fetch and on commit of a tracked file, reads on checkout, same
content-addressed layout. Don't reorganise it by hand.

Limits of "managed":

- **No automatic shrinking.** No size cap, no LRU eviction, no expiry. It
  grows until `git lfs prune`, which is manual and per-repo.
- **Pruning a shared cache is hazardous.** Prune scans only the *current*
  repo's refs, so with several repos on one cache it can delete objects the
  others need. It only removes objects confirmed present on a remote, which
  limits damage on a pushed store — and makes it nearly useless on a
  local-only one.

Net: manage size by watching rather than by policy. Fine for ~21 GB across a
couple of repos, and a reason not to give the volume a tight ceiling.

## II.10 Quick reference

```bash
# per-repo store config (folderstore phase)
git config lfs.customtransfer.lfs-folder.path /usr/local/bin/lfs-folderstore
git config lfs.customtransfer.lfs-folder.args "/Volumes/LFS/store"
git config lfs.standalonetransferagent lfs-folder

# tracking
git lfs track "*.parquet"

# machine-wide (rudolfs phase only)
git config --global lfs.storage /Volumes/LFS/cache
git config --global lfs.concurrenttransfers 64

# inspection
git lfs env
git lfs ls-files [-l]
git lfs fsck
git lfs fetch --all
```

## II.11 Sources

- <https://github.com/jasonwhite/rudolfs>
- <https://github.com/twilligon/git-lfs-s3-proxy>
- <https://github.com/datopian/giftless>
