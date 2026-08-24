#!/usr/bin/env bash
# podman-rootless.sh - rootless Podman capsule measurement adapter.
#
# Private adapter interface:
#   podman-rootless.sh probe <config-json> <host-json>
#   podman-rootless.sh measure <config-json> <host-json> <fixture.py>
#
# A measurement uses an exact image digest, a fresh container, no network,
# a read-only root, no capabilities, no host bind mounts, and the fixture on
# stdin. Environment proxy variables are not an enforcement mechanism here.
set -eu

usage() {
  printf 'usage: %s probe <config-json> <host-json>\n' "$0" >&2
  printf '       %s measure <config-json> <host-json> <fixture.py>\n' "$0" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
operation=$1
config=$2
host_file=$3
fixture=${4:-}

[ -r "$config" ] || { printf 'podman-rootless: config is unreadable: %s\n' "$config" >&2; exit 2; }
[ -r "$host_file" ] || { printf 'podman-rootless: host facts are unreadable: %s\n' "$host_file" >&2; exit 2; }
jq -e . "$config" >/dev/null || { printf 'podman-rootless: config is invalid JSON\n' >&2; exit 2; }
jq -e . "$host_file" >/dev/null || { printf 'podman-rootless: host facts are invalid JSON\n' >&2; exit 2; }

host_os=$(jq -r '.os' "$host_file")
host_supported=false
[ "$host_os" = linux ] && host_supported=true

runtime_available=false
runtime_version=unavailable
rootless=false
cgroup_version=unavailable
probe_error=
if command -v podman >/dev/null 2>&1; then
  runtime_available=true
  runtime_version=$(podman --version 2>&1 || true)
  set +e
  info=$(podman info --format json 2>&1)
  info_rc=$?
  set -e
  if [ "$info_rc" -eq 0 ] && printf '%s\n' "$info" | jq -e . >/dev/null 2>&1; then
    rootless=$(printf '%s\n' "$info" | jq -r '.host.security.rootless // false')
    cgroup_version=$(printf '%s\n' "$info" | jq -r '.host.cgroupVersion // "unavailable"')
  else
    probe_error=$info
  fi
fi

eligibility_status=supported
eligibility_reason='Linux host and rootless Podman runtime are available.'
if [ "$host_supported" != true ]; then
  eligibility_status='unsupported-host'
  eligibility_reason='This first adapter implementation supports Linux only.'
elif [ "$runtime_available" != true ]; then
  eligibility_status='adapter-unavailable'
  eligibility_reason='The podman executable is unavailable.'
elif [ "$rootless" != true ]; then
  eligibility_status='untrusted-runtime'
  eligibility_reason='Podman did not report rootless mode.'
elif [ "$cgroup_version" != v2 ]; then
  eligibility_status='unsupported-host'
  eligibility_reason='The measured host does not provide cgroup v2 to rootless Podman.'
fi

probe=$(jq -cnS \
  --arg adapter podman-rootless \
  --arg status "$eligibility_status" \
  --arg reason "$eligibility_reason" \
  --arg version "$runtime_version" \
  --arg cgroupVersion "$cgroup_version" \
  --arg probeError "$probe_error" \
  --argjson hostSupported "$host_supported" \
  --argjson runtimeAvailable "$runtime_available" \
  --argjson rootless "$rootless" \
  '{
    adapter: $adapter,
    hostEligibility: {status: $status, reason: $reason, vendorSupported: $hostSupported},
    runtime: {
      available: $runtimeAvailable,
      version: $version,
      rootless: $rootless,
      cgroupVersion: $cgroupVersion,
      probeError: (if $probeError == "" then null else $probeError end)
    }
  }')

if [ "$operation" = probe ]; then
  printf '%s\n' "$probe"
  exit 0
fi
[ "$operation" = measure ] || usage
[ -r "$fixture" ] || { printf 'podman-rootless: fixture is unreadable: %s\n' "$fixture" >&2; exit 2; }

measured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
config_sha256=$(sha256sum "$config" | awk '{print $1}')
fixture_sha256=$(sha256sum "$fixture" | awk '{print $1}')
implementation_sha256=$(sha256sum "$0" | awk '{print $1}')
host=$(jq -cS . "$host_file")
fixture_result='{"schema":1,"fixture":"marooned-hostile-v1","checks":[],"summary":{"pass":0,"fail":0,"failedChecks":[]},"verdict":"not-run"}'
execution_status='not-run'
execution_error=
image=$(jq -r '.adapters["podman-rootless"].fixtureImage' "$config")
image_identity=unavailable

if [ "$eligibility_status" = supported ]; then
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-capsule-podman.XXXXXX")
  fixture_out="$temp_dir/fixture.json"
  fixture_err="$temp_dir/fixture.stderr"
  cleanup() {
    case "$temp_dir" in
      "${TMPDIR:-/tmp}"/fm-capsule-podman.*) rm -rf "$temp_dir" ;;
      *) printf 'podman-rootless: refusing unsafe temporary cleanup: %s\n' "$temp_dir" >&2 ;;
    esac
  }
  trap cleanup EXIT INT TERM

  set +e
  image_identity=$(podman image inspect "$image" --format '{{.Digest}}' 2>&1)
  image_rc=$?
  set -e
  if [ "$image_rc" -ne 0 ]; then
    execution_status='adapter-unavailable'
    execution_error="Pinned fixture image is unavailable: $image_identity"
    image_identity=unavailable
  else
    set +e
    podman run --rm --interactive --network none --read-only --cap-drop ALL \
      --userns=auto --user 65532:65532 \
      --security-opt no-new-privileges --pids-limit 64 --memory 256m --cpus 1 \
      --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
      --env HOME=/home/capsule --env XDG_RUNTIME_DIR=/run/user/65532 --env SSH_AUTH_SOCK= \
      "$image" python3 - < "$fixture" > "$fixture_out" 2> "$fixture_err"
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
  fi
