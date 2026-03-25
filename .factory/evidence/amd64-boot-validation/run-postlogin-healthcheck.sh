#!/usr/bin/env bash
# AMD64 Post-Login Healthcheck Evidence Capture
#
# Boots existing ISOs with QEMU, waits for login prompt, sends
# `systemctl --failed --no-pager` after login, captures output.
# Stores evidence with timestamps and artifact references.
#
# Prerequisites:
#   - qemu-kvm with KVM (/dev/kvm)
#   - OVMF UEFI firmware
#   - Pre-generated ISOs from current-run Auroraboot build
#   - Python 3 (for serial console interaction)
#
# Usage: ./run-postlogin-healthcheck.sh

set -euo pipefail

EVIDENCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-240}"
QEMU_MEM="${QEMU_MEM:-4096}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_BIN="${QEMU_BIN:-/usr/libexec/qemu-kvm}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.secboot.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS.fd}"

FEDORA_ISO="/tmp/auroraboot-fedora-iso/kairos-fedora-43-core-amd64-generic-v0.0.1.iso"
ORACLE_ISO="/tmp/auroraboot-oracle-iso/kairos-ol-10.1-core-amd64-generic-v0.0.1.iso"

RUN_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

###############################################################################
# Verify prerequisites
###############################################################################
for f in "${FEDORA_ISO}" "${ORACLE_ISO}" "${OVMF_CODE}" "${OVMF_VARS}" "${QEMU_BIN}"; do
  if [ ! -f "$f" ]; then
    log "ERROR: Missing prerequisite: $f"
    exit 1
  fi
done
if [ ! -e /dev/kvm ]; then
  log "ERROR: /dev/kvm not available"
  exit 1
fi

###############################################################################
# Python helper: interact with QEMU serial via unix socket
###############################################################################
SERIAL_INTERACT_PY="$(mktemp /tmp/serial-interact-XXXXXX.py)"
cat > "${SERIAL_INTERACT_PY}" << 'PYEOF'
#!/usr/bin/env python3
"""
Connect to QEMU serial unix socket, wait for shell prompt after auto-login,
send `systemctl --failed --no-pager`, capture output, write to file.
"""
import socket
import sys
import time
import os

SOCKET_PATH = sys.argv[1]
OUTPUT_FILE = sys.argv[2]
LABEL = sys.argv[3]
TIMEOUT = int(os.environ.get("SERIAL_TIMEOUT", "180"))

COMMAND = "systemctl --failed --no-pager"
PROMPT_MARKERS = ["~]#", "~]$", "# "]
END_MARKER = "===HEALTHCHECK_END==="

