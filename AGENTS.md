<coding_guidelines>
# Learnings

## Oracle Linux
- Oracle Linux should be detected as its own distro key (`ol`) while staying in `RedHatFamily` so distro-specific package maps can be applied cleanly.
- `mudler/yip` must be at least `v1.23.0` for Oracle Linux package-manager detection; older versions fail with `unknown package manager`.
- Oracle EPEL setup should use `oracle-epel-release-el<major>` for OL8/OL9/OL10.
- Validate Oracle changes end-to-end with `Dockerfile.test` builds for `oraclelinux:8`, `oraclelinux:9`, and `oraclelinux:10`.
- For EL9 boot testing in QEMU, use a modern CPU model (`-cpu host` or equivalent). Default `qemu64` can trigger a glibc CPU-level fatal at `/init` and produce false-negative boot panics.
- A boot reaching `login:` is not enough for Oracle validation; always check `systemctl --failed` and `journalctl -b -p err..alert` to catch runtime issues like `immucore.service` `Exec format error`.

## Time Synchronization (NTP/chrony)

### RHEL Family (RHEL, CentOS, Rocky, AlmaLinux, Oracle)
- **Use `chrony`/`chronyd`**, not `systemd-timesyncd`.
- Red Hat **excludes systemd-timesyncd at build time** - it's not compiled into any systemd subpackage.
- Neither the unit file nor binary exist on these distros.
- `systemctl enable systemd-timesyncd` **fails** with "unit does not exist".
- This is a deliberate policy decision: Red Hat prefers chrony for enterprise environments.

### Fedora
- **Also uses `chrony`/`chronyd`** as the recommended NTP solution (per Fedora docs).
- However, Fedora **does include systemd-timesyncd** (bundled in the `systemd-udev` package).
- Both unit file and binary exist, so `systemctl enable systemd-timesyncd` succeeds.
- Fedora is part of `RedHatFamily` in this codebase, so it inherits chrony from package maps.
- Using chronyd avoids having two NTP daemons installed (chrony from RedHatFamily + timesyncd from systemd).
- `chronyd.service` has `Conflicts=systemd-timesyncd.service`, so chronyd would win at runtime anyway.

### Key Differences Summary
| Distro | systemd-timesyncd unit | systemd-timesyncd binary | Recommended NTP |
|--------|------------------------|--------------------------|-----------------|
| RHEL/CentOS/Rocky/AlmaLinux/Oracle | MISSING | MISSING | chrony |
| Fedora | EXISTS (in systemd-udev) | EXISTS (in systemd-udev) | chrony |
| Ubuntu/Debian/SUSE | EXISTS | EXISTS | systemd-timesyncd |

### Container Base Images
- Container base images are **minimal** and don't include chrony pre-installed.
- Must explicitly install chrony package even though full installations may have it by default.
- Example: Rocky Linux container has ~147 packages vs thousands in a full installation.

## Distro Detection Architecture
- Distro detection happens in two ways: regex string matching (`OnlyIfOs`) and Family enums (`RedHatFamily`, etc.).
- This duplication is technical debt - when adding a new distro, you must update BOTH the regex patterns AND the family definitions.
- `[O-o]` in regex is a bug - it matches O through o in ASCII (many unintended characters). Use `[Oo]` instead.

## CI Testing
- Add distros to CI matrix when fixing distro-specific bugs to prevent regressions.
- CentOS Stream images: `quay.io/centos/centos:stream9`, `quay.io/centos/centos:stream10`
- Oracle Linux images: `oraclelinux:8`, `oraclelinux:9`, `oraclelinux:10`

## Commit Message Guidelines
- Explain **WHY** the change is needed, not just WHAT changed.
- Include the error message or bug that triggered the fix.
- Example: "CentOS Stream 9 builds failed with: 'failed to run systemctl enable systemd-timesyncd: exit status 1'"

## Package Maps vs Stages
- Keep package installation in `pkg/values/packagemaps.go` (e.g., chrony package for RedHatFamily).
- Keep service enablement/configuration in `pkg/stages/steps_init.go`.
- Keep repo setup and bootstrap logic in `pkg/stages/steps_install.go`.

## Docker Build / Bundled Binaries
- `.gitignore` does **not** affect Docker build context; use `.dockerignore` for Docker builds.
- Excluding `pkg/bundled/binaries` in `.dockerignore` prevents host-generated bundled binaries from being copied into the image and causing architecture mismatches.
- An `Exec format error` from `immucore` during boot can be caused by wrong-arch bundled binaries embedded at build time.
- Verify bundled binary arch inside built images when debugging (`file /usr/bin/immucore`, etc.).
- `Dockerfile.test` build arg `FINAL_TAG` does **not** tag the output Docker image name. Tag explicitly with `-t` when building images for downstream steps (e.g. AuroraBoot): `docker build -f Dockerfile.test --build-arg BASE_IMAGE=oraclelinux:9 -t kairos-init:test-ol9 .`.

