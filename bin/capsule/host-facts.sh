#!/usr/bin/env bash
# host-facts.sh - emit canonical, secret-free host facts for capsule evidence.
#
# Usage:
#   bin/capsule/host-facts.sh
#
# The boot-id digest intentionally binds arm evidence to one host boot without
# publishing the boot ID itself. A reboot requires a fresh measurement.
set -eu

os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
architecture=$(uname -m)
kernel_release=$(uname -r)
distribution=unknown
distribution_version=unknown

if [ -r /etc/os-release ]; then
  distribution=$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d '"')
  distribution_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d '"')
  [ -n "$distribution" ] || distribution=unknown
  [ -n "$distribution_version" ] || distribution_version=unknown
elif [ "$os_name" = darwin ]; then
  distribution=macos
  distribution_version=$(sw_vers -productVersion 2>/dev/null || printf 'unknown\n')
fi

boot_id_sha256=unavailable
if [ -r /proc/sys/kernel/random/boot_id ]; then
  boot_id_sha256=$(sha256sum /proc/sys/kernel/random/boot_id | awk '{print $1}')
fi

kvm_device=false
kvm_readable=false
kvm_writable=false
kvm_module=false
[ -e /dev/kvm ] && kvm_device=true
[ -r /dev/kvm ] && kvm_readable=true
[ -w /dev/kvm ] && kvm_writable=true
if [ -d /sys/module/kvm ] || [ -d /sys/module/kvm_intel ] || [ -d /sys/module/kvm_amd ]; then
  kvm_module=true
fi

base=$(jq -cnS \
  --arg os "$os_name" \
  --arg distribution "$distribution" \
  --arg distributionVersion "$distribution_version" \
  --arg architecture "$architecture" \
  --arg kernelRelease "$kernel_release" \
  --arg bootIdSha256 "$boot_id_sha256" \
  --argjson kvmDevice "$kvm_device" \
  --argjson kvmReadable "$kvm_readable" \
  --argjson kvmWritable "$kvm_writable" \
  --argjson kvmModule "$kvm_module" \
  '{
    os: $os,
    distribution: $distribution,
    distributionVersion: $distributionVersion,
    architecture: $architecture,
    kernelRelease: $kernelRelease,
    bootIdSha256: $bootIdSha256,
    kvm: {
      devicePresent: $kvmDevice,
      readable: $kvmReadable,
      writable: $kvmWritable,
      moduleLoaded: $kvmModule
    }
  }')
fingerprint=$(printf '%s' "$base" | sha256sum | awk '{print $1}')
printf '%s\n' "$base" | jq -cS --arg fingerprint "$fingerprint" '. + {fingerprint: $fingerprint}'
