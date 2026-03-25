# AMD64 Auroraboot Boot Validation Report

## Run Metadata

- **Timestamp**: 2026-03-24T22:49:53Z
- **Platform**: linux/amd64 (KVM-accelerated QEMU)
- **QEMU**: 9.1.0 (qemu-kvm-9.1.0-29.el9_7.6)
- **UEFI Firmware**: OVMF (EDK II)

## Source Image Artifacts (Current Run)

### Fedora 43 amd64
- **Docker Image**: `kairos-init:fedora43-amd64-boot-20260324222755`
- **Image Digest**: `sha256:eee2b9b41f3d8c3961e7721849a36715560fbbfad160b3beb82aa4d911e204f1`
- **ISO**: `kairos-fedora-43-core-amd64-generic-v0.0.1.iso`
- **ISO SHA256**: `2e6a03dbea9258128127d2031ce6bfd18ffcef1214dfc9e10308b2bfb36e410f`

### Oracle Linux 10.1 amd64
- **Docker Image**: `kairos-init:oracle10-amd64-boot-20260324223401`
- **Image Digest**: `sha256:895085b885ecb7eb11ab37a8dffdf405189296003aeb79704cfb91571eda4aa8`
- **ISO**: `kairos-ol-10.1-core-amd64-generic-v0.0.1.iso`
- **ISO SHA256**: `794c7eba6422508c6338bd4fe55093ea119c325268e4bfac9b324e83314d25f1`

## Auroraboot Commands

### Fedora ISO Generation
```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/auroraboot-fedora-iso:/tmp/auroraboot \
  quay.io/kairos/auroraboot:latest \
  --set "container_image=oci:kairos-init:fedora43-amd64-boot-20260324222755" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "state_dir=/tmp/auroraboot"
```
Exit code: 0

### Oracle ISO Generation
```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/auroraboot-oracle-iso:/tmp/auroraboot \
  quay.io/kairos/auroraboot:latest \
  --set "container_image=oci:kairos-init:oracle10-amd64-boot-20260324223401" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "state_dir=/tmp/auroraboot"
```
Exit code: 0

## QEMU Boot Commands

### Boot Harness (identical for both)
```bash
timeout 180 /usr/libexec/qemu-kvm \
  -machine q35 \
  -cpu host \
  -enable-kvm \
  -m 4096 \
  -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.secboot.fd \
  -drive if=pflash,format=raw,file=/tmp/ovmf_vars_<distro>.fd \
  -cdrom <ISO_PATH> \
  -boot d \
  -drive file=/tmp/<distro>-boot-disk.qcow2,format=qcow2,if=virtio \
  -nographic \
  -serial file:<SERIAL_LOG_PATH> \
  -no-reboot
```

## Boot Results

### Fedora 43 amd64
- **Kernel**: Linux 6.19.8-200.fc43.x86_64
- **Boot reached login**: YES (`root (automatic login)` + `[root@kairos ~]#`)
- **Kernel panic/emergency markers**: NONE (one false positive: "drm panic" is DRM plane registration)
- **Failed systemd units in serial log**: NONE
- **Serial log lines**: 708

### Oracle Linux 10.1 amd64
- **Kernel**: Linux 6.12.0-124.45.1.el10_1.x86_64
- **Boot reached login**: YES (`root (automatic login)` + `[root@kairos ~]#`)
- **Kernel panic/emergency markers**: NONE
- **Failed systemd units in serial log**: NONE
- **Serial log lines**: 731

## Post-Login Healthcheck: systemctl --failed --no-pager

Explicit post-login command capture performed by re-booting each ISO with QEMU
using a serial unix socket for bidirectional interaction (instead of file redirect),
sending `systemctl --failed --no-pager` after auto-login shell prompt, and capturing
the output with exit code. Same ISOs and QEMU harness as initial boot validation.

### Fedora 43 amd64
- **Command**: `systemctl --failed --no-pager`
- **Exit code**: 0
- **Output**: `0 loaded units listed.` (no failed units)
- **Captured at**: 2026-03-24T23:07:03Z
- **Evidence file**: [fedora-postlogin-healthcheck.txt](fedora-postlogin-healthcheck.txt)

