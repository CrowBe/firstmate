#!/usr/bin/env bash
# fm-capsule.sh - configure, measure, and fail-closed arm capsule adapters.
#
# Usage:
#   bin/fm-capsule.sh host
#   bin/fm-capsule.sh validate [--config <path>]
#   bin/fm-capsule.sh candidates [--config <path>]
#   bin/fm-capsule.sh probe --adapter <id> [--config <path>]
#   bin/fm-capsule.sh measure --adapter <id> --output <result.json> [--config <path>]
#   bin/fm-capsule.sh measure-all --output-dir <dir> [--config <path>]
#   bin/fm-capsule.sh arm --evidence-dir <dir> [--adapter <id>] [--config <path>]
#
# The internal config is used unless an explicit path is supplied or
# $FM_HOME/config/containment.json exists. Configuration may order candidates;
# it cannot declare one verified. `arm` requires a passing measurement from the
# current boot, exact config, exact fixture, and a vendor-supported host.
# Unsupported-host measurements remain informative evidence only.
# `advisoryShaping` and `onUnsatisfied` accept only `refuse`.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEFAULT_CONFIG="$ROOT/bin/capsule/default-config.json"
HOST_FACTS="$ROOT/bin/capsule/host-facts.sh"
FIXTURE="$ROOT/bin/capsule/hostile-fixture.py"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit 2
}

die() {
  printf 'fm-capsule: %s\n' "$*" >&2
  exit 2
}

resolve_config() {
  explicit=$1
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
  elif [ -n "${FM_HOME:-}" ] && [ -r "$FM_HOME/config/containment.json" ]; then
    printf '%s\n' "$FM_HOME/config/containment.json"
  else
    printf '%s\n' "$DEFAULT_CONFIG"
  fi
}

validate_config() {
  config=$1
  [ -r "$config" ] || die "configuration is unreadable: $config"
  jq -e '
    def only($allowed): ((keys - $allowed) | length) == 0;
    type == "object" and
    only(["schema", "profile", "claimStatus", "armPolicy", "requiredChecks", "hostCandidateOrder", "adapters"]) and
    .schema == 1 and
    .profile == "marooned-hostile-v1" and
    .claimStatus == "unverified-until-measured" and
    (.armPolicy | type == "object" and
      only(["requireSameBoot", "advisoryShaping", "onUnsatisfied"]) and
      .requireSameBoot == true and
      .advisoryShaping == "refuse" and
      .onUnsatisfied == "refuse") and
    (.requiredChecks | sort) == ([
      "docker-socket",
      "podman-socket",
      "containerd-socket",
      "dbus-socket",
      "ssh-agent-socket",
      "systemd-socket",
      "cloud-control-socket",
      "outbound-network"
    ] | sort) and
    (.hostCandidateOrder | type == "array" and length > 0 and all(.[ ];
      type == "object" and
      only(["match", "candidates"]) and
      (.match | type == "object" and only(["os", "distribution"]) and
        (.os | type == "string" and length > 0) and
        (.distribution | type == "string" and length > 0)) and
      (.candidates | type == "array" and length > 0 and length == (unique | length) and all(.[]; type == "string" and length > 0)))) and
    (.adapters | type == "object" and (keys | sort) == ["docker-sandboxes", "podman-rootless"] and
      (. ["podman-rootless"] | type == "object" and
        only(["implementation", "vendorHostSupport", "fixtureImage"]) and
        (.implementation | type == "string") and
        (.vendorHostSupport | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))) and
      (. ["docker-sandboxes"] | type == "object" and
        only(["implementation", "vendorHostSupport", "measurementOnUnsupportedHost"]) and
        (.implementation | type == "string") and
        (.vendorHostSupport | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)))) and
    all(.hostCandidateOrder[].candidates[]; . as $id | $id != null) and
    ([.hostCandidateOrder[].candidates[]] - (.adapters | keys) | length) == 0 and
    .adapters["docker-sandboxes"].measurementOnUnsupportedHost == "informative-only" and
    (.adapters["podman-rootless"].fixtureImage | type == "string" and test("@sha256:[0-9a-f]{64}$"))
  ' "$config" >/dev/null || die "configuration is invalid or would permit advisory/degraded containment: $config"

  while IFS= read -r implementation; do
    case "$implementation" in
      bin/capsule/adapters/podman-rootless.sh|bin/capsule/adapters/docker-sandboxes.sh) ;;
      *) die "configuration names an unapproved adapter implementation: $implementation" ;;
    esac
    [ -x "$ROOT/$implementation" ] || die "adapter implementation is not executable: $implementation"
  done < <(jq -r '.adapters[].implementation' "$config")
}