## Oracle Linux Runtime Cloudconfig Learnings
- `systemctl --failed` may be clean while `journalctl -b -p err..alert` still contains actionable cloudconfig/runtime errors; always check both.
- In cloudconfigs, avoid unconditional `networkctl reload`; guard on command availability (`/usr/bin/networkctl`).
- For resolv.conf relinking, use `rm -f /etc/resolv.conf` to avoid noisy failures if state differs.
- Do not unconditionally enable units that may not exist across distros/versions (`iscsid`, `systemd-confext`); gate with unit-file existence checks.
- Datasource pull failures (`no metadata/userdata found`) are expected in local/QEMU install-mode paths; gate datasource pull in install-mode to reduce false error noise.
- Verified on OL9 and OL10: the combination of `networkctl` guard, `rm -f /etc/resolv.conf`, `iscsid` unit gating, and datasource pull gating in live/install-mode removed the prior actionable Kairos cloudconfig errors from `journalctl -b -p err..alert`.

## Validation Workflow for Oracle Linux 9
- For trustworthy OL9 validation: build image, generate ISO, boot with QEMU `-cpu host`, login, run `systemctl --failed` and `journalctl -b -p err..alert`.
- Remaining `err..alert` lines like `e1000`/`pcspkr` can be hypervisor/kernel noise and should be triaged separately from Kairos stage failures.

## Sandbox Workflow (build + boot + e2e verification)
- Local dev host is macOS: make code changes in the local repo first, sync the repo to sandbox, then run `go test`, Docker builds, and other validation tools in sandbox (Linux).
- Use sandbox when local Docker registry policy blocks `docker.io` pulls.
- SSH template:
  - `/usr/bin/ssh -F /dev/null -o ServerAliveInterval=20 -o PreferredAuthentications=publickey -o GSSAPIAuthentication=no -o ConnectTimeout=10 -o ConnectionAttempts=1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null -l sandbox -i "$HOME/.sandbox-cli/.sandbox_rsa" 10.89.8.5 -p 2222 "<cmd>"`
- Build image in sandbox (example amd64):
  - `... "cd ~/kairos-init && docker build --build-arg TARGETARCH=amd64 -t kairos-init:sandbox-amd64 ."`
- Boot/test flow in sandbox:
  - Build target distro image(s) via `Dockerfile.test` as needed.
  - Generate ISO from produced artifacts and boot in QEMU with `-cpu host` (especially EL9).
  - Login to the VM and run:
    - `systemctl --failed`
    - `journalctl -b -p err..alert`
  - Treat boot success alone as insufficient; e2e passes only when service failures are understood and journal errors are triaged.

## Oracle Linux 9 vs Oracle Linux 10 (`systemd-confext`)
- `systemd-confext` is **not available** on Oracle Linux 9 (base repos or Oracle EPEL).
- `systemd-confext` **is available on Oracle Linux 10** as part of the `systemd` package (not as a standalone `systemd-confext` package).
- Therefore, `dnf install systemd-confext` fails on both OL9 and OL10; use `dnf provides '*/systemd-confext'` to check availability.
- Runtime behavior should gate `systemd-confext` enablement by unit/binary presence instead of assuming support across all Oracle major versions.

## Oracle Linux 10 Build/Boot Validation Learnings
- Oracle Linux 10 conversion can complete successfully via `Dockerfile.test` (`/kairos-init` + `/kairos-init validate` pass) while still failing later at live ISO boot time; conversion success and boot success must be validated separately.
- For unattended AuroraBoot ISO generation in sandbox, set `disable_netboot=true`; otherwise AuroraBoot starts pixiecore (`DHCP/TFTP/PXE`) and stays running, which can look like a hung build and may trigger SSH/session interruptions.
- In sandbox runs, transient SSH disconnect/timeouts do not necessarily mean the remote Docker build failed; verify actual state with `docker images`, `docker ps`, and `docker inspect/logs` before rerunning expensive steps.
- AuroraBoot `disk.raw=true` validation in sandbox can fail due to missing loop devices (`/dev/loop0` absent in containerized environment); this is an environment limitation and requires a host/runner with loop device support.
- Current OL10 runtime status in this investigation: **validated** for ISO boot with QEMU `-cpu host`; system reaches login, `systemctl --failed --no-pager` is empty, and `journalctl -b -p err..alert --no-pager` has no actionable Kairos/runtime errors.
- Keep using `journalctl -b -p err..alert` as blocking signal and use `warning..alert` output as additional triage context, since not every warning is a release blocker.

### Definition of Done (Oracle validation quality gate)
- `Dockerfile.test` build for target Oracle version succeeds.
- Converted image passes `/kairos-init validate`.
- Boot artifact (ISO/raw as applicable) reaches interactive login in QEMU.
- `systemctl --failed --no-pager` is empty (or any failures are explicitly understood and fixed).
- `journalctl -b -p warning..alert --no-pager` has no actionable Kairos/runtime warnings.
- `journalctl -b -p err..alert --no-pager` has no actionable Kairos/runtime errors.

### Known blocker (OL10)
- No active OL10 blocker in the latest validation run.
- OL10 ISO boot reached login in QEMU (`-cpu host`) with clean runtime checks (`systemctl --failed --no-pager` empty and no actionable `journalctl -b -p err..alert --no-pager` entries).

### Environment caveats for reproducible validation
- For offline artifact generation with AuroraBoot, explicitly set `disable_netboot=true` (and usually `disable_http_server=true`) to avoid long-running pixiecore services that can mask completion.
- Raw-image validation requires loop device support in the runner (`/dev/loop*`); `--privileged` alone is insufficient if the host/container environment does not expose loop devices.
- On sandbox/remote runs, transient SSH disconnects are common during long Docker steps; always verify final state from the remote host (`docker images`, `docker ps`, artifact presence) before re-running.
</coding_guidelines>

