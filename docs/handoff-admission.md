# Handoff admission and session-end run review

**Verified:** This page owns the current Firstmate handoff admission and session-end run-review contract.

**Verified:** [`bin/fm-handoff.sh`](../bin/fm-handoff.sh) is the executable owner of plan, admission, review, content-identity assertion, record format, and refusal codes.

## Claim labels

**Verified:** A verified statement is backed by the committed implementation and its behavior test.

**Unverified:** An unverified statement identifies a limit that this fork does not prove.

## Boundary

**Verified:** This fork does not run no-mistakes.

**Verified:** The handoff guard is a workflow guardrail, not a non-bypassable control, because a worker that can alter its state record can alter the record being checked.

**Verified:** Admission binds reviewed content identity by requiring the same admitted SHA at review and assertion time.

**Unverified:** The guard does not establish provenance, including the person, process, or model that produced an admitted SHA.

**Verified:** Admission never checks out, builds, installs, imports, or executes worker-authored files.

**Unverified:** The static checks do not prove that the worker's code is correct, safe, complete, or within a natural-language task scope.

## Admission

**Verified:** A plan records a trusted repository, recorded base commit, and exactly one expected output ref before admission.

**Verified:** Admission quarantines a regular bundle in fresh state, fetches the recorded base into a fresh bare repository, enables Git object fsck, and verifies complete connectivity and ancestry before recording an admitted SHA.

**Verified:** Admission refuses an unexpected ref set, corrupt or malformed objects, object closure outside `base..head`, gitlinks, `.gitmodules`, unresolved Git LFS pointers, and objects larger than `FM_HANDOFF_MAX_OBJECT_BYTES`.

**Verified:** Every admit, refusal, session-end check, and review appends a secret-free line to `state/handoff/<task>.records`.

## Session-end run review

**Verified:** A spawned task receives a plan before its worker launches.

**Verified:** When a terminal session is reconciled, Firstmate reads the worktree's Git status and planned ref, then runs `git diff --check --no-ext-diff` only inside the admitted fresh bare repository.

**Verified:** A clean committed ref is bundled without checkout and submitted to admission, then receives `RUN_REVIEW pending-review <sha>`.

**Verified:** Dirty worktrees, unavailable metadata or ref, diff-check failures, bundle-capture failures, and admission refusals return `RUN_REVIEW needs-decision <code>`.

**Verified:** A human records `approved`, `changes`, or `pending` against the admitted SHA with `fm-handoff.sh review`.

**Verified:** Only `approved` for the exact SHA allows `fm-handoff.sh assert-reviewed`, which `fm-merge-local.sh` requires before a local landing.

**Unverified:** No session-end result can replace human review of the complete diff or decide whether changed paths satisfy the task's natural-language scope.

## Separate concerns

**Verified:** The handoff guard is separate from the Marooned containment capsule and shares no runtime adapter or containment claim with it.

**Unverified:** This initial slice does not implement a Git shuttle, hosted adapter, public SDK, egress receipt, or Sea Trials.
