#!/usr/bin/env python3
"""
Morpheus Task: Enable Boot Menu (BIOS)
======================================
Edits the inactive libvirt XML for a VME guest to set:
    <bootmenu enable='yes' timeout='<ms>'/>
inside the <os> block, then redefines the domain via virsh.
The change takes effect on the VM's next start — no shutdown required.

Morpheus Inputs (customOptions)
--------------------------------
  vm_id    : Morpheus server ID — select from the VM List typeahead
  vme_ssh_cred_id  : Infrastructure > Trust credential name or numeric ID
                     (credential must contain username + password)
  vme_host         : (optional) VME host IP/hostname — only needed if Morpheus
                     parentServer auto-discovery returns empty (e.g. stale cloud sync)
  bootmenu_timeout : Boot menu display time in milliseconds (default: 5000 = 5 sec)
"""

import re
import sys
import json
import subprocess
import urllib.request
import urllib.parse
import tempfile
import os

# ---------------------------------------------------------------------------
# Morpheus context
# ---------------------------------------------------------------------------
opts          = morpheus['customOptions']
appliance_url = morpheus['morpheus']['applianceUrl'].rstrip('/')
api_token     = morpheus['morpheus']['apiAccessToken']

VM_ID     = str(opts.get('vm_id', '')).strip()
CRED_INPUT        = str(opts.get('vme_ssh_cred_id', '')).strip()
VME_HOST_OVERRIDE = str(opts.get('vme_host', '')).strip()

_timeout_raw      = str(opts.get('bootmenu_timeout', '5000')).strip() or '5000'
try:
    BOOTMENU_TIMEOUT = max(1000, min(30000, int(_timeout_raw)))
except (ValueError, TypeError):
    BOOTMENU_TIMEOUT = 5000

# Populated during resolution
SSH_USER     = ''
SSH_PASSWORD = ''
VME_HOST     = ''
VM_DOMAIN    = ''

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def fail(msg):
    print(f'[FATAL] {msg}')
    sys.exit(1)


def morpheus_get(path, params=None):
    """GET from the Morpheus API, return parsed JSON."""
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    url = f'{appliance_url}/api/{path}'
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        'Authorization': f'Bearer {api_token}',
        'Content-Type': 'application/json',
    })
    with urllib.request.urlopen(req, context=ctx) as resp:
        return json.loads(resp.read())


def resolve_credential(cred_input):
    """
    Return (username, password) from a Morpheus Trust credential.
    Accepts either a credential name or a numeric ID.
    """
    if cred_input.isdigit():
        data = morpheus_get(f'credentials/{cred_input}')
        cred = data.get('credential', {})
    else:
        data = morpheus_get('credentials', params={'name': cred_input, 'max': 50})
        creds = data.get('credentials', [])
        matches = [c for c in creds if c.get('name', '').strip().lower() == cred_input.lower()]
        if not matches:
            names = [c.get('name') for c in creds]
            fail(
                f'No credential named "{cred_input}" found in Infrastructure > Trust > Credentials.\n'
                f'  Available: {names}\n'
                f'  Tip: hover the edit (pencil) icon — the URL in the browser status bar shows the numeric ID.'
            )
        cred_id = matches[0]['id']
        data = morpheus_get(f'credentials/{cred_id}')
        cred = data.get('credential', {})

    username = cred.get('username', '')
    password = cred.get('password', '')
    if not username or not password:
        fail(f'Credential "{cred_input}" is missing username or password. Verify in Infrastructure > Trust.')
    return username, password


def resolve_vm(vm_input):
    """
    Look up a Morpheus server record by numeric ID or name string.
    Returns (domain_name, host_ip).
    domain_name: externalId (libvirt domain) or server name as fallback.
    host_ip: from parentServer, which is the VME hypervisor host for unmanaged guest VMs.
    """
    if str(vm_input).strip().isdigit():
        # Numeric ID — direct lookup
        data   = morpheus_get(f'servers/{vm_input}')
        server = data.get('server', {})
        if not server:
            fail(f'Server ID {vm_input} not found in Morpheus (/api/servers/{vm_input}).')
    else:
        # Name string — search, then match exact or closest
        data    = morpheus_get('servers', params={'name': vm_input, 'max': 10})
        servers = data.get('servers', [])
        # Filter out hypervisor host nodes (vmHypervisor=True are the hosts, not guests)
        guests  = [s for s in servers if not s.get('vmHypervisor', False)]
        exact   = [s for s in guests if s.get('name', '').lower() == str(vm_input).lower()
                   or s.get('externalId', '').lower() == str(vm_input).lower()]
        server  = (exact or guests or [None])[0]
        if not server:
            fail(
                f'No VM named "{vm_input}" found in Morpheus (/api/servers?name={vm_input}).\n'
                f'  Check the name matches exactly, or use the numeric server ID instead.'
            )
        print(f'  [ok] Name "{vm_input}" resolved to server ID {server.get("id")}.')

    domain = server.get('externalId', '').strip() or server.get('name', '').strip()
    if not domain:
        fail(f'Could not determine libvirt domain name for VM "{vm_input}".')

    # parentServer on a guest VM is a stub (id only) — need a second lookup for the IP
    parent     = server.get('parentServer') or {}
    parent_id  = parent.get('id')
    host_ip    = ''

    if parent_id:
        print(f'  [..] parentServer ID={parent_id}, fetching host record...')
        host_data  = morpheus_get(f'servers/{parent_id}')
        host_server = host_data.get('server', {})
        host_ip = (
            host_server.get('sshHost') or
            host_server.get('internalIp') or
            host_server.get('externalIp') or
            ''
        ).strip()
        if host_ip:
            print(f'  [ok] Host IP resolved: {host_ip}')

    return domain, host_ip


