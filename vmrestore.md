# vmrestore — VM Restore Guide

> **100% vibe coded. Could be 100% wrong.**
>
> Appropriate testing in any and all environments is required. Build your own confidence that the restores work.
>
> Backups are only as good as your restores. All backups are worthless if you cannot recover from them.

vmbackup and vmrestore are two halves of one system. vmbackup backs up — vmrestore restores. They share no code, no modules, and have no runtime coupling, but vmrestore exclusively restores backups created by vmbackup. It is standalone in implementation but purpose-built for vmbackup's output.

**vmrestore** is a single-command restore tool for libvirt/KVM virtual machines. It wraps `virtnbdrestore` to provide:

- Disaster recovery and clone restore modes with full identity management
- Point-in-time recovery from any checkpoint in a backup chain
- Automatic detection of backup type, period, restore points, and chain layout
- TPM state and BitLocker key restoration for Windows VMs
- UEFI/NVRAM restore with clone-mode isolation
- Pre-flight safety checks (disk collision detection, free space verification)
- Archived chain recovery for any rotation policy (daily, weekly, monthly, accumulate)
- Dry-run mode to preview every restore before executing

> **Version:** vmrestore.sh v0.4
> **Underlying tools:** virtnbdrestore v2.28, virtnbdmap v2.28

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Installation](#2-installation)
3. [How vmrestore Fits the vmbackup Ecosystem](#3-how-vmrestore-fits-the-vmbackup-ecosystem)
4. [Understanding Your Backups](#4-understanding-your-backups)
    - [4.1 Rotation Policies](#41-rotation-policies)
    - [4.2 On-Disk Backup Structure](#42-on-disk-backup-structure)
    - [4.3 Backup Types and File Naming](#43-backup-types-and-file-naming)
    - [4.4 Chains and Checkpoints](#44-chains-and-checkpoints)
5. [What vmrestore Detects Automatically](#5-what-vmrestore-detects-automatically)
6. [Restore Types — DR and Clone](#6-restore-types--dr-and-clone)
7. [Pre-Restore Checklist](#7-pre-restore-checklist)
8. [Restore Scenarios](#8-restore-scenarios)
    - [8.1 Listing Available Backups](#81-listing-available-backups)
    - [8.2 Listing Restore Points](#82-listing-restore-points)
    - [8.3 Disaster Recovery Restore (DR)](#83-disaster-recovery-restore-dr)
    - [8.4 Point-in-Time Restore (Specific Date or Checkpoint)](#84-point-in-time-restore-specific-date-or-checkpoint)
    - [8.5 Path-Aware `--vm` (Direct Backup Path)](#85-path-aware---vm-direct-backup-path)
    - [8.6 Restore from an Archived Chain](#86-restore-from-an-archived-chain)
    - [8.7 Clone Restore (`--name`)](#87-clone-restore---name)
    - [8.8 Accumulate Policy Restore](#88-accumulate-policy-restore)
    - [8.9 Overwriting an Existing VM (`--force`)](#89-overwriting-an-existing-vm---force)
    - [8.10 Restore a Single Disk](#810-restore-a-single-disk)
    - [8.11 Disk-Only Restore (No VM Definition)](#811-disk-only-restore-no-vm-definition)
    - [8.12 Dry Run](#812-dry-run)
    - [8.13 Verify and Dump](#813-verify-and-dump)
    - [8.14 Host Configuration Restore](#814-host-configuration-restore)
9. [Restore Walkthroughs by Policy](#9-restore-walkthroughs-by-policy)
    - [9.1 Weekly Rotation Policy](#91-weekly-rotation-policy)
    - [9.2 Daily Rotation Policy](#92-daily-rotation-policy)
    - [9.3 Monthly Rotation Policy](#93-monthly-rotation-policy)
    - [9.4 Accumulate Policy](#94-accumulate-policy)
10. [TPM and BitLocker Restore](#10-tpm-and-bitlocker-restore)
11. [UEFI/OVMF Firmware and NVRAM Restore](#11-uefiovmf-firmware-and-nvram-restore)
12. [Single File Restore (virtnbdmap)](#12-single-file-restore-virtnbdmap)
13. [Instant Boot from Backup](#13-instant-boot-from-backup)
14. [Verifying Backups Before Restore](#14-verifying-backups-before-restore)
15. [Post-Restore Steps](#15-post-restore-steps)
16. [Troubleshooting](#16-troubleshooting)
17. [Quick Reference Commands](#17-quick-reference-commands)

---

## 1. Quick Start

```bash
# What VMs have backups?
sudo vmrestore --list

# What restore points are available for a VM?
sudo vmrestore --list-restore-points my-vm

# Preview a restore (no changes made)
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --dry-run

# Disaster recovery — rebuild the VM with original identity
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images

# Clone — create an independent copy with new identity
sudo vmrestore --vm my-vm --name test-clone --restore-path /var/lib/libvirt/images

# Restore a specific point in time
sudo vmrestore --vm my-vm --period 2026-W10 --restore-point 3 \
  --restore-path /var/lib/libvirt/images
```

`--restore-path` is always required. vmrestore never guesses where to write disk images.

---
## 2. Installation

vmrestore.sh is packaged as a Debian `.deb` package and can also be deployed manually as a standalone script.

### Prerequisites

| Package | Version | Purpose |
|---------|---------|---------|
| `virtnbdbackup` | ≥ 2.28 | Provides `virtnbdrestore` (disk restore engine) and `virtnbdmap` (single-file recovery) |
| `libvirt-daemon-system` | — | `virsh` domain management |
| `qemu-utils` | — | `qemu-img` for post-restore disk integrity checks |
| `coreutils` | — | `numfmt`, `stat`, `df` for pre-flight space checks |
| `bash` | ≥ 5.0 | Required for associative arrays and `${PIPESTATUS}` |

**Optional (for single-file recovery only):**

| Package | Purpose |
|---------|---------|
| `nbdkit` | Required for `virtnbdmap` single-file recovery |
| `nbd-client` | Required for `virtnbdmap` (kernel `nbd` module) |

### vmbackup Dependency

vmrestore.sh depends on **vmbackup.sh** being installed and configured on the same host (or having access to vmbackup's backup storage). Specifically, vmrestore reads:

- **vmbackup's configuration** — to resolve the backup path (`BACKUP_PATH`) from vmbackup.conf
- **vmbackup's on-disk backup structure** — the directory layout, `.data` files, config XMLs, TPM state, and NVRAM files that vmbackup.sh creates

vmrestore does **not** source any vmbackup modules, does not write to vmbackup's database, and has no runtime coupling to vmbackup.sh itself. It is a self-contained script that understands vmbackup's output format.

### From GitHub Release (.deb) — Recommended

```bash
wget https://github.com/doutsis/vmrestore/releases/download/v0.4/vmrestore_0.4_all.deb
sudo dpkg -i vmrestore_0.4_all.deb
```

### From Source (any distro)

```bash
git clone https://github.com/doutsis/vmrestore.git
cd vmrestore
sudo make install
```

### From Source (.deb)

```bash
git clone https://github.com/doutsis/vmrestore.git
cd vmrestore
make package
sudo dpkg -i build/vmrestore_0.4_all.deb
```

### Uninstall

**Debian / Ubuntu (.deb install):**

```bash
sudo apt remove vmrestore    # remove but keep logs
sudo apt purge vmrestore     # remove everything
```

**From source (make install):**

```bash
sudo make uninstall
```

### What the .deb Package Does

- Installs `vmrestore.sh` and `vmrestore.md` to `/opt/vmrestore/`
- Creates a symlink at `/usr/local/bin/vmrestore`
- Sets ownership to `root:libvirt` with `750` permissions
- Creates log directory at `/var/log/vmrestore/`

### Manual Installation

```bash
# Download the script
sudo mkdir -p /opt/vmrestore
sudo curl -fSL https://raw.githubusercontent.com/doutsis/vmrestore/main/vmrestore.sh \
     -o /opt/vmrestore/vmrestore.sh

# Set permissions
sudo chown -R root:libvirt /opt/vmrestore
sudo chmod 750 /opt/vmrestore
sudo chmod 750 /opt/vmrestore/vmrestore.sh

# Create symlink
sudo ln -sf /opt/vmrestore/vmrestore.sh /usr/local/bin/vmrestore

# Create log directory
sudo mkdir -p /var/log/vmrestore
sudo chown root:libvirt /var/log/vmrestore
sudo chmod 750 /var/log/vmrestore
```

### User & Group

vmrestore runs as **root** (it needs `virsh define`, `virsh undefine`, and write access to libvirt image paths). Non-root users who need to browse backups or check VM status should be in the appropriate groups:

| Group | Purpose | Command |
|-------|---------|---------|
| `libvirt` | Read access to libvirt (VM listing, status) | `sudo usermod -aG libvirt <username>` |
| `backup` | Read access to backup data under `BACKUP_PATH` | `sudo usermod -aG backup <username>` |

### Backup Path Resolution

vmrestore.sh resolves the backup root using a two-step cascade:

| Priority | Source | Example |
|----------|--------|---------|
| 1 | `--backup-path` CLI argument | `--backup-path /mnt/raid/backups/vm` |
| 2 | `BACKUP_PATH=` in `/opt/vmbackup/config/default/vmbackup.conf` | Standard vmbackup install location |

If neither provides a value, vmrestore exits with an error directing you to use `--backup-path` or configure vmbackup.

If vmbackup.sh is already installed and configured, vmrestore.sh will automatically pick up its configuration — no additional setup is needed.

### Verify Installation

```bash
# Check dependencies
which virtnbdrestore virsh qemu-img

# List available backups (confirms vmrestore + backup path are working)
sudo vmrestore --list
```

---
## 3. How vmrestore Fits the vmbackup Ecosystem

vmbackup and vmrestore are two halves of one system. vmbackup backs up — vmrestore restores. They share no code, no modules, and have no runtime coupling, but vmrestore exclusively restores backups created by vmbackup. It is standalone in implementation but purpose-built for vmbackup's output.

| Component | Role | How It Connects |
|-----------|------|-----------------------|
| **vmbackup.sh** | Backup engine — scheduling, rotation, retention, replication | Orchestrates `virtnbdbackup` to create on-disk backup sets |
| **virtnbdbackup** | Disk backup engine used by vmbackup.sh | Orchestrated by vmbackup.sh |
| **vmrestore.sh** | Restore engine — identity management, TPM/NVRAM, pre-flight checks | Orchestrates `virtnbdrestore` to reconstruct VMs from vmbackup's output |
| **virtnbdrestore** | Disk restore engine used by vmrestore.sh | Orchestrated by vmrestore.sh |
| **virtnbdmap** | NBD-based backup mounting for single-file recovery | Standalone — not orchestrated by vmbackup or vmrestore |

### What vmbackup Does

vmbackup.sh is the **backup engine**. It handles everything before a restore is ever needed:

- Scheduling and running backups (via systemd timer or cron)
- Choosing full vs incremental based on rotation policy
- Managing chain lifecycle — archiving old chains, starting new ones
- Capturing TPM state, NVRAM, VM configuration, and checksums
- Writing to the SQLite tracking database and sending email reports
- Retention and cleanup of expired backup sets
- Cloud replication (SharePoint, etc.)

### What vmrestore Does

vmrestore.sh is the **restore engine**. It reads what vmbackup created and reconstructs the VM:

- Locating and validating backup data on disk
- Auto-detecting backup type, period, restore points, and chain layout
- Orchestrating virtnbdrestore with the correct flags for DR or clone mode
- Restoring TPM state and NVRAM with proper ownership and isolation
- Pre-flight safety checks (disk collision detection, free space verification)
- Defining the restored VM in libvirt and refreshing storage pools

### What vmrestore Does NOT Do

vmrestore has a clear boundary. It does not:

- **Create backups** — that's vmbackup.sh
- **Schedule anything** — no timers, no cron, no recurring jobs
- **Manage retention or cleanup** — it never deletes backup data
- **Write to vmbackup's database** — restores are not tracked in SQLite
- **Share code with vmbackup** — it does not source vmbackup.sh modules and has no runtime dependency on vmbackup.sh being present

vmrestore is read-only with respect to your backup storage. It reads vmbackup's on-disk structure and configuration, but never modifies them.

---
## 4. Understanding Your Backups

Before restoring, it helps to understand what vmbackup created. This section covers the backup structure, file naming, and chain mechanics that vmrestore works with.

### 4.1 Rotation Policies

vmbackup.sh uses `virtnbdbackup` in **hybrid** mode to create online, thin-provisioned backups via libvirt's changed block tracking (dirty bitmaps). Each VM gets its own directory tree under the backup root.

#### Policies

| Policy     | Period ID Format | Full Backup Trigger       | Incrementals           | Example Path                |
|------------|-----------------|--------------------------|------------------------|-----------------------------|
| Daily      | `YYYYMMDD`      | Every day (new period)    | None (full each day)   | `web-server/20260222/`  |
| Weekly     | `YYYY-Www`      | Start of ISO week         | Rest of the week       | `my-vm/2026-W09/`      |
| Monthly    | `YYYYMM`        | 1st of month or new chain | Rest of the month      | `file-server/202602/`   |
| Accumulate | (none)          | First run only            | All subsequent backups  | `appliance/` (flat, no subdirs) |

#### How vmbackup.sh Decides Backup Type

1. **Day 1 of period** (or empty target dir): `virtnbdbackup -l full` — creates a full baseline and checkpoint `virtnbdbackup.0`
2. **Subsequent days in period**: `virtnbdbackup -l auto` — virtnbdbackup detects the existing full backup and automatically creates an incremental, adding checkpoint `virtnbdbackup.N`
3. **Chain break** (backup chain corruption, policy change): Archives old chain to `.archives/`, starts fresh full backup

#### Key Concept: Everything Needed for Restore Lives in One Directory

Each period directory (e.g., `202602/` or `20260222/`) — or the VM root for accumulate policy — is a self-contained backup set containing:
- Full backup data file(s): `*.full.data` or `*.copy.data`
- Incremental data files: `*.inc.virtnbdbackup.N.data`
- Checkpoint XMLs: `checkpoints/virtnbdbackup.N.xml`
- VM configuration: `vmconfig.virtnbdbackup.N.xml`
- UEFI firmware (if applicable): `OVMF_CODE_4M.ms.fd.virtnbdbackup.N`, `*_VARS.fd.virtnbdbackup.N`
- TPM state (if applicable): `tpm-state/tpm2/`
- BitLocker recovery keys (if applicable): `tpm-state/bitlocker-recovery-keys.txt`
- Checksum files: `*.data.chksum`

---

### 4.2 On-Disk Backup Structure

#### Backup Root Layout

```
/mnt/backups/vm/                 # BACKUP_PATH from vmbackup.conf
├── __HOST_CONFIG__/             # Host-level /etc/libvirt configuration
├── _state/                      # vmbackup.sh state (DB, logs)
│   ├── vmbackup.db              # SQLite tracking database
│   └── logs/                    # Per-backup log files
├── my-vm/                   # VM: my-vm (weekly policy)
│   ├── chain-manifest.json      # Full chain history for this VM
│   └── 2026-W09/                # Weekly period directory
│       ├── vda.full.data                    # FULL baseline
│       ├── vda.full.data.chksum             # Checksum (adler32)
│       ├── vda.inc.virtnbdbackup.1.data     # Incremental #1
│       ├── vda.inc.virtnbdbackup.1.data.chksum
│       ├── vda.inc.virtnbdbackup.2.data     # Incremental #2
│       ├── vda.inc.virtnbdbackup.2.data.chksum
│       ├── vda.virtnbdbackup.0.qcow.json   # QCOW metadata per checkpoint
│       ├── vda.virtnbdbackup.1.qcow.json
│       ├── vda.virtnbdbackup.2.qcow.json
│       ├── vmconfig.virtnbdbackup.0.xml     # VM config at checkpoint 0
│       ├── vmconfig.virtnbdbackup.1.xml     # VM config at checkpoint 1
│       ├── vmconfig.virtnbdbackup.2.xml     # VM config at checkpoint 2
│       ├── my-vm.cpt                    # Checkpoint list
│       ├── checkpoints/                     # Libvirt checkpoint XMLs
│       │   ├── virtnbdbackup.0.xml
│       │   ├── virtnbdbackup.1.xml
│       │   └── virtnbdbackup.2.xml
│       ├── config/                          # vmbackup.sh saved VM configs
│       │   ├── my-vm_config_202602_FIRST.xml
│       │   └── my-vm_config_20260220_023045.xml
│       ├── .archives/                       # Old chains (archived by vmbackup.sh)
│       │   └── chain-2026-02-20/            # Previous chain data files
│       ├── .full-backup-month               # Month marker
│       └── .agent-status                    # QEMU agent status (yes/no)
├── web-server/              # VM: web-server (daily policy, UEFI+TPM)
│   ├── chain-manifest.json
│   ├── 20260221/                # Daily FULL backup
│   │   ├── sda.full.data
│   │   ├── OVMF_CODE_4M.ms.fd.virtnbdbackup.0
│   │   ├── web-server_VARS.fd.virtnbdbackup.0
│   │   ├── tpm-state/
│   │   │   ├── tpm2/                       # TPM state directory
│   │   │   ├── BACKUP_METADATA.txt         # VM UUID for TPM mapping
│   │   │   └── bitlocker-recovery-keys.txt # BitLocker keys (if applicable)
│   │   └── ...
│   └── 20260222/                # Daily FULL backup (latest)
│       └── ...
├── file-server/                # VM: file-server (monthly policy, multi-disk)
│   └── 202602/
│       ├── vda.full.data                    # System disk
│       ├── vdb.full.data                    # Data disk
│       └── ...
└── appliance/                  # VM: appliance (accumulate policy)
    ├── vda.full.data                        # First-ever FULL (no period subdir)
    ├── vda.inc.virtnbdbackup.1.data         # Incremental #1
    └── ...
```

#### Disk Names

vmbackup.sh uses the **libvirt device target names** (vda, vdb, sda, sdb, etc.) as found in the VM's XML configuration. These are determined by the VM's virtual hardware:

| Bus Type | Naming | Example |
|----------|--------|---------|
| VirtIO | `vda`, `vdb`, ... | Most Linux VMs |
| SATA/IDE | `sda`, `sdb`, ... | Windows VMs, UEFI VMs with SATA controllers |
| SCSI | `sda`, `sdb`, ... | VMs with VirtIO SCSI controller |

---

### 4.3 Backup Types and File Naming

| Type | File Pattern | Created When |
|------|-------------|-------------|
| **Full** | `{device}.full.data` | First backup of a period, or chain start |
| **Incremental** | `{device}.inc.virtnbdbackup.{N}.data` | Subsequent backups within a period |
| **Copy** | `{device}.copy.data` | Offline/cold backup (VM was shut off) |

Each `.data` file has a corresponding `.data.chksum` file containing an adler32 checksum (integer).

---

### 4.4 Chains and Checkpoints

#### What is a Chain?

A chain is the complete set of backup files needed to reconstruct a VM's disk to a given point in time. It starts with one full backup and may include zero or more incrementals:

```
Chain start:  vda.full.data                   ← Checkpoint 0 (cp0) — FULL baseline
              vda.inc.virtnbdbackup.1.data    ← Checkpoint 1 (cp1) — changes since cp0
              vda.inc.virtnbdbackup.2.data    ← Checkpoint 2 (cp2) — changes since cp1
```

**Restoring to cp2** requires: full + inc.1 + inc.2 (all applied in sequence)
**Restoring to cp0** requires: full only

#### When Does a Chain Break?

vmbackup.sh archives the current chain and starts fresh when:
- Backup chain corruption is detected
- Backup policy changes (e.g., monthly → daily)
- Manual chain break

Archived chains are moved to `.archives/chain-YYYY-MM-DD[.N]/` within the period directory. They remain fully restorable via vmrestore.sh.

---

## 5. What vmrestore Detects Automatically

vmrestore auto-detects nearly everything it needs from the backup structure. The only required arguments for a basic restore are `--vm` and `--restore-path`. Everything else is resolved automatically.

| What | How | Override |
|------|-----|----------|
| **Backup path** | Reads `BACKUP_PATH` from vmbackup's config (`/opt/vmbackup/config/default/vmbackup.conf`) | `--backup-path` |
| **VM location** | `--vm my-vm` looks for `{BACKUP_PATH}/my-vm/`. Alternatively, `--vm /full/path/to/backups/my-vm` uses the path directly. | — |
| **Backup type** | Scans for `*.inc.*.data` (incremental), `*.full.data` (full), or `*.copy.data` (copy) | — |
| **Accumulate vs periodic** | If data files exist at the VM root (no period subdirectories), accumulate layout is assumed | — |
| **Period** | Picks the newest period subdirectory automatically | `--period` |
| **Restore point** | Defaults to `latest` (all incrementals applied). `full` restores the base only. A number `N` restores up to checkpoint N. | `--restore-point` |
| **TPM state** | Detects `.tpm-backup-marker` and `tpm-state/tpm2/` directory | `--skip-tpm` |
| **NVRAM** | virtnbdrestore handles `*_VARS.fd.*` files automatically. Clone mode copies NVRAM to a new filename. | — |
| **VM config XML** | Searches `vmconfig.virtnbdbackup.*.xml`, then `config/*.xml`, then parent directory | — |
| **Storage pool** | After restore, detects the containing libvirt storage pool and runs `virsh pool-refresh` | — |

---
## 6. Restore Types — DR and Clone

Every vmrestore command is either a **DR restore** or a **clone restore**. The difference is one flag: `--name`. If you pass `--name`, it's a clone. If you don't, it's a DR restore. This decision controls how vmrestore handles the VM's identity, disk files, and libvirt definition.

### Disaster Recovery (DR) Restore

A DR restore rebuilds a VM with its **original identity** — same name, same UUID, same MAC addresses. The restored VM is a direct replacement for the original.

```bash
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images
```

**When to use:** The original VM is lost, corrupted, or needs to be rolled back to a known-good state. You want the restored VM to be indistinguishable from the original.

**What vmrestore does:**
- Restores disk images to `--restore-path` with their original filenames
- Defines the VM in libvirt with the same name, UUID, and MAC addresses from the backup
- Restores NVRAM to its original path
- Restores TPM state to the original UUID path (BitLocker unlocks automatically)

#### When `--force` Is Required

If the VM name is **still defined in libvirt**, vmrestore will refuse to proceed — it won't silently overwrite a defined VM. You must add `--force`:

```bash
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --force
```

`--force` does two things:
1. **Undefines the existing VM** from libvirt (equivalent to `virsh undefine` with appropriate flags)
2. **Removes existing disk files** at the restore path before writing the restored disks

If the VM is **not defined** in libvirt (e.g. you're restoring onto a fresh host, or the VM was already undefined), `--force` is not needed. vmrestore will define the VM and write the disk files without complaint.

**The decision is simple:**

| VM still defined in libvirt? | Command |
|------------------------------|---------|
| No (fresh host, already undefined) | `sudo vmrestore --vm my-vm --restore-path /path` |
| Yes (replacing in-place) | `sudo vmrestore --vm my-vm --restore-path /path --force` |

> **Important:** The VM must be **shut off** before a DR restore. vmrestore checks whether the predicted output files are in use by a running VM and blocks the restore if they are. Shut down the VM first, then restore with `--force`.

### Clone Restore

A clone restore creates a **new, independent copy** of a VM with a fresh identity. The original VM (if it exists) is completely untouched.

```bash
sudo vmrestore --vm my-vm --name test-clone --restore-path /var/lib/libvirt/images
```

**When to use:** You want to test a backup, create a dev/test copy from production, or run a restored VM alongside the original.

**What vmrestore does:**
- Restores disk images into a staging directory, then renames them with the clone name:
  - Single disk: `test-clone.qcow2`
  - Multi-disk: `test-clone-vda.qcow2`, `test-clone-vdb.qcow2`, etc.
- Defines the VM in libvirt with a **new name, new UUID, and new MAC addresses** — libvirt assigns the UUID and MACs automatically when the modified XML is defined
- Copies NVRAM to a new file (`test-clone_VARS.fd`) so the clone and original don't share firmware state
- Restores TPM state under the new UUID path (BitLocker unlocks automatically because the TPM is re-mapped)

**No `--force` needed.** Clone mode uses a staging directory during the restore, so it never touches existing files. The final renamed files are checked against live VM disks before being placed.

The clone is fully independent. You can start it, modify it, or delete it without affecting the original VM.

### Comparison Matrix

| Behaviour | DR (no `--name`) | Clone (`--name`) |
|-----------|-------------------|------------------|
| UUID | Preserved from backup | New (assigned by libvirt) |
| MAC addresses | Preserved from backup | New (assigned by libvirt) |
| VM name | Original name | Clone name |
| Disk filenames | Original names | `{clone}.qcow2` or `{clone}-{vda,vdb,…}.qcow2` |
| NVRAM | Restored to original path | Copied to `{clone}_VARS.fd` |
| TPM state | At original UUID | At new UUID |
| `--force` needed if VM exists? | Yes | No (staging prevents conflicts) |
| Can run alongside original? | No (same identity = conflict) | Yes (completely independent) |
| BitLocker | Unlocks automatically | Unlocks automatically |

---
## 7. Pre-Restore Checklist

Before running a restore, verify:

| Check | Command |
|-------|---------|
| Backup path is accessible | `ls {BACKUP_PATH}/{vm-name}/` |
| Backup has data files | `sudo vmrestore --list-restore-points {vm-name}` |
| Backup checksums are valid | `sudo vmrestore --verify {vm-name}` |
| Target disk has enough space | `df -h {restore-path}` (vmrestore checks this automatically) |
| VM is shut off (DR mode) | `sudo virsh domstate {vm-name}` |
| virtnbdrestore is available | `which virtnbdrestore` |

---
## 8. Restore Scenarios

### 8.1 Listing Available Backups

```bash
sudo vmrestore --list
```

Shows all VMs in the backup root with their backup type, total size, restore point count, archived chain count, and TPM status.

### 8.2 Listing Restore Points

```bash
# Latest period (auto-detected)
sudo vmrestore --list-restore-points my-vm

# Specific period
sudo vmrestore --list-restore-points my-vm --period 2026-W09
```

Shows each checkpoint with its date and type (FULL base, Incremental, or COPY). Also lists any archived chains in `.archives/`.

### 8.3 Disaster Recovery Restore (DR)

Restore a VM to its latest state, preserving its original identity:

```bash
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images
```

If the VM is still defined in libvirt (e.g., disk is corrupted but definition exists):

```bash
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --force
```

The `--force` flag undefines the existing VM before restoring. The VM must be **shut off** first.

### 8.4 Point-in-Time Restore (Specific Date or Checkpoint)

Restore to a **specific period** (date):

```bash
# Daily policy — restore from March 2 backup
sudo vmrestore --vm my-vm --period 20260302 \
  --restore-path /var/lib/libvirt/images

# Weekly policy — restore from week 9
sudo vmrestore --vm my-vm --period 2026-W09 \
  --restore-path /var/lib/libvirt/images
```

Restore to a **specific checkpoint** within a period:

```bash
# Checkpoint 3 (full + incrementals 1, 2, 3)
sudo vmrestore --vm my-vm --restore-point 3 \
  --restore-path /var/lib/libvirt/images

# Full baseline only (checkpoint 0)
sudo vmrestore --vm my-vm --restore-point full \
  --restore-path /var/lib/libvirt/images
```

### 8.5 Path-Aware `--vm` (Direct Backup Path)

When `--vm` contains a `/`, vmrestore treats it as a path: `basename` becomes the VM name and `dirname` overrides the backup path. This is useful when the backup path differs from the configured default.

```bash
# Backup path derived from the --vm argument
sudo vmrestore --vm /mnt/backups/vm/my-vm \
  --period 20260302 --restore-path /tmp/restore
```

### 8.6 Restore from an Archived Chain

Archived chains can be accessed by passing the full path to the `.archives/chain-*` directory:

```bash
sudo vmrestore \
  --vm /mnt/backups/vm/my-vm/2026-W09/.archives/chain-2026-02-28.1 \
  --restore-path /tmp/restore/archived
```

vmrestore detects data files directly in the provided path and uses it as the data directory without period resolution.

### 8.7 Clone Restore (`--name`)

Create a new, independent copy with a fresh identity:

```bash
sudo vmrestore --vm my-vm \
  --name test-clone --restore-path /var/lib/libvirt/images
```

The clone gets a new UUID, new MAC addresses, independent NVRAM, and independent TPM state. See [section 6 Restore Types](#6-restore-types--dr-and-clone) for full details.

### 8.8 Accumulate Policy Restore

Accumulate VMs store data directly at the VM root (no period subdirectory). vmrestore auto-detects this — no `--period` needed:

```bash
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images
```

Point-in-time restore still works with `--restore-point`:

```bash
sudo vmrestore --vm my-vm --restore-point 3 \
  --restore-path /var/lib/libvirt/images
```

### 8.9 Overwriting an Existing VM (`--force`)

If a VM with the target name already exists in libvirt:

```bash
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --force
```

`--force` will:
1. `virsh undefine` the existing VM (tries `--nvram --checkpoints-metadata`, falls back gracefully)
2. Remove existing disk files at the restore path (DR mode only)
3. Proceed with the restore

Without `--force`, vmrestore aborts if the target VM is already defined.

### 8.10 Restore a Single Disk

For multi-disk VMs, restore only one disk:

```bash
sudo vmrestore --vm my-vm --disk vda --restore-path /tmp/restore
```

Only the `vda` data files are processed. Other disks in the backup are skipped.

### 8.11 Disk-Only Restore (No VM Definition)

Restore disk images without defining a VM in libvirt:

```bash
sudo vmrestore --vm my-vm --restore-path /tmp/restore --skip-config
```

Also skips TPM restoration (`--skip-config` implies data-only — TPM state should not be modified for a VM that isn't being redefined).

### 8.12 Dry Run

Preview what vmrestore would do without executing:

```bash
sudo vmrestore --vm my-vm --restore-path /tmp/restore --dry-run
```

Shows the virtnbdrestore command that would be run, safety check results, predicted output files, and (for clone mode) the staging and rename plan.

### 8.13 Verify and Dump

Validate backup integrity (checksum verification):

```bash
sudo vmrestore --verify my-vm --period 2026-W09
```

View backup metadata as JSON:

```bash
sudo vmrestore --dump my-vm --period 2026-W09
```

Both commands pass through to `virtnbdrestore -o verify` and `virtnbdrestore -o dump` respectively.

### 8.14 Host Configuration Restore

> **Warning — untested feature.** This is not a host backup. The `__HOST_CONFIG__` archive contains configuration for libvirt/KVM dependent components only: `/etc/libvirt`, `/var/lib/libvirt/{qemu,network,storage,secrets,dnsmasq}`, and host network configuration (`/etc/network/`, `/etc/NetworkManager/system-connections/`). If used to restore, the outcomes are unknown. Always use `--dry-run` to inspect the archive contents before attempting a restore.

Restore the host-level `/etc/libvirt` configuration from the `__HOST_CONFIG__` backup:

```bash
sudo vmrestore --host-config
```

This stops `libvirtd`, extracts the latest `__HOST_CONFIG__` tar.gz archive to `/`, and restarts `libvirtd`. Use `--dry-run` to preview first.

---
## 9. Restore Walkthroughs by Policy

These walkthroughs show what vmbackup produces on disk for each rotation policy and how to list, understand, and restore from those backups. Section 8 gives quick command recipes; this section provides the full context — directory layouts, checkpoint numbering, and day-by-day examples.

### 9.1 Weekly Rotation Policy

**Setup**: VM `my-vm`, weekly rotation policy, vmbackup runs once daily. Three weeks of backups: `2026-W10/`, `2026-W11/`, `2026-W12/`.

#### What Happens Each Day

The same pattern repeats every week. vmbackup makes one decision per day based on the VM's state when it runs:

| Day | VM State | vmbackup Action | Files Created |
|-----------|----------|---------------------------------------------|------------------------------|
| Monday | Online | New week → new period directory → **FULL** | `vda.full.data`, checkpoint 0 |
| Tuesday | Online | Chain continues → **incremental** | `vda.inc.virtnbdbackup.1.data`, checkpoint 1 |
| Wednesday | Offline | Disk changed (clean shutdown). Archive Mon/Tue chain → **COPY** | `vda.copy.data` |
| Thursday | Offline | VM was started, modified, shut down. Archive Wed copy → **COPY** | `vda.copy.data` |
| Friday | Online | Copy from Thu exists. Archive Thu copy → **FULL** (new chain) | `vda.full.data`, checkpoint 0 |
| Saturday | Online | Chain continues → **incremental** | `vda.inc.virtnbdbackup.1.data`, checkpoint 1 |
| Sunday | Online | Chain continues → **incremental** | `vda.inc.virtnbdbackup.2.data`, checkpoint 2 |

#### Resulting Directory Structure (End of Week)

```
my-vm/2026-W10/
├── .archives/
│   ├── chain-2026-03-04/               ← Mon/Tue chain (archived Wednesday)
│   │   ├── vda.full.data               ← Monday's full backup
│   │   ├── vda.inc.virtnbdbackup.1.data ← Tuesday's incremental
│   │   ├── checkpoints/
│   │   │   ├── virtnbdbackup.0.xml     ← Monday
│   │   │   └── virtnbdbackup.1.xml     ← Tuesday
│   │   └── my-vm.cpt
│   ├── chain-2026-03-05/               ← Wed copy (archived Thursday)
│   │   └── vda.copy.data               ← Wednesday's copy backup
│   └── chain-2026-03-06/               ← Thu copy (archived Friday)
│       └── vda.copy.data               ← Thursday's copy backup
│
├── vda.full.data                       ← Friday's full (current chain base)
├── vda.inc.virtnbdbackup.1.data        ← Saturday's incremental
├── vda.inc.virtnbdbackup.2.data        ← Sunday's incremental
├── checkpoints/
│   ├── virtnbdbackup.0.xml             ← Friday
│   ├── virtnbdbackup.1.xml             ← Saturday
│   └── virtnbdbackup.2.xml             ← Sunday
└── my-vm.cpt
```

Each of the three weeks (`2026-W10`, `2026-W11`, `2026-W12`) has the same structure.

#### Listing Restore Points

```bash
# Show current chain restore points for the latest week
sudo vmrestore --list-restore-points my-vm

# Show restore points for a specific week
sudo vmrestore --list-restore-points my-vm --period 2026-W10
```

Example output for `--period 2026-W10`:

```
Restore Points: my-vm
  Directory: /mnt/vm-backups/my-vm/2026-W10
  Type: incremental

  Restore Points:
  ─────────────────────────────────────────────────────────
  virtnbdbackup.0        2026-03-06 22:00:01  FULL (base)
  virtnbdbackup.1        2026-03-07 22:00:01  Incremental
  virtnbdbackup.2        2026-03-08 22:00:01  Incremental
  ─────────────────────────────────────────────────────────
  Total: 3

  Archived Chains:
    chain-2026-03-04                 1.2G  incremental
    chain-2026-03-05                 800M  copy
    chain-2026-03-06                 810M  copy
```

**Reading this output:**
- The 3 current restore points are from the Fri/Sat/Sun chain.
- Checkpoint 0 = Friday (FULL base), 1 = Saturday, 2 = Sunday.
- Three archived chains are also available for earlier days of the week.

#### Restore Examples

##### Restore to Sunday (latest — the default)

```bash
sudo vmrestore --vm my-vm --period 2026-W10 \
  --restore-path /var/lib/libvirt/images
```

No `--restore-point` needed — `latest` is the default and applies all checkpoints (0 + 1 + 2 = Sunday's state).

##### Restore to Saturday (Week 1, Day 6)

Saturday is checkpoint 1 in the current Fri/Sat/Sun chain:

```bash
sudo vmrestore --vm my-vm --period 2026-W10 \
  --restore-point 1 --restore-path /var/lib/libvirt/images
```

##### Restore to Tuesday (Week 1, Day 2)

Tuesday's data is in the Mon/Tue archived chain (`chain-2026-03-04`). First, list the checkpoints inside the archive to find the right one:

```bash
sudo vmrestore --list-restore-points \
  /mnt/vm-backups/my-vm/2026-W10/.archives/chain-2026-03-04
```

```
Restore Points: chain-2026-03-04
  Directory: /mnt/vm-backups/my-vm/2026-W10/.archives/chain-2026-03-04
  Type: incremental

  Restore Points:
  ─────────────────────────────────────────────────────────
  virtnbdbackup.0        2026-03-02 22:00:01  FULL (base)     ← Monday
  virtnbdbackup.1        2026-03-03 22:00:01  Incremental     ← Tuesday
  ─────────────────────────────────────────────────────────
  Total: 2
```

Tuesday is checkpoint 1. Restore it:

```bash
sudo vmrestore \
  --vm /mnt/vm-backups/my-vm/2026-W10/.archives/chain-2026-03-04 \
  --restore-point 1 --restore-path /var/lib/libvirt/images
```

- `--restore-point 0` or `--restore-point full` would give Monday's state.

##### Restore to Wednesday (Week 1, Day 3 — offline copy)

Wednesday's copy backup is in `chain-2026-03-05`. List it first:

```bash
sudo vmrestore --list-restore-points \
  /mnt/vm-backups/my-vm/2026-W10/.archives/chain-2026-03-05
```

```
Restore Points: chain-2026-03-05
  Directory: /mnt/vm-backups/my-vm/2026-W10/.archives/chain-2026-03-05
  Type: copy

  Restore Points:
  ─────────────────────────────────────────────────────────
  copy                   2026-03-04 22:00:01  COPY (offline)  ← Wednesday
  ─────────────────────────────────────────────────────────
  Total: 1
```

Copy backups have exactly one restore point — no `--restore-point` needed:

```bash
sudo vmrestore \
  --vm /mnt/vm-backups/my-vm/2026-W10/.archives/chain-2026-03-05 \
  --restore-path /var/lib/libvirt/images
```

##### Restore to Thursday (Week 2, Day 4)

Thursday of week 2 is a copy backup archived on Friday of W11. List the archives for W11 first:

```bash
sudo vmrestore --list-restore-points my-vm --period 2026-W11
```

The output shows the current chain's restore points and the archived chains. Find the archive for Thursday (`chain-2026-03-13`), then list its contents:

```bash
sudo vmrestore --list-restore-points \
  /mnt/vm-backups/my-vm/2026-W11/.archives/chain-2026-03-13
```

```
Restore Points: chain-2026-03-13
  Directory: /mnt/vm-backups/my-vm/2026-W11/.archives/chain-2026-03-13
  Type: copy

  Restore Points:
  ─────────────────────────────────────────────────────────
  copy                   2026-03-12 22:00:01  COPY (offline)  ← Thursday
  ─────────────────────────────────────────────────────────
  Total: 1
```

Restore it:

```bash
sudo vmrestore \
  --vm /mnt/vm-backups/my-vm/2026-W11/.archives/chain-2026-03-13 \
  --restore-path /var/lib/libvirt/images
```

##### Restore Week 2 Fully (Latest State of W11)

This restores the current chain in `2026-W11/` at its latest checkpoint (Sunday of W11):

```bash
sudo vmrestore --vm my-vm --period 2026-W11 \
  --restore-path /var/lib/libvirt/images
```

##### Restore to Saturday (Week 3, Day 6)

Saturday of W12 is checkpoint 1 in the current Fri/Sat/Sun chain:

```bash
sudo vmrestore --vm my-vm --period 2026-W12 \
  --restore-point 1 --restore-path /var/lib/libvirt/images
```

#### Additional Weekly Scenarios

##### Clone Instead of DR

Any of the above can be a clone by adding `--name`:

```bash
sudo vmrestore --vm my-vm --period 2026-W10 \
  --name my-vm-clone --restore-path /var/lib/libvirt/images-clone
```

##### Dry Run Before Restoring

Preview what vmrestore would do without executing:

```bash
sudo vmrestore --vm my-vm --period 2026-W10 \
  --restore-path /var/lib/libvirt/images --dry-run
```

##### Verify Backup Integrity Before Restoring

```bash
sudo vmrestore --verify my-vm --period 2026-W10
```

#### Multiple Backups in a Single Day

If vmbackup runs more than once on the same day (manual run or unplanned re-execution), the second run lands in the **same period directory** because the period ID (`2026-W10`) hasn't changed. Since a full backup already exists in the chain, the second run adds another incremental checkpoint. The result is one extra restore point for that day. This applies identically to all on/off patterns described above — the only difference is an additional checkpoint number in the chain.

---

### 9.2 Daily Rotation Policy

**Setup**: VM `my-vm`, daily rotation policy, vmbackup runs once daily. Seven days of backups: `20260302/` through `20260308/`.

#### Key Difference from Weekly

With daily rotation, **every day is a new period**. Each day gets its own directory. Since vmbackup runs once per day and the period changes daily, there are **no incremental chains** — each day contains exactly one independent backup (either a FULL or a COPY). There are no `.archives/` directories.

#### What Happens Each Day

| Day | VM State | vmbackup Action | Directory | Files Created |
|-----------|----------|------------------------------|--------------|--------------------------|
| Monday | Online | New period → **FULL** | `20260302/` | `vda.full.data` |
| Tuesday | Online | New period → **FULL** | `20260303/` | `vda.full.data` |
| Wednesday | Offline | New period, disk changed → **COPY** | `20260304/` | `vda.copy.data` |
| Thursday | Offline | New period, disk changed → **COPY** | `20260305/` | `vda.copy.data` |
| Friday | Online | New period → **FULL** | `20260306/` | `vda.full.data` |
| Saturday | Online | New period → **FULL** | `20260307/` | `vda.full.data` |
| Sunday | Online | New period → **FULL** | `20260308/` | `vda.full.data` |

#### Resulting Directory Structure

```
my-vm/
├── 20260302/                  ← Monday
│   └── vda.full.data
├── 20260303/                  ← Tuesday
│   └── vda.full.data
├── 20260304/                  ← Wednesday (offline)
│   └── vda.copy.data
├── 20260305/                  ← Thursday (offline)
│   └── vda.copy.data
├── 20260306/                  ← Friday
│   └── vda.full.data
├── 20260307/                  ← Saturday
│   └── vda.full.data
└── 20260308/                  ← Sunday
    └── vda.full.data
```

Each directory is independent. No chains, no archives, no checkpoint numbering.

#### Listing Restore Points

```bash
# List all VMs and their backup info
sudo vmrestore --list

# Show restore points for a specific day
sudo vmrestore --list-restore-points my-vm --period 20260303
```

Output for `--period 20260303`:

```
Restore Points: my-vm
  Directory: /mnt/vm-backups/my-vm/20260303
  Type: full

  Restore Points:
  ─────────────────────────────────────────────────────────
  virtnbdbackup.0        2026-03-03 22:00:01  FULL (only)
  ─────────────────────────────────────────────────────────
  Total: 1
```

One restore point. No archives.

#### Restore Examples

##### Restore Tuesday

```bash
sudo vmrestore --vm my-vm --period 20260303 \
  --restore-path /var/lib/libvirt/images
```

No `--restore-point` needed — there's only one backup per day.

##### Restore Wednesday (Offline Copy)

```bash
sudo vmrestore --vm my-vm --period 20260304 \
  --restore-path /var/lib/libvirt/images
```

Works identically — vmrestore auto-detects the copy backup type.

##### Restore the Latest Day

```bash
sudo vmrestore --vm my-vm \
  --restore-path /var/lib/libvirt/images
```

No `--period` needed — vmrestore picks the newest period automatically.

#### When Daily Makes Sense

- VMs where every day's state must be independently recoverable.
- Higher storage cost (every backup is a full/copy — no incremental savings).
- Simplest restore workflow: pick a date, restore.

#### Multiple Backups in a Single Day

If vmbackup runs a second time on the same day, it goes into the **same period directory** (e.g. `20260303/`). A full backup already exists, so the second run adds an incremental to it, creating a two-point chain. That day's directory then has `virtnbdbackup.0` (the original full) and `virtnbdbackup.1` (the second run). Use `--restore-point 0` for the first backup or omit it for the latest.

---

### 9.3 Monthly Rotation Policy

**Setup**: VM `my-vm`, monthly rotation policy, vmbackup runs once daily.
One month shown: `202603/`.

#### Key Difference from Weekly

Monthly rotation keeps everything in one period directory for the entire month. Chains can grow long (up to 30 checkpoints). On/off cycles create archived chains within the month, just like the weekly scenario but spanning more days.

#### What Happens (March 2026, Summarised)

| Days | VM State | vmbackup Action | Result |
|-------------|----------|------------------------------------------------|------------------------------|
| Mar 1 | Online | New month → new period → **FULL** | Starts new chain, checkpoint 0 |
| Mar 2–5 | Online | Chain continues → **incremental** each day | Checkpoints 1, 2, 3, 4 |
| Mar 6 | Offline | Disk changed. Archive chain (0–4) → **COPY** | Copy backup in period dir |
| Mar 7 | Offline | VM started, modified, shut down. Archive copy → **COPY** | New copy backup |
| Mar 8–14 | Online | Archive copy → **FULL**, then incrementals | New chain, checkpoints 0–6 |
| Mar 15 | Offline | Disk changed. Archive chain (0–6) → **COPY** | Copy backup |
| Mar 16–31 | Online | Archive copy → **FULL**, then incrementals | New chain, checkpoints 0–15 |

#### Resulting Directory Structure (End of March)

```
my-vm/202603/
├── .archives/
│   ├── chain-2026-03-06/               ← Mar 1–5 chain (5 points: full + 4 inc)
│   │   ├── vda.full.data
│   │   ├── vda.inc.virtnbdbackup.1.data
│   │   ├── vda.inc.virtnbdbackup.2.data
│   │   ├── vda.inc.virtnbdbackup.3.data
│   │   ├── vda.inc.virtnbdbackup.4.data
│   │   ├── checkpoints/
│   │   │   ├── virtnbdbackup.0.xml     ← Mar 1
│   │   │   ├── virtnbdbackup.1.xml     ← Mar 2
│   │   │   ├── virtnbdbackup.2.xml     ← Mar 3
│   │   │   ├── virtnbdbackup.3.xml     ← Mar 4
│   │   │   └── virtnbdbackup.4.xml     ← Mar 5
│   │   └── my-vm.cpt
│   ├── chain-2026-03-07/               ← Mar 6 copy (archived Mar 7)
│   │   └── vda.copy.data
│   ├── chain-2026-03-08/               ← Mar 7 copy (archived Mar 8)
│   │   └── vda.copy.data
│   ├── chain-2026-03-15/               ← Mar 8–14 chain (7 points)
│   │   ├── vda.full.data
│   │   ├── vda.inc.virtnbdbackup.{1..6}.data
│   │   ├── checkpoints/
│   │   └── my-vm.cpt
│   ├── chain-2026-03-16/               ← Mar 15 copy (archived Mar 16)
│   │   └── vda.copy.data
│
├── vda.full.data                       ← Mar 16 full (current chain base)
├── vda.inc.virtnbdbackup.1.data        ← Mar 17
├── vda.inc.virtnbdbackup.2.data        ← Mar 18
│   ... (continues through Mar 31)
├── vda.inc.virtnbdbackup.15.data       ← Mar 31
├── checkpoints/
│   ├── virtnbdbackup.0.xml             ← Mar 16
│   ├── virtnbdbackup.1.xml             ← Mar 17
│   │   ...
│   └── virtnbdbackup.15.xml            ← Mar 31
└── my-vm.cpt
```

#### Listing Restore Points

```bash
# Current month (auto-detected as latest period)
sudo vmrestore --list-restore-points my-vm

# Specific month
sudo vmrestore --list-restore-points my-vm --period 202603
```

Output shows 16 restore points in the current chain (Mar 16–31) plus 5 archived chains from earlier in the month.

#### Restore Examples

##### Restore to March 31 (Latest)

```bash
sudo vmrestore --vm my-vm --period 202603 \
  --restore-path /var/lib/libvirt/images
```

##### Restore to March 20

March 20 is checkpoint 4 in the current chain (Mar 16 = 0, Mar 17 = 1, ..., Mar 20 = 4):

```bash
sudo vmrestore --vm my-vm --period 202603 \
  --restore-point 4 --restore-path /var/lib/libvirt/images
```

##### Restore to March 3

March 3 is in the first archived chain. List the archive's checkpoints:

```bash
sudo vmrestore --list-restore-points \
  /mnt/vm-backups/my-vm/202603/.archives/chain-2026-03-06
```

```
Restore Points: chain-2026-03-06
  Directory: /mnt/vm-backups/my-vm/202603/.archives/chain-2026-03-06
  Type: incremental

  Restore Points:
  ─────────────────────────────────────────────────────────
  virtnbdbackup.0        2026-03-01 22:00:01  FULL (base)     ← Mar 1
  virtnbdbackup.1        2026-03-02 22:00:01  Incremental     ← Mar 2
  virtnbdbackup.2        2026-03-03 22:00:01  Incremental     ← Mar 3
  virtnbdbackup.3        2026-03-04 22:00:01  Incremental     ← Mar 4
  virtnbdbackup.4        2026-03-05 22:00:01  Incremental     ← Mar 5
  ─────────────────────────────────────────────────────────
  Total: 5
```

March 3 is checkpoint 2. Restore it:

```bash
sudo vmrestore \
  --vm /mnt/vm-backups/my-vm/202603/.archives/chain-2026-03-06 \
  --restore-point 2 --restore-path /var/lib/libvirt/images
```

##### Restore to March 6 (Offline Copy Day)

List the archive's contents:

```bash
sudo vmrestore --list-restore-points \
  /mnt/vm-backups/my-vm/202603/.archives/chain-2026-03-07
```

```
Restore Points: chain-2026-03-07
  Directory: /mnt/vm-backups/my-vm/202603/.archives/chain-2026-03-07
  Type: copy

  Restore Points:
  ─────────────────────────────────────────────────────────
  copy                   2026-03-06 22:00:01  COPY (offline)  ← Mar 6
  ─────────────────────────────────────────────────────────
  Total: 1
```

One restore point. Restore it:

```bash
sudo vmrestore \
  --vm /mnt/vm-backups/my-vm/202603/.archives/chain-2026-03-07 \
  --restore-path /var/lib/libvirt/images
```

#### When Monthly Makes Sense

- VMs where storage efficiency matters — long incremental chains mean only changed blocks are stored each day.
- Fewer period directories to manage.
- Trade-off: longer chains mean restoring older points takes longer (more incrementals to apply).

#### Multiple Backups in a Single Day

If vmbackup runs more than once on the same day, the second run adds another incremental checkpoint to the current chain within the same `YYYYMM/` directory. The effect is one extra restore point. All checkpoint numbering and restore point selection works identically — the additional checkpoint simply extends the chain.

---

### 9.4 Accumulate Policy

**Setup**: VM `my-vm`, accumulate rotation policy, vmbackup runs once daily.

#### Key Difference from All Other Policies

There are **no period directories at all**. All backup data lives directly in the VM's top-level folder. The chain grows continuously with no automatic rotation. vmrestore auto-detects this layout — no `--period` flag is needed or accepted.

Archives still happen when on/off cycles break the chain, stored in `.archives/` at the VM root.

#### What Happens Over 2 Weeks (Summarised)

| Days | VM State | vmbackup Action | Result |
|-------------|----------|------------------------------------------------|-----------------------------|
| Day 1 | Online | First backup → **FULL** | Chain starts, checkpoint 0 |
| Day 2–5 | Online | Chain continues → **incremental** each day | Checkpoints 1–4 |
| Day 6 | Offline | Disk changed. Archive chain (0–4) → **COPY** | Copy backup at VM root |
| Day 7 | Online | Archive copy → **FULL** (new chain) | New chain, checkpoint 0 |
| Day 8–14 | Online | Chain continues → **incremental** each day | Checkpoints 1–7 |

#### Resulting Directory Structure (End of Day 14)

```
my-vm/
├── .archives/
│   ├── chain-2026-03-06/               ← Day 1–5 chain (archived Day 6)
│   │   ├── vda.full.data
│   │   ├── vda.inc.virtnbdbackup.{1..4}.data
│   │   ├── checkpoints/
│   │   └── my-vm.cpt
│   └── chain-2026-03-07/               ← Day 6 copy (archived Day 7)
│       └── vda.copy.data
│
├── vda.full.data                       ← Day 7 full (current chain base)
├── vda.inc.virtnbdbackup.1.data        ← Day 8
├── vda.inc.virtnbdbackup.2.data        ← Day 9
│   ...
├── vda.inc.virtnbdbackup.7.data        ← Day 14
├── checkpoints/
│   ├── virtnbdbackup.0.xml             ← Day 7
│   ├── virtnbdbackup.1.xml             ← Day 8
│   │   ...
│   └── virtnbdbackup.7.xml             ← Day 14
└── my-vm.cpt
```

Note: no period subdirectories. Everything is at the VM root.

#### Listing Restore Points

```bash
# No --period needed or expected
sudo vmrestore --list-restore-points my-vm
```

Output shows 8 restore points in the current chain (Day 7–14) plus 2 archived chains.

#### Restore Examples

##### Restore to Latest

```bash
sudo vmrestore --vm my-vm \
  --restore-path /var/lib/libvirt/images
```

No `--period`, no `--restore-point`.

##### Restore to Day 10

Day 10 is checkpoint 3 in the current chain (Day 7 = 0, Day 8 = 1, Day 9 = 2, Day 10 = 3):

```bash
sudo vmrestore --vm my-vm \
  --restore-point 3 --restore-path /var/lib/libvirt/images
```

##### Restore to Day 3 (Archived Chain)

List the archive's checkpoints:

```bash
sudo vmrestore --list-restore-points \
  /mnt/vm-backups/my-vm/.archives/chain-2026-03-06
```

```
Restore Points: chain-2026-03-06
  Directory: /mnt/vm-backups/my-vm/.archives/chain-2026-03-06
  Type: incremental

  Restore Points:
  ─────────────────────────────────────────────────────────
  virtnbdbackup.0        2026-03-01 22:00:01  FULL (base)     ← Day 1
  virtnbdbackup.1        2026-03-02 22:00:01  Incremental     ← Day 2
  virtnbdbackup.2        2026-03-03 22:00:01  Incremental     ← Day 3
  virtnbdbackup.3        2026-03-04 22:00:01  Incremental     ← Day 4
  virtnbdbackup.4        2026-03-05 22:00:01  Incremental     ← Day 5
  ─────────────────────────────────────────────────────────
  Total: 5
```

Day 3 is checkpoint 2. Restore it:

```bash
sudo vmrestore \
  --vm /mnt/vm-backups/my-vm/.archives/chain-2026-03-06 \
  --restore-point 2 --restore-path /var/lib/libvirt/images
```

##### Restore to Day 6 (Offline Copy)

List the archive:

```bash
sudo vmrestore --list-restore-points \
  /mnt/vm-backups/my-vm/.archives/chain-2026-03-07
```

```
Restore Points: chain-2026-03-07
  Directory: /mnt/vm-backups/my-vm/.archives/chain-2026-03-07
  Type: copy

  Restore Points:
  ─────────────────────────────────────────────────────────
  copy                   2026-03-06 22:00:01  COPY (offline)  ← Day 6
  ─────────────────────────────────────────────────────────
  Total: 1
```

Restore it:

```bash
sudo vmrestore \
  --vm /mnt/vm-backups/my-vm/.archives/chain-2026-03-07 \
  --restore-path /var/lib/libvirt/images
```

#### Accumulate Safety Limits

If the chain grows past 365 checkpoints (configurable), vmbackup automatically archives the chain and starts fresh. This prevents unbounded chain growth.

#### When Accumulate Makes Sense

- Long-running appliance VMs that rarely go offline.
- VMs where period-based organisation isn't meaningful.
- Maximum storage efficiency — one chain covers the entire history.
- Trade-off: very long chains take longer to restore (hundreds of incrementals to replay).

#### Multiple Backups in a Single Day

If vmbackup runs more than once on the same day, the second run adds another incremental checkpoint to the chain at the VM root. The effect is one extra restore point. No different from any other incremental — the chain simply grows by one.

---

### Summary: Choosing a Restore Approach

| What you want | Command |
|---------------------------------------------------|---------|
| Restore to the latest state of the latest period | `sudo vmrestore --vm my-vm --restore-path /path` |
| Restore a specific period's latest state | Add `--period 2026-W10` |
| Restore a specific checkpoint within a chain | Add `--restore-point 3` |
| Restore from an archived chain | Use `--vm /full/path/to/.archives/chain-YYYY-MM-DD` |
| Clone instead of DR | Add `--name clone-name` |
| Preview without executing | Add `--dry-run` |
| Verify backup integrity first | `sudo vmrestore --verify my-vm --period 2026-W10` |

---
## 10. TPM and BitLocker Restore

vmrestore automatically restores TPM state for VMs that have TPM backups (indicated by a `.tpm-backup-marker` file created by vmbackup.sh). No manual steps are needed.

### How It Works

1. **Detection:** vmrestore checks for `.tpm-backup-marker` in the data directory
2. **UUID resolution (cascade):**
   - Clone mode: use the new UUID from `virsh define` (after `define_new_identity()`)
   - `BACKUP_METADATA.txt`: extract `VM UUID:` field from `tpm-state/BACKUP_METADATA.txt`
   - Fallback: `virsh dominfo {vm-name}` (only works if VM is already defined)
3. **Pre-backup:** If TPM state already exists at the target path, it is moved to `{path}.pre-restore-{epoch}` as a safety backup
4. **Copy:** `tpm-state/tpm2/` is copied to `/var/lib/libvirt/swtpm/{UUID}/tpm2/`
5. **Permissions:** UUID directory set to `root:root 711`, `tpm2/` subdirectory set to `tss:tss 700` (Debian/Ubuntu; dynamically detected)

### Skipping TPM Restore

```bash
sudo vmrestore --vm my-vm --restore-path /tmp/restore --skip-tpm
```

### BitLocker and TPM

- **DR restore:** Same UUID → TPM sealed data is accessible → BitLocker unlocks automatically
- **Clone restore:** New UUID, but TPM state is copied to the new UUID path → BitLocker unlocks automatically (PCR measurements match because firmware and NVRAM are identical)
- **If TPM state is lost:** BitLocker will request a recovery key (find it in `tpm-state/bitlocker-recovery-keys.txt` in the backup)

---
## 11. UEFI/OVMF Firmware and NVRAM Restore

### Automatic Handling

virtnbdrestore's `files.restore()` copies NVRAM (`*_VARS.fd`) and OVMF firmware files to their **original system paths** (e.g., `/var/lib/libvirt/qemu/nvram/`), not to the output directory.

### Clone Mode NVRAM Isolation

In clone mode (`--name`), vmrestore's `define_new_identity()` function:
1. Copies NVRAM to `{clone-name}_VARS.fd` in the same directory
2. Updates `<nvram>` path in the VM's XML
3. Sets ownership to `libvirt-qemu:libvirt-qemu` with mode 600

Without this, the original VM and clone would share a single NVRAM file — modifying one would corrupt the other's Secure Boot state.

### NVRAM Recovery if Missing

If the NVRAM file is missing after restore:

```bash
# Check what path the VM expects
sudo virsh dumpxml my-vm | grep nvram

# Copy from backup (bare-named copy is the latest state)
sudo cp /mnt/backups/vm/my-vm/20260303/my-vm_VARS.fd \
  /var/lib/libvirt/qemu/nvram/my-vm_VARS.fd
sudo chown libvirt-qemu:libvirt-qemu /var/lib/libvirt/qemu/nvram/my-vm_VARS.fd
```

### Cross-Host Considerations

When restoring to a different host, verify that OVMF firmware paths match:

```bash
# Check firmware path in VM XML
sudo virsh dumpxml my-vm | grep -E 'loader|nvram'

# Verify firmware exists on target host
ls /usr/share/OVMF/OVMF_CODE_4M.ms.fd
```

---
## 12. Single File Restore (virtnbdmap)

For recovering individual files without a full VM restore, use `virtnbdmap` directly:

```bash
# Load NBD kernel module
sudo modprobe nbd max_partitions=15

# Map backup to block device (specify data files in chronological order)
sudo virtnbdmap -f vda.full.data,vda.inc.virtnbdbackup.1.data,vda.inc.virtnbdbackup.2.data

# Identify partitions
sudo fdisk -l /dev/nbd0

# Mount partition (read-only to prevent modifications)
sudo mount -o ro /dev/nbd0p2 /mnt/restore-temp      # Linux (ext4, xfs)
sudo mount -o ro,norecovery -t ntfs3 /dev/nbd0p3 /mnt/restore-temp  # Windows (NTFS)

# Copy needed files
cp /mnt/restore-temp/path/to/file /tmp/recovered-file

# Cleanup
sudo umount /mnt/restore-temp
# Press Ctrl+C in the virtnbdmap terminal
```

> **Warning:** Data files must be specified in correct chronological order. Wrong order produces a corrupted image.

> **Note:** vmrestore.sh does not orchestrate virtnbdmap. This is a manual, low-level recovery tool from the virtnbdbackup package.

---
## 13. Instant Boot from Backup

Test a backup by booting it directly without performing a full restore:

```bash
# Map backup
sudo virtnbdmap -f /mnt/backups/vm/my-vm/2026-W09/*.data

# Create a copy-on-write overlay (all writes go to overlay, backup untouched)
sudo qemu-img create -f qcow2 -b /dev/nbd0 -F raw /tmp/overlay.qcow2

# Boot with QEMU
sudo qemu-system-x86_64 -enable-kvm -m 4096 -drive file=/tmp/overlay.qcow2

# Cleanup: kill QEMU, then Ctrl+C virtnbdmap, then rm overlay
sudo rm /tmp/overlay.qcow2
```

> **Warning:** This is an advanced, manual procedure. The overlay approach means the backup is not modified, but the VM runs in degraded mode (no virtiofs, no SPICE, no defined network). Useful primarily for verifying that the backup boots.

---
## 14. Verifying Backups Before Restore

### Checksum Verification

```bash
# Verify checksums for a VM's latest period
sudo vmrestore --verify my-vm

# Verify a specific period
sudo vmrestore --verify my-vm --period 2026-W09
```

Runs `virtnbdrestore -o verify`, which recomputes adler32 checksums and compares them against the `.data.chksum` files. Any mismatch is reported.

### Metadata Dump

```bash
sudo vmrestore --dump my-vm --period 2026-W09
```

Outputs JSON metadata including virtual disk size, data size, checkpoint names, dates, and compression details. Useful for confirming what's in a backup before restoring.

---
## 15. Post-Restore Steps

### Automated by vmrestore

vmrestore handles these automatically — no manual action needed:

| Step | Details |
|------|---------|
| Disk restoration | virtnbdrestore reconstructs qcow2 from `.data` files |
| VM definition | `virsh define` with appropriate flags for DR or clone mode |
| TPM state | Copied to `/var/lib/libvirt/swtpm/{UUID}/tpm2/` with correct ownership |
| NVRAM isolation | Clone mode copies to `{clone}_VARS.fd` |
| Disk integrity check | `qemu-img check` run on all restored disk files |
| Storage pool refresh | `virsh pool-refresh` on the containing pool |
| Log file | Written to `/var/log/vmrestore/` with full command and timing details |

### After Every Restore — Manual Steps

These apply to **every** restore, DR or clone. They are not edge cases.

#### 1. Start and Verify the VM

```bash
sudo virsh start {vm-name}
sudo virsh domdisplay {vm-name}   # get VNC/SPICE display URL
```

Or open virt-manager and check the console.

#### 2. Clean Stale Checkpoint Metadata

The restored VM inherits checkpoint metadata from the backup. These checkpoints don't match the restored disk state and **will cause the next vmbackup run to fail** with "bitmap already exists" errors. Always clean them immediately after restore:

```bash
for cp in $(sudo virsh checkpoint-list {vm-name} --name 2>/dev/null); do
  sudo virsh checkpoint-delete {vm-name} --checkpointname "$cp" --metadata
done
```

This only removes metadata — it does not affect the restored disk data. vmbackup's next run will create a fresh full backup and start a new chain.

#### 3. Re-Add CD-ROM Drives

virtnbdrestore strips all non-restorable device types from the VM definition, including CD-ROM drives and raw/passthrough devices. This is by design — these devices contain paths that may not exist on the restore host. The VM will boot without them.

To re-add a CD-ROM drive:

```bash
# Add an empty CD-ROM (SATA bus)
sudo virt-xml {vm-name} --add-device --disk device=cdrom,bus=sata

# Or with an ISO attached
sudo virt-xml {vm-name} --add-device --disk device=cdrom,bus=sata,source.file=/path/to/image.iso

# Attach/change ISO on an existing CD-ROM
sudo virsh change-media {vm-name} sdb /path/to/image.iso --insert
```

#### 4. Verify Network Attachment

The restored VM's network interfaces reference the virtual network names from the original host (e.g., `default`, `br0`). If the restore host has different network names, the VM may fail to start or start with no network. Check with:

```bash
sudo virsh domiflist {vm-name}
```

Edit the VM XML if the network name needs changing:

```bash
sudo virsh edit {vm-name}
# Find <source network='...'/> and update to match the restore host
```

---
## 16. Troubleshooting

### Disk Collision Protection — "BLOCKED" Errors

vmrestore's `preflight_disk_safety()` checks predicted output files against all live VM disks before restoring.

| Scenario | Behaviour |
|----------|-----------|
| Output file is the **live disk of another VM** | **Always blocked** — choose a different `--restore-path` |
| Output file is the **live disk of the same VM** (running) | **Blocked** — shut off the VM first |
| Output file is the **live disk of the same VM** (shut off) | Requires `--force` (disaster recovery) |
| Output file **already exists** (not a live disk) | Requires `--force` to overwrite |
| Clone mode | Uses staging directory — no collision with restore path during restore |

#### Examples

```bash
# SAFE: clone to same directory as original VM (staging dir prevents collision)
sudo vmrestore --vm my-vm --name my-clone --restore-path /var/lib/libvirt/images/

# BLOCKED: final filename would collide with another VM's live disk
sudo vmrestore --vm my-vm --name other-vm --restore-path /var/lib/libvirt/images/
# ERROR: BLOCKED: /var/lib/libvirt/images/other-vm.qcow2 is the live disk of VM 'other-vm'

# DR: must shut off VM and use --force
sudo virsh shutdown my-vm
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --force
```

### "VM already defined" Error

The VM name already exists in libvirt. Use `--force` to undefine it first:

```bash
sudo vmrestore --vm my-vm --restore-path /tmp/restore --force
```

Or undefine manually:

```bash
sudo virsh destroy my-vm 2>/dev/null
sudo virsh undefine my-vm --managed-save --nvram --checkpoints-metadata
```

### "Cannot resolve data directory"

vmrestore cannot find a data directory containing `.data` files. Common causes:
- Wrong `--period` value — check available periods with `--list-restore-points`
- Backup path not mounted — verify `--backup-path` or check that vmbackup.conf has a valid `BACKUP_PATH`
- Accumulate VMs store data directly in the VM directory (no period subdirectory)

```bash
sudo vmrestore --list-restore-points my-vm
```

### Pre-Flight Free Space Check

vmrestore automatically checks destination free space before restoring:

| Condition | Action |
|-----------|--------|
| Sufficient space with >10% headroom | Logs data size and free space, proceeds |
| Sufficient space but <10% headroom | **Warns** — restored qcow2 can be larger than raw backup data |
| Insufficient space | **Aborts** with `Insufficient space: restore needs X but only Y available on Z` |
| Cannot determine free space | **Warns** and skips the check (non-fatal) |

### "NBD server not available" or Socket Errors

```bash
# Ensure NBD module is loaded
sudo modprobe nbd
# Check for running NBD processes
ps aux | grep nbd
# Clear stale socket files
sudo rm -f /var/tmp/virtnbdbackup.*
```

### "Bitmap already exists" on First Backup After Restore

Clean stale checkpoint metadata (see [section 15 Cleaning Stale Checkpoints](#2-clean-stale-checkpoint-metadata)).

### Restored VM Won't Boot (UEFI/TPM)

1. **Check OVMF firmware:** `ls /usr/share/OVMF/OVMF_CODE_4M.ms.fd` — path must exist on the restore host
2. **Check NVRAM:** `sudo virsh dumpxml {vm} | grep nvram` — verify file exists at that path
3. **Check TPM state:** `ls -la /var/lib/libvirt/swtpm/{UUID}/tpm2/` — must exist with correct ownership
4. **Ownership:** `tss:tss` on Debian/Ubuntu (vmrestore detects this dynamically)
5. **If TPM state was not restored:** VM with BitLocker may request recovery key (see [section 10 TPM and BitLocker Restore](#10-tpm-and-bitlocker-restore))

### Restored VM is Missing CD-ROM Drives

Expected behaviour. See [section 15 Re-Adding CD-ROM Drives](#3-re-add-cd-rom-drives).

### Clone Boots but BitLocker Asks for Recovery Key

This is **expected** when TPM state was not restored or when NVRAM differs. Enter the recovery key from `tpm-state/bitlocker-recovery-keys.txt` in the backup. BitLocker will re-seal on next reboot.

If this happens on a **DR restore** (same UUID), check that TPM state was restored correctly (see [section 10](#10-tpm-and-bitlocker-restore)).

### Restore is Extremely Slow

```bash
# Check storage performance
dd if=/dev/zero of=/tmp/testfile bs=1M count=1024 oflag=direct
# Should be >100 MB/s for reasonable restore times

# Avoid restoring over network mounts — copy backup locally first
# Ensure restore target is on fast storage (SSD/NVMe preferred)
```

### Incremental File Missing from Chain

If an incremental data file is corrupted or missing, you can only restore up to the last good checkpoint:

```bash
sudo vmrestore --vm my-vm --restore-point 1 --restore-path /tmp/restore
```

### "Permission denied" During Restore

```bash
# vmrestore must run as root
sudo vmrestore ...

# Check AppArmor if virsh commands fail
sudo aa-teardown  # Disable AppArmor for this session (Debian/Ubuntu)
```

### Dry Run Shows Unexpected Paths

```bash
sudo vmrestore --vm my-vm --restore-path /tmp/test --dry-run
```

---
## 17. Quick Reference Commands

### Inventory & Inspection

```bash
# List all VMs with backup info
sudo vmrestore --list

# List restore points for a VM (auto-resolves latest period)
sudo vmrestore --list-restore-points my-vm

# List restore points for a specific period
sudo vmrestore --list-restore-points my-vm --period 2026-W09

# Verify backup checksums
sudo vmrestore --verify my-vm --period 20260303

# Dump backup metadata (JSON)
sudo vmrestore --dump my-vm --period 2026-W10
```

### Disaster Recovery

```bash
# Latest state — rebuild the VM with original identity
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images

# Specific period — recover from a particular date
sudo vmrestore --vm my-vm --period 20260302 \
  --restore-path /var/lib/libvirt/images

# Replace existing VM definition
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --force
```

### Clone Restore

```bash
# New-identity clone (new UUID, new MACs, isolated NVRAM)
sudo vmrestore --vm my-vm \
  --name test-clone --restore-path /var/lib/libvirt/images
```

### Point-in-Time

```bash
# Specific checkpoint
sudo vmrestore --vm my-vm --restore-point 3 \
  --restore-path /var/lib/libvirt/images

# Full baseline only
sudo vmrestore --vm my-vm --restore-point full \
  --restore-path /var/lib/libvirt/images
```

### Advanced

```bash
# Path-aware --vm (backup path embedded in argument)
sudo vmrestore --vm /mnt/backups/vm/my-vm \
  --period 20260302 --restore-path /tmp/restore

# Restore from archived chain
sudo vmrestore \
  --vm /mnt/backups/vm/my-vm/2026-W09/.archives/chain-2026-02-28.1 \
  --restore-path /tmp/restore/archived

# Restore single disk only
sudo vmrestore --vm my-vm --disk vda --restore-path /tmp/restore

# Disk-only (no VM definition)
sudo vmrestore --vm my-vm --restore-path /tmp/restore --skip-config

# Dry run (preview without executing)
sudo vmrestore --vm my-vm --restore-path /tmp/restore --dry-run

# Restore host /etc/libvirt configuration
sudo vmrestore --host-config
```

### Single-File Recovery (virtnbdmap — Manual)

```bash
# Map backup to block device
sudo modprobe nbd max_partitions=15
sudo virtnbdmap -f <full.data>[,<inc.1.data>,<inc.2.data>]

# Mount partition
sudo mount -o ro /dev/nbd0p2 /mnt/restore-temp       # Linux
sudo mount -o ro,norecovery -t ntfs3 /dev/nbd0p3 /mnt/restore-temp  # Windows

# Cleanup
sudo umount /mnt/restore-temp
# Ctrl+C virtnbdmap
```

### Post-Restore

```bash
# Start restored VM
sudo virsh start {vm-name}

# Verify
sudo virsh domblklist {vm-name}
sudo virsh domdisplay {vm-name}

# Clean stale checkpoints
for cp in $(sudo virsh checkpoint-list {vm-name} --name 2>/dev/null); do
  sudo virsh checkpoint-delete {vm-name} --checkpointname "$cp" --metadata
done
```

---

*vmrestore.sh v0.4 — Part of the vmbackup ecosystem*

<p align="center">
  <img src="docs/vibe-coded.png" alt="Vibe Coded" />
</p>