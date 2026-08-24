#!/usr/bin/env bash
# Behavior tests for the Firstmate handoff admission and session-end run review.
# Every fixture is a real Git repository and bundle. The test only invokes the
# public fm-handoff.sh interface; no production bypass exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDOFF="$ROOT/bin/fm-handoff.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff)
fm_git_identity fmtest fmtest@example.invalid

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  STATE="$WORLD/state"
  PROJECT="$WORLD/project"
  WORKER="$WORLD/worker"
  mkdir -p "$STATE" "$PROJECT"
  git -C "$PROJECT" init -q
  printf 'base\n' > "$PROJECT/base.txt"
  git -C "$PROJECT" add base.txt
  git -C "$PROJECT" commit -q -m base
  BASE=$(git -C "$PROJECT" rev-parse HEAD)
  git clone -q "$PROJECT" "$WORKER"
}

run_handoff() {
  FM_STATE_OVERRIDE="$STATE" "$HANDOFF" "$@"
}

plan_task() { # <task> <ref>
  run_handoff plan --task "$1" --repo "$PROJECT" --base "$BASE" --expect-ref "$2"
}

candidate() { # <task> <path> <contents>
  local task=$1 path=$2 contents=$3
  git -C "$WORKER" checkout -q -B "fm/$task" "$BASE"
  mkdir -p "$(dirname "$WORKER/$path")"
  printf '%s' "$contents" > "$WORKER/$path"
  git -C "$WORKER" add -- "$path"
  git -C "$WORKER" commit -q -m "$task"
}

bundle_for() { # <task>
  local task=$1 bundle
  bundle="$WORLD/$task.bundle"
  git -C "$WORKER" bundle create "$bundle" "refs/heads/fm/$task"
  printf '%s\n' "$bundle"
}

