# VME Boot Menu Toggle — Morpheus Automation Tasks

Two Morpheus Operational Workflow tasks that enable or disable the **BIOS boot menu** on HPE VM Essentials (VME) virtual machines by directly editing the libvirt XML configuration. No shutdown required — the change takes effect on the VM's next start.

| Task | What it does |
|------|-------------|
| `task-bootmenu-enable.py` | Sets `<bootmenu enable='yes'/>` with a configurable timeout |
| `task-bootmenu-disable.py` | Sets `<bootmenu enable='no'/>` |

---

## How It Works

When you run a task against a VM, it:

1. Resolves your SSH credential from **Infrastructure → Trust**
2. Looks up the VM in Morpheus to find its libvirt domain name and which VME host it lives on
3. SSHs to that host and runs `virsh dumpxml --inactive` to fetch the VM's XML config
4. Patches the `<bootmenu>` tag inside the `<os>` block
5. Uploads the patched XML and runs `virsh define` to apply it
6. Verifies the change landed correctly

The VM does **not** need to be shut down. The `--inactive` flag edits the persistent config rather than the running state.

---

## Prerequisites

### Environment

- **Morpheus Data Cloud** (tested on HPE VM Essentials 8.0.x with Morpheus automation)
- **HPE VM Essentials** hosts running KVM/libvirt
- **`sshpass`** installed on the Morpheus appliance

  To check / install:
  ```bash
  which sshpass || sudo apt-get install -y sshpass
  ```

### Morpheus Setup

- Your VME cloud must be **synced** in Morpheus so VMs appear under **Infrastructure → Compute → Virtual Machines**
- The VME host SSH user must have **passwordless sudo** for `virsh` commands, or sudo with a password stored in the credential

---

## Setup Guide

Follow these steps in order. You only need to do this once — both tasks share the same inputs and credential.

---

### Step 1 — Create the SSH Credential

This stores the username and password used to SSH into your VME hosts. The tasks retrieve it securely at runtime through the Morpheus API — it is never stored in the task script.

1. Go to **Infrastructure → Trust → Credentials**
2. Click **+ Add Credential**
3. Fill in:
   - **Name:** `vme-ssh` (or any name you'll remember — you'll enter this name as an input when running the tasks)
   - **Type:** `Username / Password`
   - **Username:** the SSH user on your VME hosts (e.g. `morpheus-local` or your admin user)
   - **Password:** the SSH password for that user
4. Click **Save**

> **Finding the credential ID later:** If you ever need the numeric ID instead of the name, hover your mouse over the **pencil (edit) icon** next to the credential. Look at the bottom-left of your browser — the status bar will show a URL like `.../credentials/42/edit`. The number in that URL is the ID.

---

### Step 2 — Create the Option Types (Task Inputs)

Option Types define the input fields that appear when you run a workflow. Create these four Option Types — they are shared between both tasks.

Go to **Administration → Library → Option Types** and click **+ Add Option Type** for each one below.

#### Input 1 — VM to Target

| Field | Value |
|-------|-------|
| **Name** | `vm_id` |
| **Label** | `VM` |
| **Field Name** | `vm_id` |
| **Type** | `Text` |
| **Required** | Yes |
| **Help Block** | Enter the VM name (e.g. `my-server`) or its numeric Morpheus server ID |

> **Tip:** If you have many VMs, you can change the Type to **Typeahead** and back it with an Option List that queries your VMs. For most environments a plain Text field works fine — you can type the VM name directly.

#### Input 2 — SSH Credential

| Field | Value |
|-------|-------|
| **Name** | `vme_ssh_cred_id` |
| **Label** | `SSH Credential` |
| **Field Name** | `vme_ssh_cred_id` |
| **Type** | `Text` |
| **Required** | Yes |
| **Default Value** | `vme-ssh` (or whatever you named your credential in Step 1) |
| **Help Block** | Name of the Infrastructure > Trust credential used to SSH to VME hosts |

#### Input 3 — VME Host Override (Optional)

| Field | Value |
|-------|-------|
| **Name** | `vme_host` |
| **Label** | `VME Host (optional)` |
| **Field Name** | `vme_host` |
| **Type** | `Text` |
| **Required** | No |
| **Help Block** | Leave blank — the host is auto-discovered from Morpheus. Only fill this in if auto-discovery fails (e.g. after a stale cloud sync). |

#### Input 4 — Boot Menu Timeout (Enable task only)

| Field | Value |
|-------|-------|
| **Name** | `bootmenu_timeout` |
| **Label** | `Boot Menu Timeout (ms)` |
| **Field Name** | `bootmenu_timeout` |
| **Type** | `Text` |
| **Required** | No |
| **Default Value** | `5000` |
| **Help Block** | How long the boot menu stays visible in milliseconds. 5000 = 5 seconds. Min: 1000, Max: 30000. |

---

### Step 3 — Create the Tasks

Go to **Provisioning → Automation → Tasks** and click **+ Add Task** for each task below.

#### Task 1 — Enable Boot Menu

| Field | Value |
|-------|-------|
| **Name** | `VME - Enable Boot Menu` |
| **Code** | `vme-bootmenu-enable` |
| **Type** | `Python Script` |
| **Script** | *(paste the full contents of `tasks/task-bootmenu-enable.py`)* |
| **Execute Target** | `Local` |