fi

fixture_verdict=$(printf '%s\n' "$fixture_result" | jq -r '.verdict')
verdict_status=fail
verdict_code='fixture-failed'
verdict_explanation='One or more hostile fixture checks reached a forbidden surface.'
informative_only=false
if [ "$eligibility_status" != supported ]; then
  verdict_status=$eligibility_status
  verdict_code=$eligibility_status
  verdict_explanation=$eligibility_reason
elif [ "$execution_status" != completed ]; then
  verdict_status=error
  verdict_code=$execution_status
  verdict_explanation='The adapter could not complete a valid hostile fixture run.'
elif [ "$fixture_verdict" = pass ]; then
  verdict_status=pass
  verdict_code='verified-for-hostile-v1'
  verdict_explanation='All checks in marooned-hostile-v1 passed for this exact host boot and adapter configuration.'
fi

jq -cnS \
  --arg measuredAt "$measured_at" \
  --arg configSha256 "$config_sha256" \
  --arg fixtureSha256 "$fixture_sha256" \
  --arg implementationSha256 "$implementation_sha256" \
  --arg image "$image" \
  --arg imageIdentity "$image_identity" \
  --arg executionStatus "$execution_status" \
  --arg executionError "$execution_error" \
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
      image: $image,
      imageIdentity: $imageIdentity,
      configuredEnforcement: {
        network: "none",
        rootFilesystem: "read-only",
        hostBindMounts: "none",
        capabilities: "drop-all",
        noNewPrivileges: true,
        user: "65532:65532",
        userNamespace: "auto"
      }
    }),
    fixture: ({sha256: $fixtureSha256} + $fixtureResult),
    execution: {
      status: $executionStatus,
      error: (if $executionError == "" then null else $executionError end)
    },
    informativeOnly: $informativeOnly,
    verdict: {status: $verdictStatus, code: $verdictCode, explanation: $verdictExplanation}
  }'
