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

test_hostile_fixture_records_denial_when_a_socket_cannot_be_created() {
  # A host with no IPv6 stack cannot create an AF_INET6 socket at all, which is
  # exactly the egress denial this check exists to observe. Record it as an
  # observation distinct from connect-denied instead of aborting the whole run.
  python3 - "$FIXTURE" <<'FIXTUREPY' \
    || fail "a socket that could not be created aborted the fixture instead of recording a denial"
import importlib.util
import socket
import sys

spec = importlib.util.spec_from_file_location("hostile_fixture", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RefusingSockets:
    """Socket construction fails the way a missing address family makes it fail."""

    AF_INET6 = socket.AF_INET6
    SOCK_STREAM = socket.SOCK_STREAM

    @staticmethod
    def socket(*_args, **_kwargs):
        raise OSError(97, "Address family not supported by protocol")

    @staticmethod
    def getaddrinfo(*_args, **_kwargs):
        return [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2606:4700:10::6814:179a", 443, 0, 0))]


module.socket = RefusingSockets
observations = [
    module.tcp_attempt("literal-ipv6", "2606:4700:4700::1111", 443, RefusingSockets.AF_INET6),
    module.dns_tcp_attempt(),
]
raise SystemExit(
    0
    if all(item["outcome"] == "socket-unavailable" and item["reachable"] is False for item in observations)
    else 1
)
FIXTUREPY
  pass "hostile fixture records an unavailable socket as a denial rather than crashing"
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

# adapter_implementation <adapter>: the tracked implementation path whose digest
# arm binds the evidence to.
adapter_implementation() {
  case "$1" in
    podman-rootless) printf '%s\n' "$PODMAN_ADAPTER" ;;
    docker-sandboxes) printf '%s\n' "$DOCKER_ADAPTER" ;;
    *) fail "unknown adapter: $1" ;;
  esac
}

# write_passing_evidence <destination> [adapter]: evidence that arms on this exact
# host, boot, configuration, fixture, and adapter implementation.
write_passing_evidence() {
  local destination=$1 adapter=${2:-podman-rootless} host config_sha fixture_sha implementation_sha checks
  host=$("$CAPSULE" host)
  config_sha=$(sha256sum "$CONFIG" | awk '{print $1}')
  fixture_sha=$(sha256sum "$FIXTURE" | awk '{print $1}')
  implementation_sha=$(sha256sum "$(adapter_implementation "$adapter")" | awk '{print $1}')
  checks=$(jq -c '[.requiredChecks[] | {id: ., verdict: "pass"}]' "$CONFIG")
  jq -nS \
    --argjson host "$host" \
    --arg adapter "$adapter" \
    --arg configSha "$config_sha" \
    --arg fixtureSha "$fixture_sha" \
    --arg implementationSha "$implementation_sha" \
    --argjson checks "$checks" '
      {
        schema: 1,
        host: $host,
        adapter: {
          adapter: $adapter,
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
  local evidence="$TMP_ROOT/evidence" out first_candidate second_candidate
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

  # Degradation is only observable against THIS host's candidate order: give the
  # first candidate informative-only evidence and the second complete evidence,
  # so a refusal proves arm never switches past a failed candidate. Naming the
  # adapters directly would only exercise that on hosts whose order happens to
  # start with the one being spoiled.
  first_candidate=$("$CAPSULE" candidates | jq -r '.candidates[0]')
  second_candidate=$("$CAPSULE" candidates | jq -r '.candidates[1]')
  [ -n "$first_candidate" ] && [ -n "$second_candidate" ] \
    && [ "$first_candidate" != "$second_candidate" ] \
    || fail "this host does not order two distinct candidates to test degradation against"
  write_passing_evidence "$evidence/$first_candidate.json" "$first_candidate"
  jq '.informativeOnly = true' "$evidence/$first_candidate.json" > "$evidence/invalid.json"
  mv "$evidence/invalid.json" "$evidence/$first_candidate.json"
  write_passing_evidence "$evidence/$second_candidate.json" "$second_candidate"
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

test_committed_measurement_fixture_digest_is_current_or_documented() {
  # arm binds evidence to the fixture digest, so editing the fixture silently
  # retires the committed Fedora measurement. Either the evidence was re-taken
  # against the current fixture, or the containment page says so in the open.
  local evidence="$ROOT/docs/verification/containment-results/fedora-44" current recorded file
  current=$(sha256sum "$FIXTURE" | awk '{print $1}')
  for file in "$evidence/podman-rootless.json" "$evidence/docker-sandboxes.json"; do
    recorded=$(jq -r '.fixture.sha256' "$file") || fail "committed measurement lost its fixture digest: $file"
    [ "$recorded" = "$current" ] && continue
    grep -q "$recorded" "$ROOT/docs/containment.md" \
      || fail "committed evidence predates the current fixture and docs/containment.md does not record digest $recorded"
    grep -q "predates the current hostile fixture" "$ROOT/docs/containment.md" \
      || fail "docs/containment.md does not state that the Fedora evidence predates the current hostile fixture"
  done
  pass "committed Fedora evidence either binds the current fixture or is documented as predating it"
}

test_configuration_is_strict_and_orders_two_real_adapters
test_hostile_fixture_covers_the_required_floor
test_hostile_fixture_records_denial_when_a_socket_cannot_be_created
test_docker_unsupported_host_is_informative_only
test_arm_binds_current_boot_policy_fixture_and_implementation
test_committed_measurements_preserve_claim_boundaries
test_committed_measurement_fixture_digest_is_current_or_documented