assert_refused() { # <task> <bundle> <code>
  local out rc
  out=$(run_handoff admit --task "$1" --bundle "$2" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$1: admission unexpectedly passed"
  assert_contains "$out" "QUARANTINED $3" "$1: expected refusal code $3"
}

test_admit_binds_content_identity_without_executing_output() {
  local bundle out head marker
  make_world admitted
  marker="$WORLD/worker-executed"
  candidate admitted Makefile "all:\n\t@touch $marker\n"
  printf '{"scripts":{"postinstall":"touch %s"}}\n' "$marker" > "$WORKER/package.json"
  git -C "$WORKER" add package.json
  git -C "$WORKER" commit -q -m package-json
  plan_task admitted refs/heads/fm/admitted >/dev/null
  bundle=$(bundle_for admitted)
  out=$(run_handoff admit --task admitted --bundle "$bundle") || fail "admission should accept a regular bundle: $out"
  head=$(git -C "$WORKER" rev-parse HEAD)
  assert_contains "$out" "ADMITTED $head" "admission did not report the reviewed content identity"
  assert_absent "$marker" "admission executed a worker-authored Makefile or postinstall"
  run_handoff review --task admitted --sha "$head" --reviewer captain --verdict approved >/dev/null \
    || fail "review should bind the admitted SHA"
  run_handoff assert-reviewed --task admitted --sha "$head" >/dev/null \
    || fail "approved content identity should assert"
  candidate admitted later.txt later
  if run_handoff assert-reviewed --task admitted --sha "$(git -C "$WORKER" rev-parse HEAD)" >/dev/null 2>&1; then
    fail "a different SHA must not inherit approval"
  fi
  pass "handoff admission binds reviewed content identity without executing output"
}

test_admission_refuses_extra_refs_gitlinks_lfs_and_large_objects() {
  local bundle
  make_world fail-closed

  candidate refs ordinary.txt ordinary
  plan_task refs refs/heads/fm/refs >/dev/null
  bundle="$WORLD/refs.bundle"
  git -C "$WORKER" bundle create "$bundle" --all
  assert_refused refs "$bundle" unexpected-ref-set

  git -C "$WORKER" checkout -q -B fm/gitlink "$BASE"
  git -C "$WORKER" update-index --add --cacheinfo "160000,$BASE,dependency"
  git -C "$WORKER" commit -q -m gitlink
  plan_task gitlink refs/heads/fm/gitlink >/dev/null
  bundle=$(bundle_for gitlink)
  assert_refused gitlink "$bundle" gitlink-present

  candidate lfs pointer.txt $'version https://git-lfs.github.com/spec/v1\noid sha256:0123456789\nsize 4\n'
  plan_task lfs refs/heads/fm/lfs >/dev/null
  bundle=$(bundle_for lfs)
  assert_refused lfs "$bundle" lfs-pointer-present

  candidate large large.bin "$(printf '%080d' 0)"
  plan_task large refs/heads/fm/large >/dev/null
  bundle=$(bundle_for large)
  if FM_HANDOFF_MAX_OBJECT_BYTES=32 FM_STATE_OVERRIDE="$STATE" "$HANDOFF" admit --task large --bundle "$bundle" > "$WORLD/large.out" 2>&1; then
    fail "oversized object admission unexpectedly passed"
  fi
  assert_grep 'QUARANTINED object-too-large' "$WORLD/large.out" "oversized object did not fail closed"
  pass "handoff admission refuses unclosed content shapes"
}

test_session_end_records_pending_review_and_dirty_work_needs_decision() {
  local out head
  make_world session-end
  candidate session changed.txt changed
  plan_task session refs/heads/fm/session >/dev/null
  cat > "$STATE/session.meta" <<EOF
worktree=$WORKER
project=$PROJECT
EOF
  out=$(run_handoff session-end --task session) || fail "clean session end should create a review obligation: $out"
  head=$(git -C "$WORKER" rev-parse HEAD)
  assert_contains "$out" "RUN_REVIEW pending-review $head" "session end did not report pending review"
  run_handoff review --task session --sha "$head" --reviewer captain --verdict changes >/dev/null \
    || fail "session-end admission should be reviewable"

  candidate dirty changed.txt changed-again
  plan_task dirty refs/heads/fm/dirty >/dev/null
  cat > "$STATE/dirty.meta" <<EOF
worktree=$WORKER
project=$PROJECT
EOF
  printf 'uncommitted\n' > "$WORKER/uncommitted.txt"
  out=$(run_handoff session-end --task dirty 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "dirty session end should record a decision rather than crash: $out"
  assert_contains "$out" 'RUN_REVIEW needs-decision dirty-worktree' "dirty output did not require a decision"
  pass "session-end review records only static evidence and requires decisions for dirty output"
}

test_local_landing_requires_the_exact_reviewed_sha() {
  local bundle head out
  make_world local-landing
  candidate landing landed.txt landed
  plan_task landing refs/heads/fm/landing >/dev/null
  bundle=$(bundle_for landing)
  run_handoff admit --task landing --bundle "$bundle" >/dev/null \
    || fail "landing fixture admission should succeed"
  git -C "$PROJECT" fetch -q "$WORKER" refs/heads/fm/landing:refs/heads/fm/landing
  cat > "$STATE/landing.meta" <<EOF
project=$PROJECT
mode=local-only
EOF
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD" FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-merge-local.sh" landing 2>&1)
  [ "$?" -ne 0 ] || fail "local landing bypassed missing SHA-bound review"
  assert_contains "$out" 'REFUSED: fm/landing is not the exact approved handoff content.' \
    "local landing did not name the missing handoff approval"
  head=$(git -C "$PROJECT" rev-parse refs/heads/fm/landing)
  run_handoff review --task landing --sha "$head" --reviewer captain --verdict approved >/dev/null \
    || fail "landing review should approve the admitted SHA"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD" FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-merge-local.sh" landing >/dev/null \
    || fail "exact reviewed SHA should permit local fast-forward"
  [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$head" ] \
    || fail "local landing did not advance the default branch to the reviewed SHA"
  pass "local landing has no runtime bypass around SHA-bound review"
}

test_admit_binds_content_identity_without_executing_output
test_admission_refuses_extra_refs_gitlinks_lfs_and_large_objects
test_session_end_records_pending_review_and_dirty_work_needs_decision
test_local_landing_requires_the_exact_reviewed_sha

echo "all fm-handoff tests passed"