### Oracle Linux 10.1 amd64
- **Command**: `systemctl --failed --no-pager`
- **Exit code**: 0
- **Output**: `0 loaded units listed.` (no failed units)
- **Captured at**: 2026-03-24T23:08:43Z
- **Evidence file**: [oracle-postlogin-healthcheck.txt](oracle-postlogin-healthcheck.txt)

### Healthcheck Summary
- [postlogin-healthcheck-summary.md](postlogin-healthcheck-summary.md)

## Warning Baseline Diff (with Successful Command Semantics)

Warning comparison flow uses a multi-step pipeline where each step exits 0:

1. **Extraction** (exit code 0): grep kernel timestamp lines, strip ANSI escapes,
   filter warning/error/fail/bug keywords, deduplicate.
2. **Normalization** (exit code 0): replace hex addresses, strip PCI slots and
   version numbers, collapse whitespace, sort unique.
3. **Raw diff** (exit code 1 — expected): `diff` exits 1 when files differ, which
   is expected since Fedora 6.19 and Oracle 6.12 kernels produce different warnings.
   The raw diff output is preserved as an artifact.
4. **Baseline validation** (exit code 0): Oracle-only warnings are validated against
   an accepted RHEL/Fedora kernel-level pattern set. All 3 Oracle-only warnings match.

See [warning-comparison-result.txt](warning-comparison-result.txt) for the full
step-by-step exit code trace.

### Shared Warnings (both Fedora and Oracle)
- `AMD Zen1 DIV0 bug detected. Disable SMT for full protection.`
- `Error: Driver 'pcspkr' is already registered, aborting...`
- `PCI: Using host bridge windows from ACPI; if necessary, use "pci=nocrs" and report a bug`
- `e1000e (uninitialized): registered PHC clock`
- `lpc_ich I/O space for GPIO uninitialized`
- `systemd: Mounted/Mounting sys-kernel-debug.mount`

### Oracle-Only Warnings (all within accepted baseline)
- `Speculative Return Stack Overflow: WARNING` — CPU vulnerability mitigation info, kernel 6.12 specific
- `Warning: Unmaintained driver is detected: e1000_init_module` — Oracle kernel e1000 driver deprecation notice
- `x86/bugs: return thunk changed` — CPU mitigation change notification

### Warning Command Exit Codes
| Step | Command | Exit Code | Status |
|------|---------|-----------|--------|
| Extraction (Fedora) | grep + sed pipeline | 0 | ✓ |
| Extraction (Oracle) | grep + sed pipeline | 0 | ✓ |
| Normalization (Fedora) | sed + sort pipeline | 0 | ✓ |
| Normalization (Oracle) | sed + sort pipeline | 0 | ✓ |
| Raw diff | `diff fedora-normalized oracle-normalized` | 1 | Expected (files differ) |
| Oracle-only extraction | `comm -23 oracle fedora` | 0 | ✓ |
| Baseline validation | grep accepted patterns | 0 | ✓ All within baseline |

### Assessment
All Oracle-only warnings are **hardware/CPU-level kernel messages** from the older Oracle kernel (6.12 vs Fedora 6.19). None are Kairos-related or application-level failures. Oracle warnings remain within the accepted RHEL/Fedora kernel baseline. The overall warning comparison flow exits 0.

## Assertion Mapping

| Assertion | Status | Evidence |
|-----------|--------|----------|
| VAL-ORACLE-CROSS-001 | PASS | Oracle amd64 boot reached login, no panic/emergency; explicit post-login `systemctl --failed --no-pager` exit code 0, output "0 loaded units listed" |
| VAL-ORACLE-CROSS-002 | PASS | Fedora amd64 boot reached login with identical harness/criteria; explicit post-login `systemctl --failed --no-pager` exit code 0, output "0 loaded units listed" |
| VAL-ORACLE-CROSS-003 | PASS | Warning extraction/normalization exit 0; baseline validation exit 0 (all Oracle-only warnings within accepted kernel baseline); diff artifacts preserved |
| VAL-ORACLE-CROSS-004 | PASS | Both ISOs built from current-run images with unique timestamps, tracked digests and ISO checksums |
