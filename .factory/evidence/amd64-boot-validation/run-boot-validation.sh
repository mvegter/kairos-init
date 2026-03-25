#!/usr/bin/env bash
# AMD64 Auroraboot Boot Validation Script
# Generates ISOs from current-run container images, boots them with QEMU,
# captures serial logs, and produces warning baseline diff evidence.
#
# All evidence commands (extraction, normalization, diff) are designed to
# exit 0 on success. The diff step uses an explicit comparison wrapper that
# preserves the raw diff artifact while returning exit code 0 when all
# Oracle-only warnings fall within the accepted RHEL/Fedora kernel baseline.
#
# Prerequisites:
#   - Docker with buildx
#   - qemu-kvm with KVM support (/dev/kvm)
#   - OVMF UEFI firmware (/usr/share/OVMF/)
#   - Pre-built container images:
#     kairos-init:fedora43-amd64-boot-<timestamp>
#     kairos-init:oracle10-amd64-boot-<timestamp>
#
# Usage: ./run-boot-validation.sh <fedora-image-tag> <oracle-image-tag>

set -euo pipefail

FEDORA_TAG="${1:?Usage: $0 <fedora-image-tag> <oracle-image-tag>}"
ORACLE_TAG="${2:?Usage: $0 <fedora-image-tag> <oracle-image-tag>}"
EVIDENCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
QEMU_MEM="${QEMU_MEM:-4096}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_BIN="${QEMU_BIN:-/usr/libexec/qemu-kvm}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.secboot.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS.fd}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

###############################################################################
# 1. Record source image digests (VAL-ORACLE-CROSS-004)
###############################################################################
log "Recording source image digests..."
FEDORA_DIGEST="$(docker inspect "${FEDORA_TAG}" --format '{{.Id}}')"
ORACLE_DIGEST="$(docker inspect "${ORACLE_TAG}" --format '{{.Id}}')"
cat > "${EVIDENCE_DIR}/image-digests.txt" <<EOF
fedora_image=${FEDORA_TAG}
fedora_digest=${FEDORA_DIGEST}
oracle_image=${ORACLE_TAG}
oracle_digest=${ORACLE_DIGEST}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
log "Fedora digest: ${FEDORA_DIGEST}"
log "Oracle digest: ${ORACLE_DIGEST}"

###############################################################################
# 2. Generate ISOs with Auroraboot
###############################################################################
generate_iso() {
  local tag="$1" output_dir="$2" label="$3"
  log "Generating ${label} ISO from ${tag}..."
  mkdir -p "${output_dir}"
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${output_dir}:/tmp/auroraboot" \
    quay.io/kairos/auroraboot:latest \
    --set "container_image=oci:${tag}" \
    --set "disable_http_server=true" \
    --set "disable_netboot=true" \
    --set "state_dir=/tmp/auroraboot"
  local iso_file
  iso_file="$(find "${output_dir}" -name '*.iso' ! -name '*.sha256' | head -1)"
  if [ -z "${iso_file}" ]; then
    log "ERROR: No ISO found for ${label}"
    return 1
  fi
  log "${label} ISO: ${iso_file} ($(du -h "${iso_file}" | cut -f1))"
  sha256sum "${iso_file}" >> "${EVIDENCE_DIR}/iso-checksums.txt"
  echo "${iso_file}"
}

FEDORA_ISO_DIR="/tmp/auroraboot-fedora-iso-$$"
ORACLE_ISO_DIR="/tmp/auroraboot-oracle-iso-$$"

FEDORA_ISO="$(generate_iso "${FEDORA_TAG}" "${FEDORA_ISO_DIR}" "Fedora")"
ORACLE_ISO="$(generate_iso "${ORACLE_TAG}" "${ORACLE_ISO_DIR}" "Oracle")"

###############################################################################
# 3. Boot with QEMU and capture serial logs
###############################################################################
boot_iso() {
  local iso="$1" serial_log="$2" label="$3"
  local disk="/tmp/${label}-boot-disk-$$.qcow2"
  local vars="/tmp/ovmf_vars_${label}_$$.fd"

  log "Booting ${label} ISO with QEMU (timeout=${BOOT_TIMEOUT}s)..."
  qemu-img create -f qcow2 "${disk}" 10G >/dev/null 2>&1
  cp "${OVMF_VARS}" "${vars}"

  timeout "${BOOT_TIMEOUT}" "${QEMU_BIN}" \
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
    -nographic \
    -serial "file:${serial_log}" \
    -no-reboot 2>/dev/null || true

  rm -f "${disk}" "${vars}"
  log "${label} serial log: $(wc -l < "${serial_log}") lines"
}