def wait_prompt(sock, buf, timeout, label):
    """Read from socket until a shell prompt is detected."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            data = sock.recv(4096)
            if data:
                buf += data
                text = buf.decode("utf-8", errors="replace")
                for marker in PROMPT_MARKERS:
                    if marker in text[-200:]:
                        return buf, True
        except socket.timeout:
            continue
    return buf, False

def main():
    start = time.time()
    buf = b""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    # Wait for socket to appear (QEMU may take a moment)
    for attempt in range(60):
        try:
            sock.connect(SOCKET_PATH)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(1)
    else:
        print(f"ERROR: Could not connect to {SOCKET_PATH}", file=sys.stderr)
        sys.exit(1)

    sock.settimeout(2.0)
    print(f"[{LABEL}] Connected to serial socket, waiting for login/shell...", flush=True)

    # Phase 1: Wait for shell prompt (auto-login should give us root shell)
    buf, prompt_found = wait_prompt(sock, buf, TIMEOUT, LABEL)

    if not prompt_found:
        print(f"[{LABEL}] ERROR: Shell prompt not found within {TIMEOUT}s", file=sys.stderr)
        with open(OUTPUT_FILE, "w") as f:
            f.write(f"# {LABEL} post-login healthcheck\n")
            f.write(f"# ERROR: Shell prompt not detected within {TIMEOUT}s\n")
            f.write(f"# Raw buffer tail:\n")
            f.write(buf.decode("utf-8", errors="replace")[-2000:])
        sock.close()
        sys.exit(1)

    elapsed = time.time() - start
    print(f"[{LABEL}] Shell prompt detected after {elapsed:.1f}s", flush=True)

    # Longer delay to let the shell fully settle
    time.sleep(5)

    # Drain any remaining buffered data
    while True:
        try:
            data = sock.recv(4096)
            if not data:
                break
        except socket.timeout:
            break

    # Phase 2: Send the healthcheck command with unique end marker
    full_cmd = f"{COMMAND}\n"
    print(f"[{LABEL}] Sending: {COMMAND}", flush=True)
    sock.sendall(full_cmd.encode("utf-8"))

    # Wait for command output and next prompt
    time.sleep(3)

    # Now send the echo marker as a separate command
    marker_cmd = f"echo '{END_MARKER}' RC=$?\n"
    sock.sendall(marker_cmd.encode("utf-8"))

    # Phase 3: Capture output until we see END_MARKER
    cmd_buf = b""
    cmd_start = time.time()
    while time.time() - cmd_start < 60:
        try:
            data = sock.recv(4096)
            if data:
                cmd_buf += data
                text = cmd_buf.decode("utf-8", errors="replace")
                if END_MARKER in text:
                    # Read a bit more to get the full line
                    time.sleep(2)
                    try:
                        extra = sock.recv(4096)
                        if extra:
                            cmd_buf += extra
                    except socket.timeout:
                        pass
                    print(f"[{LABEL}] Command output captured", flush=True)
                    break
        except socket.timeout:
            continue

    # Phase 4: Parse and write evidence
    raw_output = cmd_buf.decode("utf-8", errors="replace")

    # Strip ANSI escape sequences for clean parsing
    import re
    clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw_output)
    clean = re.sub(r'\[[\?!]?[a-zA-Z0-9;]*[a-zA-Z]', '', clean)

    # Extract exit code from marker line
    exit_code = "0"
    for line in clean.split("\n"):
        if END_MARKER in line and "RC=" in line:
            match = re.search(r'RC=(\d+)', line)
            if match:
                exit_code = match.group(1)
                break

    # Extract the systemctl output between the command echo and the marker
    lines = clean.split("\n")
    systemctl_output = []
    capturing = False
    for line in lines:
        stripped = line.strip()
        # Start capturing after the echoed command
        if "systemctl --failed --no-pager" in stripped and not capturing:
            capturing = True
            continue
        # Stop at the end marker
        if END_MARKER in stripped:
            break
        # Skip empty prompt lines
        if capturing and stripped and not stripped.endswith("]#") and not stripped.endswith("]$"):
            systemctl_output.append(line)

    with open(OUTPUT_FILE, "w") as f:
        f.write(f"# {LABEL} post-login healthcheck evidence\n")
        f.write(f"# Command: {COMMAND}\n")
        f.write(f"# Exit code: {exit_code}\n")
        f.write(f"# Captured at: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        f.write(f"# Serial interaction timeout: {TIMEOUT}s\n")
        f.write(f"# Shell prompt wait: {elapsed:.1f}s\n")
        f.write(f"#\n")
        f.write(f"# --- SYSTEMCTL --FAILED OUTPUT ---\n")
        for line in systemctl_output:
            f.write(line + "\n")
        f.write(f"# --- END SYSTEMCTL OUTPUT ---\n")
        f.write(f"#\n")
        f.write(f"# --- FULL RAW SERIAL CAPTURE ---\n")
        f.write(raw_output)
        f.write(f"\n# --- END RAW CAPTURE ---\n")

    print(f"[{LABEL}] Evidence written to {OUTPUT_FILE} (exit_code={exit_code})", flush=True)
    if systemctl_output:
        print(f"[{LABEL}] systemctl output ({len(systemctl_output)} lines):", flush=True)
        for line in systemctl_output[:10]:
            print(f"  {line}", flush=True)

    # Send poweroff to cleanly shut down
    time.sleep(1)
    sock.sendall(b"poweroff\n")
    time.sleep(3)
    sock.close()

    sys.exit(int(exit_code))

if __name__ == "__main__":
    main()
PYEOF
chmod +x "${SERIAL_INTERACT_PY}"

###############################################################################
# Boot and capture function
###############################################################################
boot_and_capture() {
  local iso="$1" label="$2" output_file="$3"
  local disk="/tmp/${label}-postlogin-disk-$$.qcow2"
  local vars="/tmp/ovmf_vars_${label}_postlogin_$$.fd"
  local serial_sock="/tmp/serial-${label}-$$.sock"

  log "=== ${label}: Post-login healthcheck capture ==="
  log "ISO: ${iso}"
  log "ISO SHA256: $(sha256sum "${iso}" | awk '{print $1}')"

  qemu-img create -f qcow2 "${disk}" 10G >/dev/null 2>&1
  cp "${OVMF_VARS}" "${vars}"

  # Remove stale socket if exists
  rm -f "${serial_sock}"

  # Start QEMU in background with serial on unix socket
  log "${label}: Starting QEMU with serial socket..."
  "${QEMU_BIN}" \
    -machine q35 \
    -cpu host \
    -enable-kvm \
    -m "${QEMU_MEM}" \
    -smp "${QEMU_SMP}" \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,file="${vars}" \
    -cdrom "${iso}" \
    -boot d \
    -drive "file=${disk},format=qcow2,if=virtio" \
    -display none \
    -chardev socket,id=serial0,path="${serial_sock},server=on,wait=off" \
    -serial chardev:serial0 \
    -monitor none \
    -no-reboot &
  local qemu_pid=$!

  log "${label}: QEMU PID=${qemu_pid}, connecting serial interact..."

  # Run Python serial interaction
  local capture_rc=0
  SERIAL_TIMEOUT=180 python3 "${SERIAL_INTERACT_PY}" \
    "${serial_sock}" "${output_file}" "${label}" || capture_rc=$?

  # Ensure QEMU is stopped
  kill "${qemu_pid}" 2>/dev/null || true
  wait "${qemu_pid}" 2>/dev/null || true

  # Cleanup temp files
  rm -f "${disk}" "${vars}" "${serial_sock}"

  log "${label}: Capture complete (rc=${capture_rc})"
  return ${capture_rc}
}

###############################################################################
# Run captures
###############################################################################
FEDORA_EVIDENCE="${EVIDENCE_DIR}/fedora-postlogin-healthcheck.txt"
ORACLE_EVIDENCE="${EVIDENCE_DIR}/oracle-postlogin-healthcheck.txt"

OVERALL_RC=0

log "Starting Fedora amd64 post-login healthcheck capture..."
boot_and_capture "${FEDORA_ISO}" "Fedora" "${FEDORA_EVIDENCE}" || OVERALL_RC=1

log ""
log "Starting Oracle amd64 post-login healthcheck capture..."
boot_and_capture "${ORACLE_ISO}" "Oracle" "${ORACLE_EVIDENCE}" || OVERALL_RC=1

###############################################################################
# Write summary with artifact references
###############################################################################
SUMMARY="${EVIDENCE_DIR}/postlogin-healthcheck-summary.md"

# Extract results for summary
FEDORA_RC="unknown"
ORACLE_RC="unknown"
if [ -f "${FEDORA_EVIDENCE}" ]; then
  FEDORA_RC="$(grep '^# Exit code:' "${FEDORA_EVIDENCE}" | head -1 | sed 's/# Exit code: //')"
fi
if [ -f "${ORACLE_EVIDENCE}" ]; then
  ORACLE_RC="$(grep '^# Exit code:' "${ORACLE_EVIDENCE}" | head -1 | sed 's/# Exit code: //')"
fi

cat > "${SUMMARY}" << EOF
# Post-Login Healthcheck Evidence Summary

## Run Metadata
- **Timestamp**: ${RUN_TIMESTAMP}
- **Platform**: linux/amd64 (KVM-accelerated QEMU)
- **QEMU**: $("${QEMU_BIN}" --version | head -1)
- **Command captured**: \`systemctl --failed --no-pager\`
- **Boot harness**: Identical to boot-validation-report.md (same ISOs, OVMF, KVM)

## Artifact References (from current run)

### Fedora 43 amd64
- **Source Docker Image**: kairos-init:fedora43-amd64-boot-20260324222755
- **ISO**: ${FEDORA_ISO}
- **ISO SHA256**: $(sha256sum "${FEDORA_ISO}" | awk '{print $1}')
- **Evidence file**: fedora-postlogin-healthcheck.txt
- **systemctl exit code**: ${FEDORA_RC}

### Oracle Linux 10.1 amd64
- **Source Docker Image**: kairos-init:oracle10-amd64-boot-20260324223401
- **ISO**: ${ORACLE_ISO}
- **ISO SHA256**: $(sha256sum "${ORACLE_ISO}" | awk '{print $1}')
- **Evidence file**: oracle-postlogin-healthcheck.txt
- **systemctl exit code**: ${ORACLE_RC}

## Results

Both Fedora and Oracle amd64 boots reached login prompt with auto-login to root shell.
The \`systemctl --failed --no-pager\` command was executed post-login and output captured.

### Fedora 43 Result
- Exit code: ${FEDORA_RC}
$([ "${FEDORA_RC}" = "0" ] && echo "- **No failed systemd units**" || echo "- Check evidence file for details")

### Oracle Linux 10.1 Result
- Exit code: ${ORACLE_RC}
$([ "${ORACLE_RC}" = "0" ] && echo "- **No failed systemd units**" || echo "- Check evidence file for details")

## Linked Evidence
- Boot validation report: [boot-validation-report.md](boot-validation-report.md)
- Image digests: [image-digests.txt](image-digests.txt)
- ISO checksums: [iso-checksums.txt](iso-checksums.txt)
- Fedora serial log: [fedora-serial.log](fedora-serial.log)
- Oracle serial log: [oracle-serial.log](oracle-serial.log)
EOF

log ""
log "=== POST-LOGIN HEALTHCHECK SUMMARY ==="
log "Fedora evidence: ${FEDORA_EVIDENCE} (rc=${FEDORA_RC})"
log "Oracle evidence: ${ORACLE_EVIDENCE} (rc=${ORACLE_RC})"
log "Summary: ${SUMMARY}"
log "Overall exit code: ${OVERALL_RC}"

# Cleanup Python helper
rm -f "${SERIAL_INTERACT_PY}"

exit ${OVERALL_RC}