write_host_file() {
  destination=$1
  "$HOST_FACTS" > "$destination"
  jq -e '.fingerprint | type == "string" and length == 64' "$destination" >/dev/null \
    || die "host probe emitted invalid evidence"
}

candidate_json() {
  config=$1 host_file=$2
  os_name=$(jq -r '.os' "$host_file")
  distribution=$(jq -r '.distribution' "$host_file")
  selector=$(jq -c \
    --arg os "$os_name" \
    --arg distribution "$distribution" \
    '[.hostCandidateOrder[] | select(
      .match.os == $os and
      (.match.distribution == "*" or .match.distribution == $distribution)
    )][0] // empty' "$config")
  [ -n "$selector" ] || return 1
  printf '%s\n' "$selector" | jq -cS \
    --argjson host "$(jq -cS . "$host_file")" \
    --arg profile "$(jq -r '.profile' "$config")" \
    '{profile: $profile, host: $host, matched: .match, candidates: .candidates}'
}

adapter_implementation() {
  config=$1 adapter=$2
  implementation=$(jq -r --arg adapter "$adapter" '.adapters[$adapter].implementation // empty' "$config")
  [ -n "$implementation" ] || die "unknown adapter: $adapter"
  printf '%s\n' "$ROOT/$implementation"
}

measure_one() {
  config=$1 host_file=$2 adapter=$3 output=$4
  implementation=$(adapter_implementation "$config" "$adapter")
  output_dir=$(dirname "$output")
  mkdir -p "$output_dir"
  temp_output=$(mktemp "$output.tmp.XXXXXX")
  cleanup_measure() {
    rm -f "$temp_output"
  }
  trap cleanup_measure EXIT INT TERM
  "$implementation" measure "$config" "$host_file" "$FIXTURE" > "$temp_output"
  jq -e --arg adapter "$adapter" '
    .schema == 1 and
    .adapter.adapter == $adapter and
    (.adapter.implementationSha256 | type == "string" and length == 64) and
    (.host.fingerprint | type == "string" and length == 64) and
    (.fixture.sha256 | type == "string" and length == 64) and
    (.verdict.status | type == "string" and length > 0)
  ' "$temp_output" >/dev/null || die "adapter emitted invalid measurement JSON: $adapter"
  jq -S . "$temp_output" > "$output"
  rm -f "$temp_output"
  trap - EXIT INT TERM
}

command_name=${1:-}
[ -n "$command_name" ] || usage
shift

config_arg=
adapter=
output=
output_dir=
evidence_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || usage; config_arg=$2; shift 2 ;;
    --adapter) [ "$#" -ge 2 ] || usage; adapter=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --output-dir) [ "$#" -ge 2 ] || usage; output_dir=$2; shift 2 ;;
    --evidence-dir) [ "$#" -ge 2 ] || usage; evidence_dir=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ "$command_name" = host ]; then
  [ -z "$config_arg$adapter$output$output_dir$evidence_dir" ] || usage
  exec "$HOST_FACTS"
fi

config=$(resolve_config "$config_arg")
validate_config "$config"

if [ "$command_name" = validate ]; then
  printf 'fm-capsule: valid config=%s sha256=%s\n' "$config" "$(sha256sum "$config" | awk '{print $1}')"
  exit 0
fi

host_file=$(mktemp "${TMPDIR:-/tmp}/fm-capsule-host.XXXXXX")
cleanup_host() {
  rm -f "$host_file"
}
trap cleanup_host EXIT INT TERM
write_host_file "$host_file"