def ssh(cmd, capture=False):
    full = [
        'sshpass', '-p', SSH_PASSWORD,
        'ssh', '-o', 'StrictHostKeyChecking=no',
        '-o', 'ConnectTimeout=15',
        f'{SSH_USER}@{VME_HOST}',
        cmd,
    ]
    result = subprocess.run(full, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f'SSH failed (rc={result.returncode}):\n  cmd : {cmd}\n  err : {result.stderr.strip()}')
    return result.stdout.strip() if capture else None


def scp_to(local, remote):
    result = subprocess.run(
        ['sshpass', '-p', SSH_PASSWORD,
         'scp', '-o', 'StrictHostKeyChecking=no',
         local, f'{SSH_USER}@{VME_HOST}:{remote}'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        fail(f'SCP failed: {result.stderr.strip()}')


# ---------------------------------------------------------------------------
# XML patch
# ---------------------------------------------------------------------------
def patch_xml_enable_bootmenu(xml, timeout_ms):
    """
    Insert or replace <bootmenu .../> inside the <os> block.
    Sets enable='yes' and timeout=<timeout_ms>.
    """
    bootmenu_tag = f"<bootmenu enable='yes' timeout='{timeout_ms}'/>"
    timeout_sec  = timeout_ms / 1000

    if re.search(r'<bootmenu\b', xml, re.IGNORECASE):
        patched = re.sub(r'<bootmenu\b[^/]*/>\n?', bootmenu_tag + '\n', xml)
        print(f'  [ok] Replaced existing <bootmenu> tag -> enable=yes, timeout={timeout_ms} ({timeout_sec:.1f}s)')
        return patched

    if '</os>' not in xml:
        fail('<os> closing tag not found in VM XML — unexpected XML structure.')
    patched = xml.replace('</os>', f'    {bootmenu_tag}\n  </os>', 1)
    print(f'  [ok] Inserted <bootmenu> tag -> enable=yes, timeout={timeout_ms} ({timeout_sec:.1f}s)')
    return patched


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if not VM_ID:
    fail('vm_id input is required.')
if not CRED_INPUT:
    fail('vme_ssh_cred_id input is required.')

print(f'[1/5] Resolving SSH credential "{CRED_INPUT}"...')
SSH_USER, SSH_PASSWORD = resolve_credential(CRED_INPUT)
print(f'  [ok] Credential resolved (user: {SSH_USER}).')

print(f'[2/5] Resolving VM from Morpheus server ID {VM_ID}...')
VM_DOMAIN, host_ip_from_api = resolve_vm(VM_ID)
VME_HOST = host_ip_from_api or VME_HOST_OVERRIDE
if not VME_HOST:
    fail(
        f'Could not auto-discover VME host IP for server ID {VM_ID}.\n'
        f'  The Morpheus parentServer record is empty — this usually means the VM\n'
        f'  was not discovered via cloud sync, or the sync data is stale.\n'
        f'  Fix: re-run a cloud sync on the VME cloud, or enter the host IP\n'
        f'  manually in the vme_host input and re-run this task.'
    )
print(f'  [ok] Domain: {VM_DOMAIN}  |  Host: {VME_HOST}')

print(f'[3/5] Fetching inactive XML for domain "{VM_DOMAIN}"...')
xml = ssh(f"sudo virsh dumpxml --inactive '{VM_DOMAIN}'", capture=True)
if not xml or '<domain' not in xml:
    fail(f'virsh dumpxml returned empty or invalid output for "{VM_DOMAIN}".')
print(f'  [ok] XML retrieved ({len(xml)} bytes).')

print(f'[4/5] Patching XML (timeout={BOOTMENU_TIMEOUT} ms)...')
patched_xml = patch_xml_enable_bootmenu(xml, BOOTMENU_TIMEOUT)

print('[5/5] Uploading and applying patched XML...')
with tempfile.NamedTemporaryFile(mode='w', suffix='.xml', delete=False) as f:
    f.write(patched_xml)
    local_tmp = f.name

remote_tmp = f'/tmp/{VM_DOMAIN}-bootmenu-enable-$$.xml'
scp_to(local_tmp, remote_tmp)
os.unlink(local_tmp)

ssh(f"sudo virsh define '{remote_tmp}' && rm -f '{remote_tmp}'")
print('  [ok] virsh define succeeded.')

verify_xml = ssh(f"sudo virsh dumpxml --inactive '{VM_DOMAIN}'", capture=True)
m = re.search(r'<bootmenu\b[^/]*/>', verify_xml)
if m:
    print(f'  [ok] Confirmed in XML: {m.group(0)}')
else:
    fail('Verification failed — <bootmenu> tag not found after redefine.')

print()
print(f'Done. Boot menu is ENABLED for "{VM_DOMAIN}".')
print(f'The menu will appear for {BOOTMENU_TIMEOUT / 1000:.1f} seconds on next VM start.')
print(f'Restart the VM to activate: virsh reboot {VM_DOMAIN}  (or from Morpheus UI)')
