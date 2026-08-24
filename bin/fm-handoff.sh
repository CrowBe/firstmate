#!/usr/bin/env bash
# Firstmate handoff admission and session-end run review.
#
# Usage:
#   fm-handoff.sh plan --task <id> --repo <trusted-repo> --base <sha> --expect-ref <ref>
#   fm-handoff.sh admit --task <id> --bundle <path>
#   fm-handoff.sh session-end --task <id>
#   fm-handoff.sh review --task <id> --sha <sha> --reviewer <name> --verdict <approved|changes|pending>
#   fm-handoff.sh assert-reviewed --task <id> --sha <sha>
#
# This is a workflow guardrail, not a non-bypassable control: a worker that can
# write this home's state records can alter the record the guard reads.
# It binds reviewed content identity (the reviewed SHA is the same SHA presented
# for landing), but it does not establish provenance (who produced that SHA).
#
# This fork does not run no-mistakes.
# The session-end checks are deliberately weaker: they inspect Git objects and
# run metadata only, and are neither a replacement for host execution nor a
# claim that the worker's code is correct.
# No command below checks out, builds, installs, imports, or executes worker
# authored files.
#
# Admission fails closed when the candidate contains a gitlink or .gitmodules,
# an unresolved Git LFS pointer, or a new object larger than the configured
# maximum. FM_HANDOFF_MAX_OBJECT_BYTES sets that maximum and defaults to
# 16 MiB; it must be a positive integer.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MAX_OBJECT_BYTES=${FM_HANDOFF_MAX_OBJECT_BYTES:-16777216}

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

case "$MAX_OBJECT_BYTES" in
  ''|*[!0-9]*|0)
    printf 'error: FM_HANDOFF_MAX_OBJECT_BYTES must be a positive integer\n' >&2
    exit 2
    ;;
esac

valid_task() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

absolute_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (CDPATH='' cd -- "$1" && pwd -P)
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'error: sha256sum or shasum is required\n' >&2
    return 1
  fi
}

safe_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_ATTR_NOSYSTEM=1 git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

handoff_dir() {
  printf '%s/handoff' "$STATE"
}

plan_path() {
  printf '%s/%s.plan' "$(handoff_dir)" "$1"
}

decision_path() {
  printf '%s/%s.decision' "$(handoff_dir)" "$1"
}

review_path() {
  printf '%s/%s.review' "$(handoff_dir)" "$1"
}

record_path() {
  printf '%s/%s.records' "$(handoff_dir)" "$1"
}

