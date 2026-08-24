#!/usr/bin/env bash
# Behavior tests for the private Marooned capsule configuration and evidence gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPSULE="$ROOT/bin/fm-capsule.sh"
CONFIG="$ROOT/bin/capsule/default-config.json"
FIXTURE="$ROOT/bin/capsule/hostile-fixture.py"
DOCKER_ADAPTER="$ROOT/bin/capsule/adapters/docker-sandboxes.sh"
PODMAN_ADAPTER="$ROOT/bin/capsule/adapters/podman-rootless.sh"
TMP_ROOT=$(fm_test_tmproot fm-capsule)

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

test_configuration_is_strict_and_orders_two_real_adapters() {
  local bad_config="$TMP_ROOT/advisory.json" bad_checks="$TMP_ROOT/checks.json" candidates
  "$CAPSULE" validate >/dev/null || fail "default capsule configuration did not validate"
  jq '.armPolicy.advisoryShaping = "permit"' "$CONFIG" > "$bad_config"
  run_expect_failure "would permit advisory/degraded containment" \
    "$CAPSULE" validate --config "$bad_config"
  jq 'del(.requiredChecks[0])' "$CONFIG" > "$bad_checks"
  run_expect_failure "would permit advisory/degraded containment" \
    "$CAPSULE" validate --config "$bad_checks"

  candidates=$("$CAPSULE" candidates) || fail "current Linux host did not resolve a candidate order"
  jq -e '
    (.candidates | length) == 2 and
    (.candidates | index("podman-rootless")) != null and
    (.candidates | index("docker-sandboxes")) != null
  ' <<<"$candidates" >/dev/null || fail "candidate order did not retain both adapter implementations"
  pass "capsule configuration preserves the hostile floor, refuses advisory shaping, and orders both concrete adapters"
}

test_hostile_fixture_covers_the_required_floor() {
  local out="$TMP_ROOT/fixture.json" rc ids present_path
  set +e
  python3 "$FIXTURE" > "$out"
  rc=$?
  set -e
  case "$rc" in
    0|1) ;;
    *) fail "hostile fixture exited unexpectedly with $rc" ;;
  esac
  ids=$(jq -c '[.checks[].id] | sort' "$out") || fail "hostile fixture did not emit JSON"
  [ "$ids" = '["cloud-control-socket","containerd-socket","dbus-socket","docker-socket","outbound-network","podman-socket","ssh-agent-socket","systemd-socket"]' ] \
    || fail "hostile fixture check set changed: $ids"
  present_path="$TMP_ROOT/present-not-socket"
  : > "$present_path"
  python3 - "$FIXTURE" "$present_path" <<'PY' \
    || fail "a present but unreachable control path passed the absence assertion"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hostile_fixture", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result = module.socket_check("mutation", [sys.argv[2]])
raise SystemExit(0 if result["verdict"] == "fail" else 1)
PY
  pass "hostile fixture attempts every non-negotiable control-plane and egress check"
}

test_docker_unsupported_host_is_informative_only() {
  local host="$TMP_ROOT/fedora-host.json" fakebin result
  fakebin=$(fm_fakebin "$TMP_ROOT/docker")
  cat > "$fakebin/sbx" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/sbx"
  jq -n '{
    os: "linux",
    distribution: "fedora",
    distributionVersion: "44",
    architecture: "x86_64",
    fingerprint: ("a" * 64),
    kvm: {devicePresent: true, readable: true, writable: true, moduleLoaded: true}
  }' > "$host"
  result=$(PATH="$fakebin:$PATH" "$DOCKER_ADAPTER" measure "$CONFIG" "$host" "$FIXTURE") \
    || fail "Docker adapter did not return unsupported-host evidence"
  jq -e '
    .adapter.hostEligibility.status == "unsupported-host" and
    .adapter.hostEligibility.vendorSupported == false and
    .informativeOnly == true and
    .fixture.verdict == "not-run" and
    .verdict.explanation == "This unsupported-host result is informative evidence only and must never support a containment claim."
  ' <<<"$result" >/dev/null || fail "unsupported Docker evidence could be mistaken for containment proof"
  pass "Docker measurement labels unsupported Fedora evidence as informative only"
}

