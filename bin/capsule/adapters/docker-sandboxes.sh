#!/usr/bin/env bash
# docker-sandboxes.sh - Docker Sandboxes capsule measurement adapter.
#
# Private adapter interface:
#   docker-sandboxes.sh probe <config-json> <host-json>
#   docker-sandboxes.sh measure <config-json> <host-json> <fixture.py>
#
# The adapter may measure an unsupported host, but such evidence is always
# informative-only and can never arm containment. It creates only a uniquely
# named shell sandbox over a synthetic workspace and removes that exact sandbox.
set -eu

usage() {
  printf 'usage: %s probe <config-json> <host-json>\n' "$0" >&2
  printf '       %s measure <config-json> <host-json> <fixture.py>\n' "$0" >&2
  exit 2
}

version_at_least() {
  current=$1 minimum=$2
  [ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n 1)" = "$minimum" ]
}

[ "$#" -ge 3 ] || usage
operation=$1
config=$2
host_file=$3
fixture=${4:-}

[ -r "$config" ] || { printf 'docker-sandboxes: config is unreadable: %s\n' "$config" >&2; exit 2; }
[ -r "$host_file" ] || { printf 'docker-sandboxes: host facts are unreadable: %s\n' "$host_file" >&2; exit 2; }
jq -e . "$config" >/dev/null || { printf 'docker-sandboxes: config is invalid JSON\n' >&2; exit 2; }
jq -e . "$host_file" >/dev/null || { printf 'docker-sandboxes: host facts are invalid JSON\n' >&2; exit 2; }

host_os=$(jq -r '.os' "$host_file")
distribution=$(jq -r '.distribution' "$host_file")
distribution_version=$(jq -r '.distributionVersion' "$host_file")
architecture=$(jq -r '.architecture' "$host_file")
kvm_available=$(jq -r '.kvm.devicePresent and .kvm.readable and .kvm.writable and .kvm.moduleLoaded' "$host_file")
host_supported=false
host_reason='Docker Sandboxes supports Ubuntu 24.04+, macOS 14+ on Apple silicon, or Windows 11; this adapter measured a different host.'
if [ "$host_os" = linux ] && [ "$distribution" = ubuntu ] && version_at_least "$distribution_version" 24.04; then
  host_supported=true
  host_reason='The Linux distribution is inside Docker Sandboxes documented support and KVM is checked separately.'
elif [ "$host_os" = darwin ] && [ "$architecture" = arm64 ] && version_at_least "$distribution_version" 14; then
  host_supported=true
  host_reason='The macOS version and architecture are inside Docker Sandboxes documented support.'
fi

runtime_available=false
runtime_version=unavailable
runtime_probe_error=
if command -v sbx >/dev/null 2>&1; then
  runtime_available=true
  set +e
  runtime_version=$(sbx version 2>&1)
  version_rc=$?
  set -e
  if [ "$version_rc" -ne 0 ]; then
    runtime_probe_error=$runtime_version
    runtime_version=unavailable
  fi
fi

prerequisite_status=pass
prerequisite_reason='No Linux KVM prerequisite applies to this host classification.'
if [ "$host_os" = linux ]; then
  if [ "$kvm_available" = true ]; then
    prerequisite_reason='KVM is loaded and /dev/kvm is readable and writable.'
  else
    prerequisite_status=fail
    prerequisite_reason='The Linux KVM prerequisite is not satisfied.'
  fi
fi

eligibility_status=supported
eligibility_reason=$host_reason
if [ "$host_supported" != true ]; then
  eligibility_status='unsupported-host'
elif [ "$prerequisite_status" != pass ]; then
  eligibility_status='unsupported-host'
  eligibility_reason=$prerequisite_reason
elif [ "$runtime_available" != true ]; then
  eligibility_status='adapter-unavailable'
  eligibility_reason='The sbx executable is unavailable.'
elif [ "$runtime_version" = unavailable ]; then
  eligibility_status='adapter-unavailable'
  eligibility_reason='The sbx executable did not return a version.'
fi

probe=$(jq -cnS \
  --arg adapter docker-sandboxes \
  --arg status "$eligibility_status" \
  --arg reason "$eligibility_reason" \
  --arg version "$runtime_version" \
  --arg runtimeProbeError "$runtime_probe_error" \
  --arg prerequisiteStatus "$prerequisite_status" \
  --arg prerequisiteReason "$prerequisite_reason" \
  --argjson hostSupported "$host_supported" \
  --argjson runtimeAvailable "$runtime_available" \
  '{
    adapter: $adapter,
    hostEligibility: {status: $status, reason: $reason, vendorSupported: $hostSupported},
    prerequisites: {kvm: {status: $prerequisiteStatus, reason: $prerequisiteReason}},
    runtime: {
      available: $runtimeAvailable,
      version: $version,
      probeError: (if $runtimeProbeError == "" then null else $runtimeProbeError end)
    }
  }')

if [ "$operation" = probe ]; then
  printf '%s\n' "$probe"
  exit 0
fi
[ "$operation" = measure ] || usage
[ -r "$fixture" ] || { printf 'docker-sandboxes: fixture is unreadable: %s\n' "$fixture" >&2; exit 2; }

measured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
config_sha256=$(sha256sum "$config" | awk '{print $1}')
fixture_sha256=$(sha256sum "$fixture" | awk '{print $1}')
implementation_sha256=$(sha256sum "$0" | awk '{print $1}')
host=$(jq -cS . "$host_file")
fixture_result='{"schema":1,"fixture":"marooned-hostile-v1","checks":[],"summary":{"pass":0,"fail":0,"failedChecks":[]},"verdict":"not-run"}'
execution_status='not-run'
execution_error=
cleanup_status='not-created'
cleanup_error=
informative_only=false
[ "$host_supported" = true ] || informative_only=true

