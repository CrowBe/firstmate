# Capsule containment

**Verified:** This page describes the operator-current first Marooned capsule slice.

## Claim labels

**Verified:** A verified statement is backed by the committed implementation, behavior tests, or the dated host measurement linked from this page.

**Unverified:** An unverified statement identifies a boundary that this slice does not prove.

## Current slice

**Verified:** The private capsule seam has concrete rootless Podman and Docker Sandboxes implementations behind one configuration and measurement command.

**Verified:** Configuration orders candidates per host, while only fresh evidence can arm one candidate.

**Unverified:** Candidate ordering does not make either adapter a reference, default containment implementation, or generally proved sandbox.

**Verified:** Fedora selects rootless Podman before Docker Sandboxes, Ubuntu selects Docker Sandboxes before rootless Podman, and other configured Linux distributions select rootless Podman before Docker Sandboxes.

**Verified:** If the first host-eligible candidate has incomplete or failing evidence, `arm` refuses instead of silently switching to the next candidate.

**Verified:** `arm` refuses unless evidence matches the current boot, configuration, hostile fixture, adapter implementation, supported-host eligibility, and every required passing check.

**Verified:** Advisory environment shaping cannot arm the capsule because the only accepted `advisoryShaping` and `onUnsatisfied` values are `refuse`.

**Unverified:** This slice does not implement work handoff admission, a Git shuttle, egress receipts, Sea Trials, a hosted adapter, a remote adapter, or a public adapter SDK.

## Configuration

**Verified:** [`bin/capsule/default-config.json`](../bin/capsule/default-config.json) is the tracked configuration and [`docs/examples/containment.json`](examples/containment.json) is its copyable operator example.

**Verified:** A readable `$FM_HOME/config/containment.json` overrides the tracked configuration, and an explicit `--config` path overrides both.

**Verified:** The configuration validator allows only the two private implementation paths shipped in this slice, so configuration cannot load arbitrary executable adapter paths.

**Verified:** The `marooned-hostile-v1` profile requires the complete eight-check floor, and removing, adding, or renaming a required check makes configuration invalid.

**Verified:** Copying the tracked example creates a home-local override without changing tracked policy.

```sh
mkdir -p config
cp docs/examples/containment.json config/containment.json
bin/fm-capsule.sh validate --config config/containment.json
```

**Verified:** Any valid change to candidate ordering or adapter settings changes the policy digest and invalidates older evidence.

## Reproduce a measurement

**Verified:** The following commands validate policy, display host selection, measure every candidate in the current host order, and attempt the fail-closed arm decision.

```sh
bin/fm-capsule.sh validate
bin/fm-capsule.sh candidates
bin/fm-capsule.sh measure-all --output-dir /tmp/fm-capsule-results
bin/fm-capsule.sh arm --evidence-dir /tmp/fm-capsule-results
```

**Verified:** The rootless Podman adapter requires the pinned fixture image to exist locally before measurement, and it refuses with `adapter-unavailable` instead of pulling implicitly.

```sh
podman pull docker.io/library/python@sha256:0ad7f98a97b1b8fcc226f5cbe49f0b95cd6f624582cdc6fbf7e41312075cb401
```

**Verified:** The Podman implementation sends the fixture over standard input into a fresh rootless container with no network, a read-only root, no host bind mounts, no capabilities, no-new-privileges, an automatic user namespace, and UID/GID `65532:65532`.

**Verified:** The Docker Sandboxes implementation creates a uniquely named shell sandbox over a synthetic temporary workspace, requests a deny-all network policy, sends the same fixture over standard input, and attempts to remove that exact sandbox when creation succeeds.

**Verified:** A Docker measurement cannot pass unless the adapter proves that exact sandbox was removed.

**Verified:** Each result is machine-readable JSON containing host facts, host eligibility, implementation digest, fixture digest, configured enforcement, observations, and a bounded verdict.

## Hostile fixture floor

**Verified:** [`bin/capsule/hostile-fixture.py`](../bin/capsule/hostile-fixture.py) attempts connections to Docker, Podman, containerd, D-Bus, SSH agent, systemd, and known cloud-control Unix sockets.

**Verified:** The same fixture also attempts outbound literal IPv4, literal IPv6, and DNS-resolved TCP connections.

**Verified:** A socket check passes only when every named socket path is absent, while a present but unreachable path is recorded and fails the check.

**Verified:** The egress check passes only when every outbound attempt is denied.

**Unverified:** Passing this minimum floor does not prove broader filesystem isolation, source confidentiality, credential non-disclosure, denial-of-service resistance, crash safety, or handoff integrity.

## Fedora 44 evidence

**Verified:** The dated evidence in [`docs/verification/containment-adapters.md`](verification/containment-adapters.md) records rootless Podman passing all eight `marooned-hostile-v1` checks on the measured Fedora 44 boot.

**Verified:** Docker Sandboxes is `unsupported-host` on the measured Fedora 44 boot even though the KVM prerequisite passed and the `sbx` executable was unavailable.

**Verified:** This unsupported-host result is informative evidence only and must never support a containment claim.

**Unverified:** Docker Sandboxes has not run this fixture on a vendor-supported host in this repository.

**Unverified:** Rootless Podman has not passed the broader Marooned assurance programme beyond this explicitly listed fixture floor.