record_value() { # <file> <key>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

atomic_record() { # <path> <body>
  local path=$1 body=$2 tmp
  mkdir -p "$(dirname "$path")"
  [ ! -L "$(dirname "$path")" ] || return 1
  tmp=$(mktemp "$(dirname "$path")/.handoff.XXXXXX") || return 1
  umask 077
  printf '%s' "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path"
}

append_record() { # <task> <event> <result> [key=value...]
  local task=$1 event=$2 result=$3 path field
  shift 3
  path=$(record_path "$task")
  mkdir -p "$(dirname "$path")"
  [ ! -L "$(dirname "$path")" ] || return 1
  {
    printf 'epoch=%s event=%s result=%s' "$(date +%s)" "$event" "$result"
    for field in "$@"; do printf ' %s' "$field"; done
    printf '\n'
  } >> "$path"
}

refuse() { # <task> <code> [bundle-digest] [quarantine-dir]
  local task=$1 code=$2 digest=${3:-none} quarantine=${4:-none}
  append_record "$task" admit refused "code=$code" "bundle_sha256=$digest" "quarantine=$quarantine" || true
  printf 'QUARANTINED %s\n' "$code" >&2
  exit 1
}

parse_plan() { # <task>
  local task=$1 plan
  plan=$(plan_path "$task")
  [ -f "$plan" ] && [ ! -L "$plan" ] || return 1
  PLAN_REPO=$(record_value "$plan" repo) || return 1
  PLAN_BASE=$(record_value "$plan" base) || return 1
  PLAN_EXPECT_REF=$(record_value "$plan" expect_ref) || return 1
  PLAN_DIGEST=$(record_value "$plan" plan_sha256) || return 1
  [ -n "$PLAN_REPO" ] && [ -n "$PLAN_BASE" ] && [ -n "$PLAN_EXPECT_REF" ] && [ -n "$PLAN_DIGEST" ]
}

command_plan() {
  local task= repo= base= expect_ref= arg repo_real resolved plan
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --task|--repo|--base|--expect-ref)
        [ "$#" -ge 2 ] || { printf 'error: %s requires a value\n' "$arg" >&2; exit 2; }
        case "$arg" in
          --task) task=$2 ;;
          --repo) repo=$2 ;;
          --base) base=$2 ;;
          --expect-ref) expect_ref=$2 ;;
        esac
        shift 2
        ;;
      *) printf 'error: unknown plan argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
  done
  valid_task "$task" || { printf 'error: invalid task id\n' >&2; exit 2; }
  repo_real=$(absolute_directory "$repo") || { printf 'error: trusted repo must be a non-symlink directory\n' >&2; exit 2; }
  safe_git -C "$repo_real" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'error: trusted repo is not a Git worktree\n' >&2; exit 2; }
  resolved=$(safe_git -C "$repo_real" rev-parse --verify "${base}^{commit}" 2>/dev/null) \
    || { printf 'error: base is not a commit in the trusted repo\n' >&2; exit 2; }
  safe_git -C "$repo_real" check-ref-format "$expect_ref" \
    || { printf 'error: expected ref is invalid\n' >&2; exit 2; }
  plan=$(plan_path "$task")
  local plan_tmp plan_digest
  mkdir -p "$(handoff_dir)"
  plan_tmp=$(mktemp "$(handoff_dir)/.plan.XXXXXX")
  printf 'schema=fm-handoff-plan.v1\nrepo=%s\nbase=%s\nexpect_ref=%s\n' "$repo_real" "$resolved" "$expect_ref" > "$plan_tmp"
  plan_digest=$(sha256_file "$plan_tmp")
  printf 'plan_sha256=%s\n' "$plan_digest" >> "$plan_tmp"
  if [ -f "$plan" ]; then
    parse_plan "$task" || { rm -f "$plan_tmp"; printf 'error: existing handoff plan is malformed\n' >&2; exit 1; }
    if [ "$PLAN_REPO" = "$repo_real" ] && [ "$PLAN_BASE" = "$resolved" ] && [ "$PLAN_EXPECT_REF" = "$expect_ref" ]; then
      rm -f "$plan_tmp"
      printf 'PLANNED %s existing\n' "$PLAN_DIGEST"
      return
    fi
    rm -f "$plan_tmp"
    printf 'error: task already has a different handoff plan; refusing to replace it\n' >&2
    exit 1
  fi
  chmod 600 "$plan_tmp" 2>/dev/null || true
  mv -f "$plan_tmp" "$plan"
  append_record "$task" plan recorded "plan_sha256=$plan_digest" "base=$resolved" "expect_ref=$expect_ref"
  printf 'PLANNED %s\n' "$plan_digest"
}

