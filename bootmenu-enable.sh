#!/usr/bin/env bash
# =============================================================================
# bootmenu-enable.sh — Enable BIOS boot menu on a KVM/libvirt VM
# =============================================================================
# Edits the inactive libvirt XML for a guest VM to set:
#     <bootmenu enable='yes' timeout='<ms>'/>
# The change takes effect on the VM's next start. No shutdown required.
#
# Usage:
#   ./bootmenu-enable.sh <vm-name> [timeout-ms]
#
# Arguments:
#   vm-name     : libvirt domain name (as shown in: virsh list --all)
#   timeout-ms  : (optional) how long the menu stays visible in milliseconds
#                 default: 5000 (5 seconds), min: 1000, max: 30000
#
# Examples:
#   ./bootmenu-enable.sh my-server
#   ./bootmenu-enable.sh my-server 10000
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
    echo "Usage: $0 <vm-name> [timeout-ms]"
    echo "  vm-name    : libvirt domain name (see: virsh list --all)"
    echo "  timeout-ms : menu display time in ms (default: 5000)"
    exit 1
fi

VM_NAME="${1}"
TIMEOUT_MS="${2:-5000}"

# Clamp timeout to 1000–30000
if ! [[ "${TIMEOUT_MS}" =~ ^[0-9]+$ ]]; then
    echo "[WARN] Invalid timeout '${TIMEOUT_MS}', using default 5000ms."
    TIMEOUT_MS=5000
fi
if (( TIMEOUT_MS < 1000 )); then TIMEOUT_MS=1000; fi
if (( TIMEOUT_MS > 30000 )); then TIMEOUT_MS=30000; fi

TIMEOUT_SEC=$(echo "scale=1; ${TIMEOUT_MS}/1000" | bc)

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

echo "[3/4] Patching XML (timeout=${TIMEOUT_MS}ms / ${TIMEOUT_SEC}s)..."
PY_SCRIPT=$(mktemp /tmp/patch_bootmenu_XXXXXX.py)
cat > "${PY_SCRIPT}" <<'PYEOF'
import sys, re

vm_name    = sys.argv[1]
timeout_ms = sys.argv[2]
xml        = sys.stdin.read()

tag = f"<bootmenu enable='yes' timeout='{timeout_ms}'/>"

if re.search(r'<bootmenu\b', xml, re.IGNORECASE):
    xml = re.sub(r'<bootmenu\b[^/]*/>\n?', tag + '\n', xml)
    print(f"  [ok] Replaced existing <bootmenu> tag -> enable=yes, timeout={timeout_ms}", file=sys.stderr)
elif '</os>' in xml:
    xml = xml.replace('</os>', f'    {tag}\n  </os>', 1)
    print(f"  [ok] Inserted <bootmenu> tag -> enable=yes, timeout={timeout_ms}", file=sys.stderr)
else:
    print("[FATAL] Could not find </os> tag in XML — unexpected structure.", file=sys.stderr)
    sys.exit(1)

print(xml, end='')
PYEOF
PATCHED_XML=$(echo "${XML}" | python3 "${PY_SCRIPT}" "${VM_NAME}" "${TIMEOUT_MS}")
rm -f "${PY_SCRIPT}"

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
echo "[4/4] Applying patched XML..."
TMP_XML=$(mktemp /tmp/${VM_NAME}-bootmenu-enable-XXXXXX.xml)
echo "${PATCHED_XML}" > "${TMP_XML}"
sudo virsh define "${TMP_XML}"
rm -f "${TMP_XML}"
echo "  [ok] virsh define succeeded."

# Verify
VERIFY=$(sudo virsh dumpxml --inactive "${VM_NAME}" | grep -o "<bootmenu[^/]*/>" || true)
if [[ -n "${VERIFY}" ]]; then
    echo "  [ok] Confirmed in XML: ${VERIFY}"
else
    echo "[WARN] Could not confirm <bootmenu> tag in XML after redefine — check manually."
fi

echo ""
echo "Done. Boot menu is ENABLED for '${VM_NAME}'."
echo "The menu will appear for ${TIMEOUT_SEC} seconds on next VM start."
echo "Restart the VM to activate: sudo virsh reboot ${VM_NAME}"