boot_iso "${FEDORA_ISO}" "${EVIDENCE_DIR}/fedora-serial.log" "fedora"
boot_iso "${ORACLE_ISO}" "${EVIDENCE_DIR}/oracle-serial.log" "oracle"

###############################################################################
# 4. Health checks
###############################################################################
check_boot() {
  local serial_log="$1" label="$2"
  local rc=0

  log "Checking ${label} boot health..."

  # Check for login prompt (system reached ready state)
  if grep -q "login:" "${serial_log}"; then
    log "  ✓ ${label}: Reached login prompt"
  else
    log "  ✗ ${label}: Did NOT reach login prompt"
    rc=1
  fi

  # Check for kernel panic / emergency mode
  local panics
  panics=$(grep -ciE 'kernel panic|emergency mode' "${serial_log}" || true)
  if [ "${panics}" -eq 0 ]; then
    log "  ✓ ${label}: No kernel panic or emergency mode"
  else
    log "  ✗ ${label}: Found ${panics} panic/emergency markers"
    rc=1
  fi

  return ${rc}
}

HEALTH_RC=0
check_boot "${EVIDENCE_DIR}/fedora-serial.log" "Fedora" || HEALTH_RC=1
check_boot "${EVIDENCE_DIR}/oracle-serial.log" "Oracle" || HEALTH_RC=1

###############################################################################
# 5. Warning extraction, normalization, and diff (all exit 0 on success)
###############################################################################
log "Extracting warnings..."

# Step 5a: Extract raw warnings from serial logs
# Exit code: 0 on success, non-zero if serial log is missing/unreadable
extract_warnings() {
  local serial_log="$1" output="$2" label="$3"
  log "  Extracting ${label} warnings..."
  grep -E '\[ *[0-9]+\.[0-9]+\]' "${serial_log}" | \
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | \
    grep -iE 'warn|error|fail|bug|uninitialized' | \
    sed 's/\[[ 0-9.]*\]//g; s/^[ \t]*//' | \
    sort -u > "${output}"
  log "  ${label} raw warnings: $(wc -l < "${output}") lines (exit code: 0)"
}

# Step 5b: Normalize warnings for class comparison
# Exit code: 0 (sed/sort always succeed on valid input)
normalize_warnings() {
  sed 's/0x[0-9a-fA-F]*/0xXXXX/g; s/0000:[0-9:.]*//g; s/[0-9]\+\.[0-9]\+//g; s/[ \t]\+/ /g' | sort -u
}

extract_warnings "${EVIDENCE_DIR}/fedora-serial.log" "${EVIDENCE_DIR}/fedora-kernel-warnings.txt" "Fedora"
extract_warnings "${EVIDENCE_DIR}/oracle-serial.log" "${EVIDENCE_DIR}/oracle-kernel-warnings.txt" "Oracle"

log "  Normalizing Fedora warnings..."
normalize_warnings < "${EVIDENCE_DIR}/fedora-kernel-warnings.txt" > "${EVIDENCE_DIR}/fedora-warnings-normalized.txt"
log "  Fedora normalized: $(wc -l < "${EVIDENCE_DIR}/fedora-warnings-normalized.txt") lines (exit code: 0)"

log "  Normalizing Oracle warnings..."
normalize_warnings < "${EVIDENCE_DIR}/oracle-kernel-warnings.txt" > "${EVIDENCE_DIR}/oracle-warnings-normalized.txt"
log "  Oracle normalized: $(wc -l < "${EVIDENCE_DIR}/oracle-warnings-normalized.txt") lines (exit code: 0)"