case "$command_name" in
  candidates)
    candidate_json "$config" "$host_file" || die "no candidate order matches the current host"
    ;;
  probe)
    [ -n "$adapter" ] || usage
    implementation=$(adapter_implementation "$config" "$adapter")
    "$implementation" probe "$config" "$host_file"
    ;;
  measure)
    [ -n "$adapter" ] && [ -n "$output" ] || usage
    measure_one "$config" "$host_file" "$adapter" "$output"
    jq -cS '{adapter: .adapter.adapter, eligibility: .adapter.hostEligibility.status, verdict: .verdict.status, informativeOnly}' "$output"
    ;;
  measure-all)
    [ -n "$output_dir" ] || usage
    candidates=$(candidate_json "$config" "$host_file") || die "no candidate order matches the current host"
    summaries='[]'
    while IFS= read -r candidate; do
      result="$output_dir/$candidate.json"
      measure_one "$config" "$host_file" "$candidate" "$result"
      summary=$(jq -cS '{adapter: .adapter.adapter, eligibility: .adapter.hostEligibility.status, verdict: .verdict.status, informativeOnly}' "$result")
      summaries=$(jq -cn --argjson summaries "$summaries" --argjson summary "$summary" '$summaries + [$summary]')
    done < <(printf '%s\n' "$candidates" | jq -r '.candidates[]')
    jq -cnS --arg profile "$(jq -r '.profile' "$config")" --argjson results "$summaries" '{profile: $profile, results: $results}'
    ;;
  arm)
    [ -n "$evidence_dir" ] || usage
    candidates=$(candidate_json "$config" "$host_file") || die "no candidate order matches the current host"
    config_sha256=$(sha256sum "$config" | awk '{print $1}')
    fixture_sha256=$(sha256sum "$FIXTURE" | awk '{print $1}')
    host_fingerprint=$(jq -r '.fingerprint' "$host_file")
    required_checks=$(jq -c '.requiredChecks' "$config")
    refusals='[]'
    selected=
    while IFS= read -r candidate; do
      if [ -n "$adapter" ] && [ "$candidate" != "$adapter" ]; then
        continue
      fi
      result="$evidence_dir/$candidate.json"
      implementation=$(adapter_implementation "$config" "$candidate")
      implementation_sha256=$(sha256sum "$implementation" | awk '{print $1}')
      reason=
      if [ ! -r "$result" ]; then
        reason='evidence-missing'
      elif ! jq -e . "$result" >/dev/null 2>&1; then
        reason='evidence-invalid'
      elif ! jq -e \
        --arg candidate "$candidate" \
        --arg configSha256 "$config_sha256" \
        --arg fixtureSha256 "$fixture_sha256" \
        --arg implementationSha256 "$implementation_sha256" \
        --arg hostFingerprint "$host_fingerprint" \
        --argjson requiredChecks "$required_checks" '
          .schema == 1 and
          .adapter.adapter == $candidate and
          .config.profile == "marooned-hostile-v1" and
          .config.sha256 == $configSha256 and
          .fixture.schema == 1 and
          .fixture.fixture == "marooned-hostile-v1" and
          .fixture.sha256 == $fixtureSha256 and
          .adapter.implementationSha256 == $implementationSha256 and
          .host.fingerprint == $hostFingerprint and
          (.host.bootIdSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          .adapter.hostEligibility.status == "supported" and
          .adapter.hostEligibility.vendorSupported == true and
          .informativeOnly == false and
          .execution.status == "completed" and
          .fixture.verdict == "pass" and
          .fixture.summary.fail == 0 and
          .fixture.summary.pass == ($requiredChecks | length) and
          .fixture.summary.failedChecks == [] and
          .verdict.status == "pass" and
          .verdict.code == "verified-for-hostile-v1" and
          ([.fixture.checks[].id] | sort) == ($requiredChecks | sort) and
          all(.fixture.checks[]; .verdict == "pass")
        ' "$result" >/dev/null; then
        reason='evidence-does-not-prove-required-floor'
      else
        selected=$candidate
        jq -cnS \
          --arg adapter "$candidate" \
          --arg profile "$(jq -r '.profile' "$config")" \
          --arg evidence "$result" \
          --arg policySha256 "$config_sha256" \
          --arg hostFingerprint "$host_fingerprint" \
          '{status: "armed", adapter: $adapter, profile: $profile, evidence: $evidence, policySha256: $policySha256, hostFingerprint: $hostFingerprint}'
        break
      fi
      refusal=$(jq -cn --arg adapter "$candidate" --arg reason "$reason" '{adapter: $adapter, reason: $reason}')
      refusals=$(jq -cn --argjson refusals "$refusals" --argjson refusal "$refusal" '$refusals + [$refusal]')
      if [ "$reason" = 'evidence-missing' ] || [ "$reason" = 'evidence-invalid' ]; then
        break
      fi
      if jq -e '.adapter.hostEligibility.status == "supported"' "$result" >/dev/null 2>&1; then
        break
      fi
    done < <(printf '%s\n' "$candidates" | jq -r '.candidates[]')
    if [ -z "$selected" ]; then
      if [ -n "$adapter" ] && ! printf '%s\n' "$candidates" | jq -e --arg adapter "$adapter" '.candidates | index($adapter) != null' >/dev/null; then
        refusals=$(jq -cn --argjson refusals "$refusals" --arg adapter "$adapter" '$refusals + [{adapter: $adapter, reason: "adapter-not-in-host-candidate-order"}]')
      fi
      jq -cnS \
        --arg profile "$(jq -r '.profile' "$config")" \
        --argjson refusals "$refusals" \
        '{status: "refused", code: "adapter-unverified", profile: $profile, refusals: $refusals, explanation: "Advisory shaping is not containment; no candidate has current proof for every required check."}'
      exit 1
    fi
    ;;
  *) usage ;;
esac
