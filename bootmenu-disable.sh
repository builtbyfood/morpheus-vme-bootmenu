#!/usr/bin/env bash
# =============================================================================
# bootmenu-disable.sh — Disable BIOS boot menu on a KVM/libvirt VM
# =============================================================================
# Edits the inactive libvirt XML for a guest VM to set:
#     <bootmenu enable='no'/>
# The change takes effect on the VM's next start. No shutdown required.
#
# Usage:
#   ./bootmenu-disable.sh <vm-name>
#
# Arguments:
#   vm-name : libvirt domain name (as shown in: virsh list --all)
#
# Example:
#   ./bootmenu-disable.sh my-server
#
# Requirements:
#   - Run directly on the VME/KVM host (or via SSH)
#   - sudo access to virsh
#   - python3 (for XML patching — available on all VME hosts)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <vm-name>"
    echo "  vm-name : libvirt domain name (see: virsh list --all)"
    exit 1
fi

VM_NAME="${1}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "[1/4] Checking VM exists..."
if ! sudo virsh dominfo "${VM_NAME}" &>/dev/null; then
    echo "[FATAL] Domain '${VM_NAME}' not found."
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
echo "Restart the VM to activate: sudo virsh reboot ${VM_NAME}"
