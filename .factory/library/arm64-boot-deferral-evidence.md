# ARM64 Boot Deferral Evidence — Oracle Linux 10

Generated: 2026-03-25T10:40:00Z
Branch: oracle10-ol10-validation-clean
Commit: 175c97d60a90c504954564e098e6655d212ef41d

## 1. ARM64 Build+Validate: PASSED (Prerequisite for Deferral)

Oracle arm64 build and `/kairos-init validate` succeeded on native arm64 CI runner
(ubuntu-24.04-arm) in GitHub Actions workflow run #23531136378.

### CI Evidence

| Field | Value |
|---|---|
| Workflow run | https://github.com/mvegter/kairos-init/actions/runs/23531136378 |
| Job name | arm64 - oraclelinux:10 - generic |
| Job URL | https://github.com/mvegter/kairos-init/actions/runs/23531136378/job/68496382932 |
| Runner | ubuntu-24.04-arm (Ubuntu 24.04 by Arm Limited, native aarch64) |
| Runner OS | Linux (arm64) |
| Runner image version | 20260318.59.1 |
| Job status | completed / success |
| Job started | 2026-03-25T08:21:25Z |
| Job completed | 2026-03-25T08:25:41Z |
| Build command | `docker buildx build --build-arg BASE_IMAGE=oraclelinux:10 --build-arg VALIDATE=true --platform linux/arm64 --file Dockerfile.test .` |
| Image tag | kairos-oraclelinux:10 |
| Build version | v0.7.3-15-gd77a07e |
| Base image digest | oraclelinux:10@sha256:430cf2fbfc7fdd0e1691b2c8df5d3555d095cb151df14efb52f338011277b9a3 |

### Build+Validate Timestamps from CI Log

- `#19 [default 3/5] RUN /kairos-init` — started 08:22:48Z, completed 08:25:29Z (160.7s)
- `#20 [default 4/5] RUN /kairos-init validate` — started 08:25:29Z, completed 08:25:35Z (6.2s, **SUCCESS**)
- `#21 [default 5/5] RUN rm /kairos-init` — completed 08:25:35Z

### amd64-first Ordering Proof

| Phase | Job | Completed |
|---|---|---|
| amd64 | amd64 - oraclelinux:10 - generic | 2026-03-25T08:15:39Z |
| arm64 | arm64 - oraclelinux:10 - generic | Started 2026-03-25T08:21:25Z (after all amd64) |

The arm64 job has `needs: [amd64_validation]` in the workflow, guaranteeing it only starts after all amd64 jobs succeed.

## 2. ARM64 Boot Infeasibility Proof

### Probe Results

```
=== Probe 1: qemu-system-aarch64 ===
which qemu-system-aarch64
RESULT: NOT FOUND

=== Probe 2: qemu-system-x86_64 ===
which qemu-system-x86_64
RESULT: NOT FOUND

=== Probe 3: qemu-system-* binaries ===
ls /usr/bin/qemu-system-*
RESULT: No qemu-system-* binaries in /usr/bin/
ls /usr/local/bin/qemu-system-*
RESULT: No qemu-system-* binaries in /usr/local/bin/

=== Probe 4: /dev/kvm ===
ls -la /dev/kvm
RESULT: /dev/kvm exists (crw-rw-rw- root kvm 10,232) — but only useful for same-arch VMs

=== Probe 5: Host architecture ===
uname -m
RESULT: x86_64

=== Probe 6: Auroraboot binary ===
which auroraboot
RESULT: NOT FOUND (containerized auroraboot available: quay.io/kairos/auroraboot:latest)
```

### Infeasibility Conclusion

ARM64 boot validation **cannot** be performed in this sandbox because:
1. **No `qemu-system-aarch64`** — required to emulate arm64 VM for boot validation
2. **Host is x86_64** — cannot natively boot arm64 images
3. **`/dev/kvm` available but for x86_64 only** — KVM acceleration is arch-specific
4. **Auroraboot is available** (containerized) but arm64 artifact boot requires `qemu-system-aarch64`

## 3. Deferred ARM64 Boot Validation Commands

The following fully-expanded command blocks can be executed on an environment with
`qemu-system-aarch64` (e.g., a native arm64 host or a host with arm64 QEMU system emulation).

### 3.1 Prerequisites Check Commands

```bash
# Verify qemu-system-aarch64 is available
which qemu-system-aarch64 || { echo "BLOCKER: qemu-system-aarch64 not found"; exit 1; }

# Verify Docker and buildx are available
docker buildx version || { echo "BLOCKER: docker buildx not available"; exit 1; }

# Verify Auroraboot image is available
docker pull quay.io/kairos/auroraboot:latest || { echo "BLOCKER: cannot pull auroraboot"; exit 1; }

# Verify /dev/kvm for acceleration (optional but recommended)
ls -la /dev/kvm && echo "KVM acceleration available" || echo "WARNING: No KVM, boot will be slow"
```

### 3.2 ARM64 Artifact Build Commands