command_admit() {
  local task= bundle= arg bundle_digest bundle_bytes quarantine_root quarantine empty_hooks qrepo
  local heads head_count head_oid head_ref actual_head base_objects head_objects expected_objects actual_objects new_objects tree_entries tree_names blob_file
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --task|--bundle)
        [ "$#" -ge 2 ] || { printf 'error: %s requires a value\n' "$arg" >&2; exit 2; }
        case "$arg" in --task) task=$2 ;; --bundle) bundle=$2 ;; esac
        shift 2
        ;;
      *) printf 'error: unknown admit argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
  done
  valid_task "$task" || { printf 'error: invalid task id\n' >&2; exit 2; }
  parse_plan "$task" || { printf 'error: no valid handoff plan for task %s\n' "$task" >&2; exit 1; }
  [ -f "$bundle" ] && [ ! -L "$bundle" ] || refuse "$task" bundle-not-regular
  bundle_bytes=$(wc -c < "$bundle" | tr -d ' ')
  case "$bundle_bytes" in ''|*[!0-9]*) refuse "$task" bundle-size-unreadable ;; esac
  bundle_digest=$(sha256_file "$bundle") || refuse "$task" bundle-digest-unavailable
  quarantine_root="$STATE/handoff-quarantine/$task"
  mkdir -p "$quarantine_root"
  [ ! -L "$quarantine_root" ] || refuse "$task" quarantine-path-unsafe "$bundle_digest"
  quarantine=$(mktemp -d "$quarantine_root/admit.XXXXXX") || refuse "$task" quarantine-unavailable "$bundle_digest"
  chmod 700 "$quarantine" 2>/dev/null || true
  cp -- "$bundle" "$quarantine/bundle" || refuse "$task" quarantine-copy-failed "$bundle_digest" "$quarantine"
  empty_hooks="$quarantine/empty-hooks"
  mkdir -p "$empty_hooks"
  qrepo="$quarantine/quarantine.git"

  heads=$(safe_git bundle list-heads "$quarantine/bundle" 2>/dev/null) || refuse "$task" bundle-headers-invalid "$bundle_digest" "$quarantine"
  head_count=$(printf '%s\n' "$heads" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$head_count" = 1 ] || refuse "$task" unexpected-ref-set "$bundle_digest" "$quarantine"
  head_oid=$(printf '%s\n' "$heads" | awk 'NF == 2 { print $1 }')
  head_ref=$(printf '%s\n' "$heads" | awk 'NF == 2 { print $2 }')
  [ -n "$head_oid" ] && [ "$head_ref" = "$PLAN_EXPECT_REF" ] \
    || refuse "$task" unexpected-ref-set "$bundle_digest" "$quarantine"

  safe_git init --bare --template="$empty_hooks" "$qrepo" >/dev/null 2>&1 \
    || refuse "$task" quarantine-init-failed "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" config core.hooksPath "$empty_hooks"
  safe_git -C "$qrepo" fetch --no-tags "$PLAN_REPO" "$PLAN_BASE:refs/handoff/base" >/dev/null 2>&1 \
    || refuse "$task" recorded-base-unavailable "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" -c fetch.fsckObjects=true -c transfer.fsckObjects=true \
    -c core.hooksPath="$empty_hooks" fetch --no-tags "$quarantine/bundle" \
    "$PLAN_EXPECT_REF:refs/handoff/head" >/dev/null 2>&1 \
    || refuse "$task" object-integrity-failed "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" fsck --connectivity-only --no-reflogs >/dev/null 2>&1 \
    || refuse "$task" object-connectivity-failed "$bundle_digest" "$quarantine"
  actual_head=$(safe_git -C "$qrepo" rev-parse --verify refs/handoff/head^{commit} 2>/dev/null) \
    || refuse "$task" output-not-commit "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" merge-base --is-ancestor refs/handoff/base refs/handoff/head >/dev/null 2>&1 \
    || refuse "$task" output-not-descendant "$bundle_digest" "$quarantine"

  base_objects="$quarantine/base.objects"
  head_objects="$quarantine/head.objects"
  expected_objects="$quarantine/expected.objects"
  actual_objects="$quarantine/actual.objects"
  new_objects="$quarantine/new.objects"
  safe_git -C "$qrepo" rev-list --objects --no-object-names refs/handoff/base > "$base_objects.raw" \
    || refuse "$task" base-object-list-failed "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" rev-list --objects --no-object-names refs/handoff/head > "$head_objects.raw" \
    || refuse "$task" head-object-list-failed "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" rev-list --objects --no-object-names refs/handoff/base..refs/handoff/head > "$expected_objects.raw" \
    || refuse "$task" output-object-list-failed "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" cat-file --batch-all-objects --batch-check='%(objectname)' > "$actual_objects.raw" \
    || refuse "$task" object-inventory-failed "$bundle_digest" "$quarantine"
  LC_ALL=C sort -u "$base_objects.raw" > "$base_objects"
  LC_ALL=C sort -u "$head_objects.raw" > "$head_objects"
  LC_ALL=C sort -u "$expected_objects.raw" > "$expected_objects"
  LC_ALL=C sort -u "$actual_objects.raw" > "$actual_objects"
  comm -23 "$actual_objects" "$base_objects" > "$new_objects"
  cmp -s "$new_objects" "$expected_objects" \
    || refuse "$task" object-closure-failed "$bundle_digest" "$quarantine"

  tree_entries="$quarantine/tree.entries"
  tree_names="$quarantine/tree.names"
  safe_git -C "$qrepo" ls-tree -r -l refs/handoff/head > "$tree_entries" \
    || refuse "$task" tree-inspection-failed "$bundle_digest" "$quarantine"
  awk '$1 == "160000" { exit 1 }' "$tree_entries" \
    || refuse "$task" gitlink-present "$bundle_digest" "$quarantine"
  safe_git -C "$qrepo" ls-tree -r --name-only refs/handoff/head > "$tree_names" \
    || refuse "$task" tree-inspection-failed "$bundle_digest" "$quarantine"
  grep -Fx '.gitmodules' "$tree_names" >/dev/null 2>&1 \
    && refuse "$task" submodule-declaration-present "$bundle_digest" "$quarantine"

  blob_file="$quarantine/blob.inspect"
  local object type size first_line
  while IFS= read -r object; do
    [ -n "$object" ] || continue
    type=$(safe_git -C "$qrepo" cat-file -t "$object" 2>/dev/null) \
      || refuse "$task" object-type-unreadable "$bundle_digest" "$quarantine"
    size=$(safe_git -C "$qrepo" cat-file -s "$object" 2>/dev/null) \
      || refuse "$task" object-size-unreadable "$bundle_digest" "$quarantine"
    case "$size" in ''|*[!0-9]*) refuse "$task" object-size-unreadable "$bundle_digest" "$quarantine" ;; esac
    [ "$size" -le "$MAX_OBJECT_BYTES" ] \
      || refuse "$task" object-too-large "$bundle_digest" "$quarantine"
    [ "$type" = blob ] || continue
    safe_git -C "$qrepo" cat-file blob "$object" > "$blob_file" \
      || refuse "$task" blob-read-failed "$bundle_digest" "$quarantine"
    first_line=$(sed -n '1p' "$blob_file")
    [ "$first_line" != 'version https://git-lfs.github.com/spec/v1' ] \
      || refuse "$task" lfs-pointer-present "$bundle_digest" "$quarantine"
  done < "$head_objects"

  local decision old_sha old_digest
  decision=$(decision_path "$task")
  if [ -f "$decision" ]; then
    old_sha=$(record_value "$decision" admitted_sha || true)
    old_digest=$(record_value "$decision" bundle_sha256 || true)
    if [ "$old_sha" = "$actual_head" ] && [ "$old_digest" = "$bundle_digest" ]; then
      append_record "$task" admit admitted-existing "sha=$actual_head" "bundle_sha256=$bundle_digest" "quarantine=$quarantine"
      printf 'ADMITTED %s existing\n' "$actual_head"
      return
    fi
    refuse "$task" admission-already-recorded "$bundle_digest" "$quarantine"
  fi
  atomic_record "$decision" "$(printf 'schema=fm-handoff-decision.v1\nplan_sha256=%s\nadmitted_sha=%s\nbundle_sha256=%s\nquarantine=%s\n' "$PLAN_DIGEST" "$actual_head" "$bundle_digest" "$quarantine")"
  append_record "$task" admit admitted "sha=$actual_head" "bundle_sha256=$bundle_digest" "quarantine=$quarantine"
  printf 'ADMITTED %s\n' "$actual_head"
}

