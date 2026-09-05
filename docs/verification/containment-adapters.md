# Capsule adapter verification

**Verified:** This is dated maintainer evidence for the first Marooned capsule slice.

## Claim labels

**Verified:** A verified statement below is supported by the committed machine result, the named command output, or a linked vendor support document.

**Unverified:** An unverified statement below is outside the evidence produced by this measurement.

## Measurement identity

**Verified:** Both adapter measurements ran on 2026-08-24 against Fedora Linux 44, kernel `7.1.8-200.fc44.x86_64`, architecture `x86_64`, and host fingerprint `12f5043b274de2912b9e3e51585791b2c55f974c69b16b543e34d860cd03bf9c`.

**Verified:** The host had loaded KVM modules and a readable and writable `/dev/kvm` device.

**Verified:** Both results bind policy SHA-256 `1bc199b92d5a6cd597b59c508d1a8c5ee76c6a54272c807481012146411b328b` and hostile-fixture SHA-256 `b408f43b9eab086dcb3938ef6ce0441532a91a7fea98168ec016bb4c56eb8433`.

**Verified:** That fixture digest is no longer the digest of `bin/capsule/hostile-fixture.py`, which changed after this measurement to record an unopenable address family as a denial, so this page is a dated record and not a current arming claim.

**Verified:** The measurement command was `bin/fm-capsule.sh measure-all --output-dir docs/verification/containment-results/fedora-44`.

**Verified:** The arm check command was `bin/fm-capsule.sh arm --evidence-dir docs/verification/containment-results/fedora-44`.

## Results

| Claim label | Adapter | Host eligibility | Fixture execution | Result | Evidence |
| --- | --- | --- | --- | --- | --- |
| Verified | rootless Podman | supported | completed, 8 pass and 0 fail | `verified-for-hostile-v1` | [`podman-rootless.json`](containment-results/fedora-44/podman-rootless.json) |
| Verified | Docker Sandboxes | `unsupported-host` | not run because `sbx` was unavailable | informative only, never containment proof | [`docker-sandboxes.json`](containment-results/fedora-44/docker-sandboxes.json) |

**Verified:** The rootless Podman run used Podman 5.8.4 in rootless mode with cgroup v2 and the exact image manifest `docker.io/library/python@sha256:0ad7f98a97b1b8fcc226f5cbe49f0b95cd6f624582cdc6fbf7e41312075cb401`.

**Verified:** The Podman fixture observed every listed control socket absent and observed literal IPv4, literal IPv6, and DNS-based outbound attempts denied.

**Verified:** The Podman result passed the configured minimum floor for that exact boot, policy, fixture, and adapter implementation, so the arm check selected `podman-rootless`.

**Unverified:** The Podman result does not prove any property outside the eight checks in `marooned-hostile-v1`.

**Verified:** Docker documents Docker Sandboxes host support as Ubuntu 24.04 or later, macOS 14 or later on Apple silicon, or Windows 11 with Windows Hypervisor Platform in its [installation guide](https://docs.docker.com/ai/sandboxes/install/).

**Verified:** Fedora 44 is outside that vendor host matrix, so the Docker result is labelled `unsupported-host` even though KVM passed.

**Verified:** This unsupported-host result is informative evidence only and must never support a containment claim.

**Unverified:** The Docker fixture did not execute because the `sbx` executable was unavailable on this host.

**Unverified:** No Docker Sandboxes containment property is established by this Fedora result.

## Reproduction notes

**Verified:** A second Fedora operator can reproduce the Podman measurement by installing rootless Podman, pre-pulling the pinned image digest, and running the commands documented in [`docs/containment.md`](../containment.md#reproduce-a-measurement).

**Verified:** A second operator can reproduce the Docker eligibility result with the same `measure-all` command whether or not `sbx` is installed, while actual fixture execution requires an installed working `sbx` CLI.

**Verified:** A reboot changes the host fingerprint, so the committed evidence intentionally refuses to arm on a later boot.

**Verified:** Editing the policy, fixture, or adapter implementation changes a bound SHA-256 value, so the old evidence intentionally refuses to arm.

**Unverified:** Reproduction on a different host produces new evidence and cannot extend this Fedora measurement into a cross-host guarantee.
