# Post-Login Healthcheck Evidence Summary

## Run Metadata
- **Timestamp**: 2026-03-25T11:37:41Z
- **Platform**: linux/amd64 (KVM-accelerated QEMU)
- **QEMU**: QEMU emulator version 9.1.0 (qemu-kvm-9.1.0-29.el9_7.6)
- **Command captured**: `systemctl --failed --no-pager`
- **Boot harness**: Identical to boot-validation-report.md (same ISOs, OVMF, KVM)

## Artifact References (from current run)

### Fedora 43 amd64
- **Source Docker Image**: kairos-init:fedora43-amd64-boot-20260324222755
- **ISO**: /tmp/auroraboot-fedora-iso/kairos-fedora-43-core-amd64-generic-v0.0.1.iso
- **ISO SHA256**: 2e6a03dbea9258128127d2031ce6bfd18ffcef1214dfc9e10308b2bfb36e410f
- **Evidence file**: fedora-postlogin-healthcheck.txt
- **systemctl exit code**: 0

### Oracle Linux 10.1 amd64
- **Source Docker Image**: kairos-init:oracle10-amd64-boot-20260324223401
- **ISO**: /tmp/auroraboot-oracle-iso/kairos-ol-10.1-core-amd64-generic-v0.0.1.iso
- **ISO SHA256**: 794c7eba6422508c6338bd4fe55093ea119c325268e4bfac9b324e83314d25f1
- **Evidence file**: oracle-postlogin-healthcheck.txt
- **systemctl exit code**: 0

## Results

Both Fedora and Oracle amd64 boots reached login prompt with auto-login to root shell.
The `systemctl --failed --no-pager` command was executed post-login and output captured.

### Fedora 43 Result
- Exit code: 0
- **No failed systemd units**

### Oracle Linux 10.1 Result
- Exit code: 0
- **No failed systemd units**

## Linked Evidence
- Boot validation report: [boot-validation-report.md](boot-validation-report.md)
- Image digests: [image-digests.txt](image-digests.txt)
- ISO checksums: [iso-checksums.txt](iso-checksums.txt)
- Fedora serial log: [fedora-serial.log](fedora-serial.log)
- Oracle serial log: [oracle-serial.log](oracle-serial.log)