command_session_end() {
  local task= arg meta worktree expected head dirty bundle output rc=0 decision quarantine qrepo
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --task)
        [ "$#" -ge 2 ] || { printf 'error: --task requires a value\n' >&2; exit 2; }
        task=$2; shift 2
        ;;
      *) printf 'error: unknown session-end argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
  done
  valid_task "$task" || { printf 'error: invalid task id\n' >&2; exit 2; }
  parse_plan "$task" || { printf 'RUN_REVIEW needs-decision no-plan\n'; exit 1; }
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf 'RUN_REVIEW needs-decision meta-unavailable\n'; exit 1; }
  worktree=$(record_value "$meta" worktree || true)
  worktree=$(absolute_directory "$worktree" 2>/dev/null || true)
  [ -n "$worktree" ] || { printf 'RUN_REVIEW needs-decision worktree-unavailable\n'; exit 1; }
  expected=$(safe_git -C "$worktree" rev-parse --verify "${PLAN_EXPECT_REF}^{commit}" 2>/dev/null || true)
  [ -n "$expected" ] || { printf 'RUN_REVIEW needs-decision expected-ref-unavailable\n'; exit 1; }
  head=$expected
  dirty=$(safe_git -C "$worktree" status --porcelain 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    append_record "$task" session-end needs-decision "code=dirty-worktree" "sha=$head"
    printf 'RUN_REVIEW needs-decision dirty-worktree\n'
    return
  fi
  bundle=$(mktemp "$(handoff_dir)/$task.session.XXXXXX.bundle")
  if ! safe_git -C "$worktree" bundle create "$bundle" "$PLAN_EXPECT_REF" >/dev/null 2>&1; then
    rm -f "$bundle"
    append_record "$task" session-end needs-decision "code=bundle-capture-failed" "sha=$head"
    printf 'RUN_REVIEW needs-decision bundle-capture-failed\n'
    return
  fi
  output=$("$0" admit --task "$task" --bundle "$bundle" 2>&1) || rc=$?
  rm -f "$bundle"
  if [ "$rc" -ne 0 ]; then
    append_record "$task" session-end needs-decision "code=admission-refused" "sha=$head"
    printf 'RUN_REVIEW needs-decision admission-refused\n'
    return
  fi
  decision=$(decision_path "$task")
  quarantine=$(record_value "$decision" quarantine || true)
  quarantine=$(absolute_directory "$quarantine" 2>/dev/null || true)
  qrepo=${quarantine:+$quarantine/quarantine.git}
  if [ -z "$qrepo" ] || [ ! -d "$qrepo" ] || [ -L "$qrepo" ] \
    || ! safe_git -C "$qrepo" diff --no-ext-diff --check refs/handoff/base...refs/handoff/head --; then
    append_record "$task" session-end needs-decision "code=diff-check-failed" "sha=$head"
    printf 'RUN_REVIEW needs-decision diff-check-failed\n'
    return
  fi
  append_record "$task" session-end pending-review "sha=$head" "scope=human-review-required"
  printf 'RUN_REVIEW pending-review %s\n' "$head"
}