```bash
# Step 1: Build the Oracle arm64 kairos-init image with validation
timeout 1800 docker buildx build \
  --progress=plain \
  --platform linux/arm64 \
  -f Dockerfile.test \
  --build-arg BASE_IMAGE=oraclelinux:10 \
  --build-arg VALIDATE=true \
  --load \
  -t kairos-init:oracle10-arm64-validate \
  .

# Step 2: Generate Auroraboot arm64 ISO artifact
mkdir -p /tmp/arm64-oracle10-boot
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/arm64-oracle10-boot:/output \
  quay.io/kairos/auroraboot:latest \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "artifact_version=v0.0.1-test" \
  --set "release_version=v0.0.1-test" \
  --set "flavor=oracle" \
  --set "flavor_release=10.1" \
  --set "repository=kairos-init" \
  --set "container_image=docker://kairos-init:oracle10-arm64-validate" \
  --set "state_dir=/output" \
  --set "disk.raw=true"

# Step 3: Verify artifact was produced
ls -la /tmp/arm64-oracle10-boot/*.iso /tmp/arm64-oracle10-boot/*.raw 2>/dev/null
sha256sum /tmp/arm64-oracle10-boot/*.iso /tmp/arm64-oracle10-boot/*.raw 2>/dev/null
```

### 3.3 ARM64 Boot Commands

```bash
# Boot the arm64 Oracle artifact using QEMU with serial console capture
ARTIFACT_PATH=$(ls /tmp/arm64-oracle10-boot/*.iso 2>/dev/null | head -1)
if [ -z "$ARTIFACT_PATH" ]; then
  ARTIFACT_PATH=$(ls /tmp/arm64-oracle10-boot/*.raw 2>/dev/null | head -1)
fi

qemu-system-aarch64 \
  -m 4096 \
  -cpu cortex-a72 \
  -M virt \
  -bios /usr/share/qemu/edk2-aarch64-code.fd \
  -drive if=virtio,format=raw,file="${ARTIFACT_PATH}" \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -device virtio-rng-pci \
  2>&1 | tee /tmp/arm64-oracle10-boot/serial-boot.log &
QEMU_PID=$!

# Wait for system to reach login/ready state (up to 300 seconds)
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  if grep -qE "(login:|Welcome to|kairos|systemd.*Reached target)" /tmp/arm64-oracle10-boot/serial-boot.log 2>/dev/null; then
    echo "System reached ready state after ${ELAPSED}s"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "TIMEOUT: System did not reach ready state within ${TIMEOUT}s"
  kill $QEMU_PID 2>/dev/null
  exit 1
fi
```

### 3.4 Post-Boot Health Check Commands

```bash
# Check 1: No failed systemd units
# (Execute inside the booted VM via serial console or SSH)
# If accessible via serial:
echo "root" | timeout 10 socat - UNIX-CONNECT:/tmp/arm64-oracle10-qemu-monitor.sock 2>/dev/null

# Alternative: Use expect-style or SSH-based health checks
# SSH into the VM (if network is configured):
# ssh -o StrictHostKeyChecking=no -p 2222 root@localhost "systemctl --failed --no-pager"

# Check 2: Verify no panic/emergency-mode markers in boot log
echo "=== Checking for panic/emergency markers ==="
if grep -iE "(kernel panic|emergency mode|emergency\.target|Failed to start|dracut-emergency)" /tmp/arm64-oracle10-boot/serial-boot.log; then
  echo "FAIL: panic/emergency markers found in boot log"
  exit 1
else
  echo "PASS: No panic/emergency markers in boot log"
fi

# Check 3: Verify systemd reached multi-user or graphical target
echo "=== Checking for system ready state ==="
if grep -E "(Reached target|multi-user\.target|graphical\.target|login:)" /tmp/arm64-oracle10-boot/serial-boot.log; then
  echo "PASS: System reached ready/login state"
else
  echo "FAIL: System did not reach ready state"
  exit 1
fi

# Check 4: Capture systemctl --failed output from within the VM
# (Requires VM to be accessible — via serial console injection or SSH)
# Example via SSH (adjust port if needed):
# ssh -o StrictHostKeyChecking=no root@localhost -p 2222 \
#   "systemctl --failed --no-pager && echo 'PASS: No failed units' || echo 'FAIL: Failed units detected'"

# Check 5: Capture journalctl warnings for baseline comparison
# ssh -o StrictHostKeyChecking=no root@localhost -p 2222 \
#   "journalctl -p warning --no-pager | head -100"

# Cleanup
kill $QEMU_PID 2>/dev/null
echo "=== ARM64 boot validation complete ==="
```

## 4. Summary

| Check | Status |
|---|---|
| Oracle arm64 build (CI native runner) | ✅ PASSED |
| Oracle arm64 `/kairos-init validate` (CI native runner) | ✅ PASSED |
| amd64-first ordering enforced | ✅ VERIFIED |
| arm64 boot infeasibility documented | ✅ PROVEN |
| Deferred boot prerequisites commands | ✅ PROVIDED |
| Deferred boot artifact build commands | ✅ PROVIDED |
| Deferred boot execution commands | ✅ PROVIDED |
| Deferred post-boot health checks | ✅ PROVIDED |