write_passing_evidence() {
  local destination=$1 host config_sha fixture_sha implementation_sha checks
  host=$("$CAPSULE" host)
  config_sha=$(sha256sum "$CONFIG" | awk '{print $1}')
  fixture_sha=$(sha256sum "$FIXTURE" | awk '{print $1}')
  implementation_sha=$(sha256sum "$PODMAN_ADAPTER" | awk '{print $1}')
  checks=$(jq -c '[.requiredChecks[] | {id: ., verdict: "pass"}]' "$CONFIG")
  jq -nS \
    --argjson host "$host" \
    --arg configSha "$config_sha" \
    --arg fixtureSha "$fixture_sha" \
    --arg implementationSha "$implementation_sha" \
    --argjson checks "$checks" '
      {
        schema: 1,
        host: $host,
        adapter: {
          adapter: "podman-rootless",
          implementationSha256: $implementationSha,
          hostEligibility: {status: "supported", vendorSupported: true}
        },
        config: {sha256: $configSha, profile: "marooned-hostile-v1"},
        fixture: {
          schema: 1,
          fixture: "marooned-hostile-v1",
          sha256: $fixtureSha,
          checks: $checks,
          summary: {pass: ($checks | length), fail: 0, failedChecks: []},
          verdict: "pass"
        },
        execution: {status: "completed"},
        informativeOnly: false,
        verdict: {status: "pass", code: "verified-for-hostile-v1"}
      }
    ' > "$destination"
}

test_arm_binds_current_boot_policy_fixture_and_implementation() {
  local evidence="$TMP_ROOT/evidence" out docker_implementation_sha
  mkdir -p "$evidence"
  write_passing_evidence "$evidence/podman-rootless.json"
  out=$("$CAPSULE" arm --adapter podman-rootless --evidence-dir "$evidence") \
    || fail "complete current evidence did not arm"
  jq -e '.status == "armed" and .adapter == "podman-rootless"' <<<"$out" >/dev/null \
    || fail "arm did not name the proved adapter"

  jq '.informativeOnly = true' "$evidence/podman-rootless.json" > "$evidence/invalid.json"
  mv "$evidence/invalid.json" "$evidence/podman-rootless.json"
  run_expect_failure "Advisory shaping is not containment" \
    "$CAPSULE" arm --adapter podman-rootless --evidence-dir "$evidence"

  write_passing_evidence "$evidence/podman-rootless.json"
  jq '.adapter.implementationSha256 = ("0" * 64)' "$evidence/podman-rootless.json" > "$evidence/invalid.json"
  mv "$evidence/invalid.json" "$evidence/podman-rootless.json"
  run_expect_failure "evidence-does-not-prove-required-floor" \
    "$CAPSULE" arm --adapter podman-rootless --evidence-dir "$evidence"

  write_passing_evidence "$evidence/podman-rootless.json"
  jq '.informativeOnly = true' "$evidence/podman-rootless.json" > "$evidence/invalid.json"
  mv "$evidence/invalid.json" "$evidence/podman-rootless.json"
  docker_implementation_sha=$(sha256sum "$DOCKER_ADAPTER" | awk '{print $1}')
  jq --arg implementationSha "$docker_implementation_sha" '
    .adapter.adapter = "docker-sandboxes" |
    .adapter.implementationSha256 = $implementationSha
  ' "$evidence/podman-rootless.json" > "$evidence/docker-sandboxes.json"
  jq '.informativeOnly = false' "$evidence/docker-sandboxes.json" > "$evidence/valid.json"
  mv "$evidence/valid.json" "$evidence/docker-sandboxes.json"
  run_expect_failure "evidence-does-not-prove-required-floor" \
    "$CAPSULE" arm --evidence-dir "$evidence"
  pass "arm refuses informative or stale implementation evidence instead of degrading"
}

test_committed_measurements_preserve_claim_boundaries() {
  local evidence="$ROOT/docs/verification/containment-results/fedora-44"
  jq -e '
    .host.distribution == "fedora" and
    .host.distributionVersion == "44" and
    .adapter.adapter == "podman-rootless" and
    .adapter.hostEligibility.status == "supported" and
    .fixture.summary == {fail: 0, failedChecks: [], pass: 8} and
    .informativeOnly == false and
    .verdict.code == "verified-for-hostile-v1"
  ' "$evidence/podman-rootless.json" >/dev/null || fail "committed Podman measurement lost its bounded passing claim"
  jq -e '
    .host.distribution == "fedora" and
    .host.distributionVersion == "44" and
    .adapter.adapter == "docker-sandboxes" and
    .adapter.hostEligibility.status == "unsupported-host" and
    .informativeOnly == true and
    .verdict.code == "unsupported-host" and
    .verdict.explanation == "This unsupported-host result is informative evidence only and must never support a containment claim."
  ' "$evidence/docker-sandboxes.json" >/dev/null || fail "committed Docker measurement overstated unsupported-host evidence"
  pass "committed Fedora measurements retain supported and unsupported claim labels"
}

test_configuration_is_strict_and_orders_two_real_adapters
test_hostile_fixture_covers_the_required_floor
test_docker_unsupported_host_is_informative_only
test_arm_binds_current_boot_policy_fixture_and_implementation
test_committed_measurements_preserve_claim_boundaries