command_review() {
  local task= sha= reviewer= verdict= arg decision admitted
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --task|--sha|--reviewer|--verdict)
        [ "$#" -ge 2 ] || { printf 'error: %s requires a value\n' "$arg" >&2; exit 2; }
        case "$arg" in
          --task) task=$2 ;; --sha) sha=$2 ;; --reviewer) reviewer=$2 ;; --verdict) verdict=$2 ;;
        esac
        shift 2
        ;;
      *) printf 'error: unknown review argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
  done
  valid_task "$task" || { printf 'error: invalid task id\n' >&2; exit 2; }
  case "$reviewer" in ''|*$'\n'*|*$'\r'*|*=*) printf 'error: reviewer must be a one-line label\n' >&2; exit 2 ;; esac
  case "$verdict" in approved|changes|pending) : ;; *) printf 'error: verdict must be approved, changes, or pending\n' >&2; exit 2 ;; esac
  decision=$(decision_path "$task")
  admitted=$(record_value "$decision" admitted_sha || true)
  [ -n "$admitted" ] && [ "$sha" = "$admitted" ] \
    || { printf 'error: review SHA is not the admitted content identity\n' >&2; exit 1; }
  atomic_record "$(review_path "$task")" "$(printf 'schema=fm-handoff-review.v1\nadmitted_sha=%s\nreviewed_sha=%s\nreviewer=%s\nverdict=%s\n' "$admitted" "$sha" "$reviewer" "$verdict")"
  append_record "$task" review "$verdict" "sha=$sha" "reviewer=$reviewer"
  case "$verdict" in
    approved) printf 'APPROVED %s content-identity-bound provenance-unestablished\n' "$sha" ;;
    *) printf '%s %s\n' "${verdict^^}" "$sha" ;;
  esac
}

command_assert_reviewed() {
  local task= sha= arg review reviewed verdict
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --task|--sha)
        [ "$#" -ge 2 ] || { printf 'error: %s requires a value\n' "$arg" >&2; exit 2; }
        case "$arg" in --task) task=$2 ;; --sha) sha=$2 ;; esac
        shift 2
        ;;
      *) printf 'error: unknown assert-reviewed argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
  done
  valid_task "$task" || { printf 'error: invalid task id\n' >&2; exit 2; }
  review=$(review_path "$task")
  reviewed=$(record_value "$review" reviewed_sha || true)
  verdict=$(record_value "$review" verdict || true)
  [ "$verdict" = approved ] && [ "$reviewed" = "$sha" ] \
    || { printf 'REFUSED reviewed-content-identity-mismatch\n' >&2; exit 1; }
  printf 'REVIEWED %s content-identity-bound provenance-unestablished\n' "$sha"
}

command=$1
shift
case "$command" in
  plan) command_plan "$@" ;;
  admit) command_admit "$@" ;;
  session-end) command_session_end "$@" ;;
  review) command_review "$@" ;;
  assert-reviewed) command_assert_reviewed "$@" ;;
  *) printf 'error: unknown command: %s\n' "$command" >&2; usage >&2; exit 2 ;;
esac