#### Task 2 — Disable Boot Menu

| Field | Value |
|-------|-------|
| **Name** | `VME - Disable Boot Menu` |
| **Code** | `vme-bootmenu-disable` |
| **Type** | `Python Script` |
| **Script** | *(paste the full contents of `tasks/task-bootmenu-disable.py`)* |
| **Execute Target** | `Local` |

> **Execute Target must be `Local`** — the tasks run on the Morpheus appliance itself and SSH out to your VME hosts. Do not set this to `Remote` or `Resource`.

---

### Step 4 — Create the Workflows

Workflows are what tie the inputs (Option Types) to the tasks and give you a runnable form. Create one workflow per task.

Go to **Provisioning → Automation → Workflows** and click **+ Add Workflow**.

#### Workflow 1 — Enable Boot Menu

| Field | Value |
|-------|-------|
| **Name** | `VME - Enable Boot Menu` |
| **Type** | `Operational` |

Under **Tasks**, add:
- `VME - Enable Boot Menu`

Under **Option Types**, add all four inputs you created in Step 2:
- `vm_id`
- `vme_ssh_cred_id`
- `vme_host`
- `bootmenu_timeout`

Save the workflow.

#### Workflow 2 — Disable Boot Menu

| Field | Value |
|-------|-------|
| **Name** | `VME - Disable Boot Menu` |
| **Type** | `Operational` |

Under **Tasks**, add:
- `VME - Disable Boot Menu`

Under **Option Types**, add three inputs (no timeout for disable):
- `vm_id`
- `vme_ssh_cred_id`
- `vme_host`

Save the workflow.

---

## Running the Workflows

1. Go to **Provisioning → Automation → Workflows**
2. Find `VME - Enable Boot Menu` (or Disable) and click **Execute** (the play button ▶)
3. A form will appear with the inputs you defined. Fill in:
   - **VM:** the name of your VM (e.g. `my-server`) or its numeric server ID
   - **SSH Credential:** the credential name from Step 1 (e.g. `vme-ssh`)
   - **VME Host (optional):** leave blank unless auto-discovery has failed
   - **Boot Menu Timeout (ms):** (enable only) leave blank for the default 5 seconds
4. Click **Execute**
5. Click the task result to view the output log

A successful enable run looks like:
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
Restart the VM to activate: virsh reboot my-server  (or from Morpheus UI)
```

**The change takes effect on the next VM start.** Restart the VM from the Morpheus UI or run:
```bash
virsh reboot <vm-name>
```

---

## Troubleshooting

### `SSL: CERTIFICATE_VERIFY_FAILED`
Your Morpheus appliance is using a self-signed certificate. The tasks handle this automatically with an unverified SSL context. If you are still seeing this error, confirm you are running the task with **Execute Target: Local**.

### `No credential named "..." found`
The name you entered doesn't match any credential in Infrastructure → Trust → Credentials. Check for typos, or use the numeric ID instead (hover the edit pencil to find it — see Step 1).

### `No VM named "..." found`
The VM name doesn't match what Morpheus has on record. Check **Infrastructure → Compute → Virtual Machines** for the exact name. Alternatively use the numeric server ID — you can find it by hovering the VM name in the Morpheus UI and checking the URL in your browser status bar.

### `Could not auto-discover VME host IP`
Morpheus doesn't have a `parentServer` record linking this VM to its host. This usually means:
- The VME cloud sync hasn't run recently — go to **Infrastructure → Clouds**, find your VME cloud, and trigger a **Refresh**
- The VM was created outside of Morpheus and hasn't been fully discovered

As a workaround, enter the VME host IP directly in the **VME Host (optional)** input field.

### `SSH failed` / `virsh` permission denied
The SSH user in your credential needs passwordless sudo for virsh, or the password needs to match. Test manually:
```bash
ssh <user>@<vme-host> "sudo virsh list --all"
```

### `virsh dumpxml returned empty output`
The VM domain name couldn't be matched on the host. This can happen if the `externalId` in Morpheus doesn't match the actual libvirt domain name. Check by running on the VME host:
```bash
sudo virsh list --all
```
and compare the domain name to what Morpheus shows.

---

## Notes

- Both tasks edit the **inactive** XML config (`virsh dumpxml --inactive`). This means the VM does not need to be shut down, and a running VM is not affected until it is restarted.
- The enable task accepts a timeout between **1000 ms (1 second)** and **30000 ms (30 seconds)**. Values outside this range are clamped automatically.
- If `<bootmenu>` is already present in the XML, it is replaced in-place. If it is absent, it is inserted before the closing `</os>` tag.
- These tasks have been tested on **HPE VM Essentials 8.0.x** with **Morpheus** as the automation layer. The underlying mechanism (`virsh define`) is standard libvirt and should work on any KVM host that Morpheus manages.

---

## File Structure

```
vme-bootmenu/
├── README.md
└── tasks/
    ├── task-bootmenu-enable.py    # Morpheus task: enable boot menu
    └── task-bootmenu-disable.py   # Morpheus task: disable boot menu
```
