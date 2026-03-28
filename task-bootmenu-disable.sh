#!/usr/bin/env bash
# =============================================================================
# task-bootmenu-disable.sh — Morpheus Agent Task: Disable BIOS Boot Menu
# =============================================================================
# Designed to run as a Morpheus Operational Workflow task with
# Execute Target: Resource (VME host with agent installed).
#
# Morpheus substitutes customOptions values at runtime before execution.
# The script runs directly on the target VME host — no SSH or sshpass needed.
#
# Morpheus Inputs (customOptions)
# --------------------------------
#   vm_id : VM name or Morpheus server ID
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Inputs — injected by Morpheus at runtime via customOptions substitution
# ---------------------------------------------------------------------------
VM_NAME="<%=customOptions.vm_id%>"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "${VM_NAME}" ]]; then
    echo "[FATAL] vm_id input is required."
    exit 1
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "[1/4] Checking VM exists on this host..."
if ! sudo virsh dominfo "${VM_NAME}" &>/dev/null; then
    echo "[FATAL] Domain '${VM_NAME}' not found on this host."
    echo "  Available VMs:"
    sudo virsh list --all --name | sed 's/^/    /'
    exit 1
fi
echo "  [ok] Domain '${VM_NAME}' found."

# ---------------------------------------------------------------------------
# Patch XML
# ---------------------------------------------------------------------------
echo "[2/4] Fetching inactive XML..."
XML=$(sudo virsh dumpxml --inactive "${VM_NAME}")
echo "  [ok] XML retrieved (${#XML} bytes)."

echo "[3/4] Patching XML..."
PY_SCRIPT=$(mktemp /tmp/patch_bootmenu_XXXXXX.py)
cat > "${PY_SCRIPT}" <<'PYEOF'
import sys, re

vm_name = sys.argv[1]
xml     = sys.stdin.read()

tag = "<bootmenu enable='no'/>"

if re.search(r'<bootmenu\b', xml, re.IGNORECASE):
    xml = re.sub(r'<bootmenu\b[^/]*/>\n?', tag + '\n', xml)
    print(f"  [ok] Replaced existing <bootmenu> tag -> enable=no", file=sys.stderr)
elif '</os>' in xml:
    xml = xml.replace('</os>', f'    {tag}\n  </os>', 1)
    print(f"  [ok] Inserted <bootmenu> tag -> enable=no", file=sys.stderr)
else:
    print("[FATAL] Could not find </os> tag in XML — unexpected structure.", file=sys.stderr)
    sys.exit(1)

print(xml, end='')
PYEOF
PATCHED_XML=$(echo "${XML}" | python3 "${PY_SCRIPT}" "${VM_NAME}")
rm -f "${PY_SCRIPT}"

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
echo "[4/4] Applying patched XML..."
TMP_XML=$(mktemp /tmp/${VM_NAME}-bootmenu-disable-XXXXXX.xml)
echo "${PATCHED_XML}" > "${TMP_XML}"
sudo virsh define "${TMP_XML}"
rm -f "${TMP_XML}"
echo "  [ok] virsh define succeeded."

# Verify
VERIFY=$(sudo virsh dumpxml --inactive "${VM_NAME}" | grep -o "<bootmenu[^/]*/>" || true)
if [[ -n "${VERIFY}" ]]; then
    echo "  [ok] Confirmed in XML: ${VERIFY}"
else
    echo "  [ok] <bootmenu> tag absent (libvirt default = disabled)."
fi

echo ""
echo "Done. Boot menu is DISABLED for '${VM_NAME}'."
echo "No boot menu will appear on next VM start."
echo "Restart the VM to activate: sudo virsh reboot ${VM_NAME}  (or from Morpheus UI)"
