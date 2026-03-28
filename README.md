# Morpheus and VME/HVM Boot Menu Toggle

Enable or disable the **BIOS boot menu** on HPE VM Essentials (VME) / KVM virtual machines. No VM shutdown required — the change takes effect on the next start.

---

## Which Method Is Right for Me?

This repo provides three ways to use these tools. Pick the one that matches your setup:

| Method | I have... | Skill level |
|--------|-----------|-------------|
| [**Option A — Standalone Shell**](#option-a--standalone-shell-scripts) | Direct SSH or console access to a VME host | Any |
| [**Option B — Morpheus Agent Task**](#option-b--morpheus-agent-tasks) | HPE VM Essentials + Morpheus Agent installed on VME hosts | Intermediate |
| [**Option C — Morpheus Appliance Task**](#option-c--morpheus-appliance-tasks-python) | Morpheus Enterprise (no agent required on hosts) | Intermediate |

> **Not sure?** Start with Option A. It has zero dependencies and works anywhere.

---

## How It Works

Regardless of method, the logic is the same:

1. Fetch the VM's libvirt XML configuration (`virsh dumpxml --inactive`)
2. Find or insert the `<bootmenu>` tag inside the `<os>` block
3. Set `enable='yes'` (with a configurable timeout) or `enable='no'`
4. Re-apply the XML with `virsh define`

Using `--inactive` means the **running VM is not affected** — only the saved config is changed. Restart the VM to activate.

---

## Option A — Standalone Shell Scripts

**Best for:** anyone with SSH or console access to a VME/KVM host. No Morpheus required.

### Files
```
standalone/
├── bootmenu-enable.sh
└── bootmenu-disable.sh
```

### Requirements
- Run directly on a VME/KVM host (or SSH to one)
- `sudo` access to run `virsh` commands
- `python3` and `bc` — both present on all VME hosts by default

### Usage

**1. Copy the scripts to your VME host**

```bash
scp standalone/bootmenu-enable.sh  user@your-vme-host:~/
scp standalone/bootmenu-disable.sh user@your-vme-host:~/
```

Or paste the contents into a file on the host directly.

**2. Make them executable**

```bash
chmod +x ~/bootmenu-enable.sh ~/bootmenu-disable.sh
```

**3. Find your VM name**

```bash
sudo virsh list --all
```

The **Name** column is what you pass to the scripts.

**4. Enable the boot menu**

```bash
# Default timeout (5 seconds)
./bootmenu-enable.sh my-server

# Custom timeout (10 seconds)
./bootmenu-enable.sh my-server 10000
```

**5. Disable the boot menu**

```bash
./bootmenu-disable.sh my-server
```

**6. Restart the VM to apply**

```bash
sudo virsh reboot my-server
```

### Example Output

```
[1/4] Checking VM exists...
  [ok] Domain 'my-server' found.
[2/4] Fetching inactive XML...
  [ok] XML retrieved (4821 bytes).
[3/4] Patching XML (timeout=5000ms / 5.0s)...
  [ok] Replaced existing <bootmenu> tag -> enable=yes, timeout=5000
[4/4] Applying patched XML...
  [ok] virsh define succeeded.
  [ok] Confirmed in XML: <bootmenu enable='yes' timeout='5000'/>

Done. Boot menu is ENABLED for 'my-server'.
The menu will appear for 5.0 seconds on next VM start.
Restart the VM to activate: sudo virsh reboot my-server
```

---

## Option B — Morpheus Agent Tasks

**Best for:** Morpheus users who have the **Morpheus Agent installed on their VME host nodes**. The task runs directly on the host via the agent — no SSH credentials or sshpass required.

### Files
```
morpheus/agent-tasks/
├── task-bootmenu-enable.sh
└── task-bootmenu-disable.sh
```

### Requirements
- Morpheus Data Cloud (any edition that supports Operational Workflows)
- Morpheus Agent installed on your VME host nodes
- VME hosts visible in **Infrastructure → Hosts** in Morpheus

### How Agent Tasks Work

When Execute Target is set to `Resource`, Morpheus sends the script to the selected host and runs it there via the agent. The `<%=customOptions.vm_id%>` placeholders are replaced with the values you enter in the workflow form before the script executes — so the script always sees real values, not template strings.

### Setup

#### Step 1 — Create the Option Types

Option Types are the input fields shown on your workflow form. Create these in **Administration → Library → Option Types**.

**Input: VM Name**

| Field | Value |
|-------|-------|
| Name | `vm_id` |
| Label | `VM Name` |
| Field Name | `vm_id` |
| Type | `Text` |
| Required | Yes |
| Help Block | The libvirt domain name of the VM (as shown in `virsh list --all`) |

**Input: Boot Menu Timeout** *(enable workflow only)*

| Field | Value |
|-------|-------|
| Name | `bootmenu_timeout` |
| Label | `Boot Menu Timeout (ms)` |
| Field Name | `bootmenu_timeout` |
| Type | `Text` |
| Required | No |
| Default Value | `5000` |
| Help Block | How long the boot menu stays visible. 5000 = 5 seconds. Min: 1000, Max: 30000. |

#### Step 2 — Create the Tasks

Go to **Provisioning → Automation → Tasks** → **+ Add Task**.

**Task: Enable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Enable Boot Menu (Agent)` |
| Type | `Shell Script` |
| Execute Target | `Resource` |
| Script | *(paste full contents of `morpheus/agent-tasks/task-bootmenu-enable.sh`)* |

**Task: Disable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Disable Boot Menu (Agent)` |
| Type | `Shell Script` |
| Execute Target | `Resource` |
| Script | *(paste full contents of `morpheus/agent-tasks/task-bootmenu-disable.sh`)* |

> **Execute Target must be `Resource`** — this tells Morpheus to run the script on the selected host via the agent, not on the appliance.

#### Step 3 — Create the Workflows

Go to **Provisioning → Automation → Workflows** → **+ Add Workflow**.

**Workflow: Enable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Enable Boot Menu` |
| Type | `Operational` |

- Under **Tasks**: add `VME - Enable Boot Menu (Agent)`
- Under **Option Types**: add `vm_id` and `bootmenu_timeout`

**Workflow: Disable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Disable Boot Menu` |
| Type | `Operational` |

- Under **Tasks**: add `VME - Disable Boot Menu (Agent)`
- Under **Option Types**: add `vm_id`

#### Step 4 — Run the Workflow

1. Go to **Provisioning → Automation → Workflows**
2. Click **▶ Execute** on the workflow
3. Fill in **VM Name** (e.g. `my-server`) and optionally the timeout
4. Under **Target** — select the **VME host** that the VM lives on
5. Click **Execute** and view the output log

> **Tip:** The VM name must match the libvirt domain name on that specific host. If unsure, SSH to the host and run `sudo virsh list --all`.

---

## Option C — Morpheus Appliance Tasks (Python)

**Best for:** Morpheus users where the agent is **not** installed on VME hosts. The task runs on the Morpheus appliance and SSHes to the VME host automatically. The VM and its host are auto-discovered from the Morpheus API — you only need to enter the VM name.

### Files
```
morpheus/tasks/
├── task-bootmenu-enable.py
└── task-bootmenu-disable.py
```

### Requirements
- Morpheus Data Cloud (any edition)
- VME cloud synced in Morpheus (VMs visible under Infrastructure → Compute)
- `sshpass` installed on the Morpheus appliance:
  ```bash
  which sshpass || sudo apt-get install -y sshpass
  ```
- An SSH credential stored in **Infrastructure → Trust → Credentials**

### Setup

#### Step 1 — Create the SSH Credential

This stores the username and password used to SSH to your VME hosts. It is retrieved securely through the Morpheus API at runtime and never stored in the task script.

1. Go to **Infrastructure → Trust → Credentials**
2. Click **+ Add Credential**
3. Fill in:
   - **Name:** anything memorable (e.g. `vme-ssh`)
   - **Type:** `Username / Password`
   - **Username:** SSH user on your VME hosts
   - **Password:** SSH password for that user
4. Click **Save**

> **Finding the credential ID later:** Hover over the **pencil (edit) icon** next to the credential. Your browser's status bar will show a URL like `.../credentials/42/edit` — the number is the numeric ID. You can use either the name or the ID as the input value.

#### Step 2 — Create the Option Types

Go to **Administration → Library → Option Types** → **+ Add Option Type**.

**Input: VM**

| Field | Value |
|-------|-------|
| Name | `vm_id` |
| Label | `VM` |
| Field Name | `vm_id` |
| Type | `Text` |
| Required | Yes |
| Help Block | VM name (e.g. `my-server`) or numeric Morpheus server ID |

**Input: SSH Credential**

| Field | Value |
|-------|-------|
| Name | `vme_ssh_cred_id` |
| Label | `SSH Credential` |
| Field Name | `vme_ssh_cred_id` |
| Type | `Text` |
| Required | Yes |
| Default Value | *(name of the credential you created in Step 1, e.g. `vme-ssh`)* |
| Help Block | Name or numeric ID of the Infrastructure > Trust credential used for SSH |

**Input: VME Host Override** *(optional)*

| Field | Value |
|-------|-------|
| Name | `vme_host` |
| Label | `VME Host (optional)` |
| Field Name | `vme_host` |
| Type | `Text` |
| Required | No |
| Help Block | Leave blank — the host is auto-discovered from Morpheus. Only fill in if auto-discovery fails. |

**Input: Boot Menu Timeout** *(enable workflow only)*

| Field | Value |
|-------|-------|
| Name | `bootmenu_timeout` |
| Label | `Boot Menu Timeout (ms)` |
| Field Name | `bootmenu_timeout` |
| Type | `Text` |
| Required | No |
| Default Value | `5000` |
| Help Block | How long the boot menu stays visible. 5000 = 5 seconds. Min: 1000, Max: 30000. |

#### Step 3 — Create the Tasks

Go to **Provisioning → Automation → Tasks** → **+ Add Task**.

**Task: Enable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Enable Boot Menu` |
| Type | `Python Script` |
| Execute Target | `Local` |
| Script | *(paste full contents of `morpheus/tasks/task-bootmenu-enable.py`)* |

**Task: Disable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Disable Boot Menu` |
| Type | `Python Script` |
| Execute Target | `Local` |
| Script | *(paste full contents of `morpheus/tasks/task-bootmenu-disable.py`)* |

> **Execute Target must be `Local`** — the task runs on the Morpheus appliance and SSHes out to the VME host. Do not set this to `Remote` or `Resource`.

#### Step 4 — Create the Workflows

Go to **Provisioning → Automation → Workflows** → **+ Add Workflow**.

**Workflow: Enable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Enable Boot Menu` |
| Type | `Operational` |

- Under **Tasks**: add `VME - Enable Boot Menu`
- Under **Option Types**: add `vm_id`, `vme_ssh_cred_id`, `vme_host`, `bootmenu_timeout`

**Workflow: Disable Boot Menu**

| Field | Value |
|-------|-------|
| Name | `VME - Disable Boot Menu` |
| Type | `Operational` |

- Under **Tasks**: add `VME - Disable Boot Menu`
- Under **Option Types**: add `vm_id`, `vme_ssh_cred_id`, `vme_host`

#### Step 5 — Run the Workflow

1. Go to **Provisioning → Automation → Workflows**
2. Click **▶ Execute** on the workflow
3. Fill in:
   - **VM:** VM name or server ID (e.g. `my-server`)
   - **SSH Credential:** credential name (e.g. `vme-ssh`)
   - **VME Host (optional):** leave blank
   - **Boot Menu Timeout (ms):** leave blank for 5 seconds (enable only)
4. Click **Execute** and view the output log

### Example Output

```
[1/5] Resolving SSH credential "vme-ssh"...
  [ok] Credential resolved (user: morpheus-local).
[2/5] Resolving VM from Morpheus server ID my-server...
  [ok] Name "my-server" resolved to server ID 29.
  [..] parentServer ID=3, fetching host record...
  [ok] Host IP resolved: 192.168.1.10
[3/5] Fetching inactive XML for domain "my-server"...
  [ok] XML retrieved (4821 bytes).
[4/5] Patching XML (timeout=5000 ms)...
  [ok] Replaced existing <bootmenu> tag -> enable=yes, timeout=5000 (5.0s)
[5/5] Uploading and applying patched XML...
  [ok] virsh define succeeded.
  [ok] Confirmed in XML: <bootmenu enable='yes' timeout='5000'/>

Done. Boot menu is ENABLED for "my-server".
The menu will appear for 5.0 seconds on next VM start.
```

---

## Troubleshooting

### Boot menu doesn't appear after enabling
The change applies on the next **cold start** (full stop and start). A warm reboot may not be sufficient on all firmware. Try `sudo virsh destroy <vm>` then `sudo virsh start <vm>`.

### `Domain not found`
The name you entered doesn't match the libvirt domain name. Run `sudo virsh list --all` on the host to confirm the exact name.

### `virsh define` fails with XML error
Run `sudo virsh dumpxml --inactive <vm>` and inspect the `<os>` block manually. The XML should have a single well-formed `<bootmenu .../>` tag inside `<os>`.

### *(Option B)* Task output shows template strings like `<%=customOptions.vm_id%>`
The Morpheus input substitution didn't run. This usually means the Option Type `Field Name` doesn't exactly match what the script expects (`vm_id`, `bootmenu_timeout`). Double-check the Field Name values in Administration → Library → Option Types.

### *(Option C)* `SSL: CERTIFICATE_VERIFY_FAILED`
The Python tasks handle self-signed certificates automatically. If you still see this, confirm Execute Target is set to `Local`.

### *(Option C)* `No credential named "..." found`
The name doesn't match what's in Infrastructure → Trust → Credentials. Check for typos or use the numeric ID (hover the edit pencil to find it in the browser status bar).

### *(Option C)* `Could not auto-discover VME host IP`
Morpheus has no host linked to this VM. Go to **Infrastructure → Clouds**, find your VME cloud, and trigger a **Refresh**. As a workaround, enter the host IP directly in the **VME Host (optional)** input.

### *(Option C)* `SSH failed`
Test the connection manually from the Morpheus appliance:
```bash
sshpass -p 'yourpassword' ssh -o StrictHostKeyChecking=no user@vme-host "sudo virsh list --all"
```

---

## File Structure

```
vme-bootmenu/
├── README.md
├── standalone/                       # Option A — run directly on the VME host
│   ├── bootmenu-enable.sh
│   └── bootmenu-disable.sh
└── morpheus/
    ├── agent-tasks/                  # Option B — Shell task via Morpheus Agent
    │   ├── task-bootmenu-enable.sh
    │   └── task-bootmenu-disable.sh
    └── tasks/                        # Option C — Python task via Morpheus appliance
        ├── task-bootmenu-enable.py
        └── task-bootmenu-disable.py
```

---

## Tested On

| Component | Version |
|-----------|---------|
| HPE VM Essentials | 8.0.x |
| Morpheus | 8.x |
| libvirt | 10.x |
| QEMU | 8.2 |
| Host OS | Ubuntu 24.04 |