if [ "$runtime_available" = true ] && [ "$runtime_version" != unavailable ] && [ "$prerequisite_status" = pass ]; then
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/fm-capsule-sbx.XXXXXX")
  sandbox_name="fm-measure-$$-$(date +%s)"
  fixture_out="$workspace/fixture.json"
  fixture_err="$workspace/fixture.stderr"
  created=0
  cleanup() {
    if [ "$created" -eq 1 ]; then
      if sbx rm "$sandbox_name" >/dev/null 2>"$workspace/cleanup.stderr"; then
        cleanup_status=removed
      else
        cleanup_status='cleanup-incomplete'
        cleanup_error=$(sed -n '1,20p' "$workspace/cleanup.stderr")
      fi
      created=0
    fi
    case "$workspace" in
      "${TMPDIR:-/tmp}"/fm-capsule-sbx.*) rm -rf "$workspace" ;;
      *) printf 'docker-sandboxes: refusing unsafe temporary cleanup: %s\n' "$workspace" >&2 ;;
    esac
  }
  trap cleanup EXIT INT TERM

  set +e
  sbx create --name "$sandbox_name" --deny-network '**' shell "$workspace" >"$workspace/create.stdout" 2>"$workspace/create.stderr"
  create_rc=$?
  set -e
  if [ "$create_rc" -ne 0 ]; then
    execution_status='adapter-unavailable'
    execution_error=$(sed -n '1,20p' "$workspace/create.stderr")
    [ -n "$execution_error" ] || execution_error="sbx create exited $create_rc."
  else
    created=1
    set +e
    sbx exec -i -e HOME=/home/capsule -e XDG_RUNTIME_DIR=/run/user/65532 -e SSH_AUTH_SOCK= \
      "$sandbox_name" python3 - < "$fixture" > "$fixture_out" 2> "$fixture_err"
    fixture_rc=$?
    set -e
    if jq -e '.schema == 1 and .fixture == "marooned-hostile-v1" and (.checks | type == "array")' "$fixture_out" >/dev/null 2>&1; then
      fixture_result=$(jq -cS . "$fixture_out")
      execution_status=completed
      if [ "$fixture_rc" -ne 0 ] && [ "$(printf '%s\n' "$fixture_result" | jq -r '.verdict')" = pass ]; then
        execution_status='fixture-error'
        execution_error="Fixture exited $fixture_rc despite a passing result."
      fi
    else
      execution_status='fixture-error'
      execution_error=$(sed -n '1,20p' "$fixture_err")
      [ -n "$execution_error" ] || execution_error="Fixture emitted invalid JSON and exited $fixture_rc."
    fi
    cleanup
    trap - EXIT INT TERM
  fi
fi

fixture_verdict=$(printf '%s\n' "$fixture_result" | jq -r '.verdict')
verdict_status=fail
verdict_code='fixture-failed'
verdict_explanation='One or more hostile fixture checks reached a forbidden surface.'
if [ "$host_supported" != true ]; then
  verdict_status='unsupported-host'
  verdict_code='unsupported-host'
  verdict_explanation='This unsupported-host result is informative evidence only and must never support a containment claim.'
elif [ "$eligibility_status" != supported ]; then
  verdict_status=$eligibility_status
  verdict_code=$eligibility_status
  verdict_explanation=$eligibility_reason
elif [ "$execution_status" != completed ]; then
  verdict_status=error
  verdict_code=$execution_status
  verdict_explanation='The adapter could not complete a valid hostile fixture run.'
elif [ "$cleanup_status" != removed ]; then
  verdict_status=error
  verdict_code='cleanup-incomplete'
  verdict_explanation='The fixture ran, but the adapter could not prove its sandbox was removed.'
elif [ "$fixture_verdict" = pass ]; then
  verdict_status=pass
  verdict_code='verified-for-hostile-v1'
  verdict_explanation='All checks in marooned-hostile-v1 passed for this exact supported host boot and adapter configuration.'
fi

jq -cnS \
  --arg measuredAt "$measured_at" \
  --arg configSha256 "$config_sha256" \
  --arg fixtureSha256 "$fixture_sha256" \
  --arg implementationSha256 "$implementation_sha256" \
  --arg executionStatus "$execution_status" \
  --arg executionError "$execution_error" \
  --arg cleanupStatus "$cleanup_status" \
  --arg cleanupError "$cleanup_error" \
  --arg verdictStatus "$verdict_status" \
  --arg verdictCode "$verdict_code" \
  --arg verdictExplanation "$verdict_explanation" \
  --argjson host "$host" \
  --argjson probe "$probe" \
  --argjson fixtureResult "$fixture_result" \
  --argjson informativeOnly "$informative_only" \
  '{
    schema: 1,
    measuredAt: $measuredAt,
    host: $host,
    config: {sha256: $configSha256, profile: "marooned-hostile-v1"},
    adapter: ($probe + {
      implementationSha256: $implementationSha256,
      configuredEnforcement: {
        networkPolicy: "deny **",
        workspace: "synthetic-temporary-directory"
      }
    }),
    fixture: ({sha256: $fixtureSha256} + $fixtureResult),
    execution: {
      status: $executionStatus,
      error: (if $executionError == "" then null else $executionError end)
    },
    cleanup: {
      status: $cleanupStatus,
      error: (if $cleanupError == "" then null else $cleanupError end)
    },
    informativeOnly: $informativeOnly,
    verdict: {status: $verdictStatus, code: $verdictCode, explanation: $verdictExplanation}
  }'