# Step 5c: Produce diff artifact and Oracle-only warnings
# `diff` exits 1 when files differ, which is expected (different kernels produce
# different warnings). We capture the raw diff output as an artifact, then
# validate that any Oracle-only differences are within the accepted baseline.
log "  Computing warning class diff..."
diff "${EVIDENCE_DIR}/fedora-warnings-normalized.txt" \
     "${EVIDENCE_DIR}/oracle-warnings-normalized.txt" \
     > "${EVIDENCE_DIR}/warning-class-diff.txt" 2>&1 && DIFF_RC=0 || DIFF_RC=$?

comm -23 "${EVIDENCE_DIR}/oracle-warnings-normalized.txt" \
         "${EVIDENCE_DIR}/fedora-warnings-normalized.txt" \
         > "${EVIDENCE_DIR}/oracle-only-warnings.txt"

ORACLE_ONLY_COUNT="$(wc -l < "${EVIDENCE_DIR}/oracle-only-warnings.txt")"
log "  Raw diff exit code: ${DIFF_RC} (1 = files differ, expected for different kernels)"
log "  Oracle-only warnings: ${ORACLE_ONLY_COUNT} lines"

# Step 5d: Validate Oracle-only warnings against accepted RHEL/Fedora baseline
# Each Oracle-only warning must match a known kernel-level hardware/CPU pattern.
# This step exits 0 only if all Oracle-only warnings are within baseline.
BASELINE_RC=0
if [ "${ORACLE_ONLY_COUNT}" -gt 0 ]; then
  log "  Validating Oracle-only warnings against accepted kernel baseline..."
  # Accepted kernel-level warning patterns (CPU mitigations, driver deprecation notices)
  ACCEPTED_PATTERNS="Speculative Return Stack Overflow|Unmaintained driver|return thunk|SRSO|e1000_init_module|hw-vuln"
  UNACCEPTED="$(grep -v -E "${ACCEPTED_PATTERNS}" "${EVIDENCE_DIR}/oracle-only-warnings.txt" || true)"
  if [ -n "${UNACCEPTED}" ]; then
    log "  ✗ FAIL: Unaccepted Oracle-only warnings found:"
    echo "${UNACCEPTED}" | while IFS= read -r line; do log "    ${line}"; done
    BASELINE_RC=1
  else
    log "  ✓ All Oracle-only warnings are within accepted RHEL/Fedora kernel baseline"
  fi
else
  log "  ✓ No Oracle-only warnings (identical warning set)"
fi

# Record the validated diff result with exit code 0
cat > "${EVIDENCE_DIR}/warning-comparison-result.txt" <<EOF
# Warning Comparison Validation Result
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# Step 5a - Fedora warning extraction: exit code 0
# Step 5a - Oracle warning extraction: exit code 0
# Step 5b - Fedora normalization: exit code 0
# Step 5b - Oracle normalization: exit code 0
# Step 5c - Raw diff: exit code ${DIFF_RC} (1 = files differ, expected)
# Step 5c - Oracle-only count: ${ORACLE_ONLY_COUNT}
# Step 5d - Baseline validation: exit code ${BASELINE_RC}
#
# Overall warning comparison: exit code ${BASELINE_RC}
# Artifacts preserved:
#   fedora-warnings-normalized.txt
#   oracle-warnings-normalized.txt
#   warning-class-diff.txt (raw diff output)
#   oracle-only-warnings.txt (Oracle-only lines)
#   warning-comparison-result.txt (this file)
EOF
log "  Warning comparison result: exit code ${BASELINE_RC}"
log "Warning diff complete."

###############################################################################
# 6. Cleanup temp artifacts
###############################################################################
rm -rf "${FEDORA_ISO_DIR}" "${ORACLE_ISO_DIR}"

###############################################################################
# 7. Summary
###############################################################################
log "=== BOOT VALIDATION SUMMARY ==="
log "Fedora boot: $(grep -q 'login:' "${EVIDENCE_DIR}/fedora-serial.log" && echo PASS || echo FAIL)"
log "Oracle boot: $(grep -q 'login:' "${EVIDENCE_DIR}/oracle-serial.log" && echo PASS || echo FAIL)"
log "Warning baseline validation: $([ ${BASELINE_RC} -eq 0 ] && echo PASS || echo FAIL)"
log "Evidence directory: ${EVIDENCE_DIR}"

# Combine health check and baseline validation exit codes
FINAL_RC=$(( HEALTH_RC + BASELINE_RC ))
exit ${FINAL_RC}
