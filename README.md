# vmrestore — KVM/libvirt VM Restore & Disaster Recovery

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/release/doutsis/vmrestore)](https://github.com/doutsis/vmrestore/releases)

The restore half of the [vmbackup](https://github.com/doutsis/vmbackup) ecosystem. vmbackup backs up KVM/libvirt virtual machines — vmrestore brings them back.

vmrestore is a standalone script with no shared code or runtime coupling to vmbackup, but it exclusively restores backups created by vmbackup. The two are complementary halves of one system.

It wraps [virtnbdrestore](https://github.com/abbbi/virtnbdbackup) to provide single-command disaster recovery, clone restores and point-in-time recovery — with full identity management, TPM/BitLocker support and pre-flight safety checks.

## Why vmrestore

[vmbackup](https://github.com/doutsis/vmbackup) captures everything needed to rebuild a VM — disk images, VM configuration, TPM state, NVRAM, BitLocker recovery keys and checksums. Backups are only as good as your ability to restore them, and restoring all of that correctly involves more than running virtnbdrestore. Disk images must be reconstructed across full and incremental chains. The VM must be re-defined in libvirt with the original UUID and MAC addresses intact. TPM state needs to land at the right path. NVRAM must be isolated for clones. Storage pools need refreshing. Disk collisions must be caught before anything is overwritten.

vmrestore handles all of it. One command, every detail — so the moment you need a restore is not the moment you're learning how to do one.

- **Disaster recovery** — rebuild a destroyed VM from any backup chain
- **Clone restores** — stand up an isolated copy with a new name, no identity conflicts
- **Point-in-time recovery** — roll back to any incremental checkpoint in the chain
- **Single-disk restore** — surgical recovery of one disk without touching the rest
- **Pre-flight safety** — dry-run mode, collision detection, disk integrity checks and detailed logging at every step

vmbackup and vmrestore are tested together but coupled to nothing. vmrestore is a standalone script — no shared libraries, no daemons, no runtime dependencies on vmbackup. Install it on a recovery host that has never seen vmbackup and it works the same way.

## Quick Start

**Debian / Ubuntu:**

```bash
wget https://github.com/doutsis/vmrestore/releases/download/v0.5.3/vmrestore_0.5.3_all.deb
sudo dpkg -i vmrestore_0.5.3_all.deb
```

**Any distro (from source):**

```bash
git clone https://github.com/doutsis/vmrestore.git
cd vmrestore
sudo make install
```

**Manual install:**

```bash
sudo mkdir -p /opt/vmrestore
sudo curl -fSL https://raw.githubusercontent.com/doutsis/vmrestore/main/vmrestore.sh \
     -o /opt/vmrestore/vmrestore.sh
sudo chmod 750 /opt/vmrestore/vmrestore.sh
sudo ln -sf /opt/vmrestore/vmrestore.sh /usr/local/bin/vmrestore
```

Then:

```bash
sudo vmrestore --list                    # what VMs have backups?
sudo vmrestore --list-restore-points my-vm   # what restore points exist?
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --dry-run  # preview
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images            # restore
```

## Features

**What you can do:**
- **Four restore modes** — disaster recovery, clone, point-in-time, and disk restore
- **Multi-disk VMs** — all disks restored in a single run, with automatic naming
- **TPM and BitLocker** — just works. No recovery keys needed in any restore mode

**What keeps you safe:**
- **Pre-flight checks** — disk collisions, free space, running VM detection. Blocks dangerous restores before they start
- **`.pre-restore` backups** — original disks are preserved with overwrite protection
- **Dry-run mode** — preview every action before committing
- **Integrity verification** — `qemu-img check` on every restored disk

**What makes it easy:**
- **One command to restore** — backup type, period, chain layout, TPM state, storage pools are all auto-detected
- **Discover before you restore** — `--list` and `--list-restore-points` show exactly what's available
- **Standalone script** — self-contained bash, no shared code with vmbackup, no runtime dependencies

## Prerequisites

| Package | Version | Purpose |
|---------|---------|----------|
| `virtnbdbackup` | ≥ 2.28 | Provides `virtnbdrestore` (disk restore engine) |
| `libvirt-daemon-system` | — | `virsh` domain management |
| `qemu-utils` | — | `qemu-img` for post-restore disk checks |

**vmrestore only works with backups created by [vmbackup](https://github.com/doutsis/vmbackup).** It reads vmbackup's configuration to resolve the backup path and depends on the specific on-disk structure, metadata files and naming conventions that vmbackup produces. vmrestore has no runtime coupling to vmbackup — no shared code, no sourced modules — but the two scripts are designed as complementary halves of one backup-and-restore system.

## How It Works

vmrestore reads the on-disk backup structure created by vmbackup and orchestrates the restore:

1. **Discovery** — resolves backup path, detects layout (periodic or accumulate), finds the latest period and chain
2. **Validation** — pre-flight checks: disk collision detection, free space, running VM detection, backup integrity
3. **Restore** — runs `virtnbdrestore` with the correct flags for DR or clone mode
4. **Identity** — DR: re-injects original UUID and MAC addresses. Clone: lets libvirt assign new identity
5. **TPM/NVRAM** — restores TPM state to the correct UUID path; isolates NVRAM in clone mode
6. **Definition** — defines the VM in libvirt, refreshes storage pools, runs `qemu-img check`

```
vmrestore.sh             ← single self-contained script
├── reads                → vmbackup's on-disk backup structure
├── calls                → virtnbdrestore (disk reconstruction)
├── manages              → virsh define/undefine, TPM state, NVRAM
└── logs to              → /var/log/vmrestore/ (or ./logs/ in dev)
```

## Restore Modes

Before restoring, find out what's available:

```bash
# Which VMs have backups?
sudo vmrestore --list

# What restore points exist for a specific VM?
sudo vmrestore --list-restore-points my-vm

# Restore points for a specific period?
sudo vmrestore --list-restore-points my-vm --period 2026-W09
```

`--list` shows all VMs with their backup type, total size, restore point count (summed across all periods), archived chain count, and tags for TPM and multi-disk VMs. `--list-restore-points` shows every retention period with its restore points (numbered to match `--restore-point`), date, type (FULL, Incremental, COPY), per-checkpoint disk set, and any archived chains — everything you need to decide what to restore and from when. No log files are created for read-only commands.

### Disaster Recovery (DR)

Your VM is gone — disk corruption, host failure, accidental deletion. DR mode rebuilds it exactly as it was: same name, same UUID, same MAC addresses, same network identity. To the rest of your infrastructure, it's as if nothing happened.

By default, vmrestore restores the latest backup. Use `--list-restore-points` to see what's available if you need to confirm the backup date before restoring.

Technically, vmrestore reconstructs the disk images, re-injects the original UUID and MAC addresses into the VM definition, restores TPM state and NVRAM, defines the VM in libvirt, and refreshes storage pools.

```bash
# VM is gone — restore from latest backup
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images

# VM still defined in libvirt — force undefine + restore
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --force
```

### Clone

You need a copy of a VM for testing, development, or migration — but the original must keep running undisturbed. Clone mode creates a fully independent copy with a new name, new UUID, and new MAC addresses. It won't conflict with the original on the network, and both can run side by side.

Like DR, cloning uses the latest backup by default. To clone from a specific point in time, combine `--name` with `--period` or `--restore-point` (see [Point-in-Time](#point-in-time) below).

Technically, vmrestore reconstructs the disk images with new filenames, lets libvirt assign fresh identity (UUID, MACs), copies NVRAM to an isolated file so the clone has its own firmware state, and migrates TPM state to the new UUID so BitLocker unlocks without recovery keys.

```bash
sudo vmrestore --vm my-vm --name test-clone \
  --restore-path /var/lib/libvirt/images
```

| Behaviour | DR (no `--name`) | Clone (`--name`) |
|-----------|-------------------|------------------|
| UUID | Preserved from backup | New (assigned by libvirt) |
| MAC addresses | Preserved from backup | New (assigned by libvirt) |
| VM name | Original | Clone name |
| Disk filenames | Original | `{clone}.qcow2` or `{clone}-{vda,vdb,…}.qcow2` |
| NVRAM | Restored to original path | Copied to `{clone}_VARS.fd` |
| TPM state | At original UUID | At new UUID |
| `--force` needed if VM exists? | Yes | No |
| Can run alongside original? | No | Yes |
| BitLocker | Unlocks automatically | Unlocks automatically |

> `{clone}` = the value you pass to `--name` (e.g. `--name test-clone` → `test-clone.qcow2`)

### Point-in-Time

Something went wrong at 2pm but the backup from this morning was fine. Point-in-time lets you restore to a specific moment — a particular restore point, a specific backup period, or even an older archived chain. You pick exactly how far back to go.

If disks were added or removed between checkpoints, vmrestore detects the configuration change and automatically restores the correct disk set for the target checkpoint — no manual intervention needed. Use `--list-restore-points` to see the per-checkpoint disk layout before restoring.

Start with `--list-restore-points` to see what's available — it shows every period with numbered restore points, dates, and types, so you can identify exactly which point to restore to:

```bash
sudo vmrestore --list-restore-points my-vm
```

Then pick a period, a restore point number, or a path to an archived chain:

Technically, vmrestore uses `--restore-point` to select a point within an incremental backup chain (the FULL base plus incrementals up to that point), `--period` to target a specific rotation period (weekly, daily, monthly), or a direct path to an archived chain in `.archives/`.

```bash
# Specific period
sudo vmrestore --vm my-vm --period 2026-W09 \
  --restore-path /var/lib/libvirt/images

# Specific restore point within a period
sudo vmrestore --vm my-vm --restore-point 3 \
  --restore-path /var/lib/libvirt/images

# Archived chain
sudo vmrestore --vm /mnt/backups/vm/my-vm/2026-W09/.archives/chain-2026-02-28 \
  --restore-path /tmp/restore
```

Point-in-time works with both DR and clone modes — add `--name` to clone from a specific point instead of replacing the original.

### Disk Restore (`--disk`)

One disk went bad but everything else is fine — the VM definition, the other disks, TPM, NVRAM. You don't need a full DR restore, you just need to swap out the broken disk. Disk restore replaces specific disk file(s) without touching anything else. The VM keeps its identity, its configuration, and its other disks exactly as they are.

Use `--list-restore-points` to see which disks are available at each restore point — each row shows a `Disk(s)` column listing the device names backed up at that checkpoint:

```bash
sudo vmrestore --list-restore-points my-vm
# Each restore point row includes: Disk(s) column (e.g. sda, vda, vdb)
```

Pick the disk(s) you need to replace:

```bash
# Replace one disk (VM must be shut off)
sudo vmrestore --vm my-vm --disk vdb

# Replace multiple disks at once
sudo vmrestore --vm my-vm --disk vda,vdb,sda

# Replace all disks
sudo vmrestore --vm my-vm --disk all

# Point-in-time — roll back a disk to restore point 3
sudo vmrestore --vm my-vm --disk vdb --restore-point 3

# Extract to staging instead of replacing in-place (VM can be running)
sudo vmrestore --vm my-vm --disk vdb --restore-path /tmp/restore
```

Technically, vmrestore resolves each disk's original path from the live VM XML, creates a `.pre-restore` backup of each existing disk file, runs `virtnbdrestore -d {disk}` for each, verifies integrity with `qemu-img check`, and sets ownership/permissions. VM definitions, UUIDs, MAC addresses, TPM and NVRAM are untouched.

**Safety:** vmrestore refuses to overwrite an existing `.pre-restore` file — if one exists from a previous restore that wasn't cleaned up, you'll be told to delete it first (or use `--no-pre-restore`). This prevents accidentally losing your only rollback copy.

**After restoring:** The replaced disk(s) invalidate QEMU checkpoint bitmaps. vmrestore warns you about this and tells you exactly what to do. If vmbackup has `ENABLE_AUTO_RECOVERY_ON_CHECKPOINT_CORRUPTION="yes"`, the next backup handles it automatically.

Disk restore also works with `--restore-point` for point-in-time recovery of individual disks.

## Multi-Disk VMs

vmrestore handles multi-disk VMs automatically — all disks are restored in a single run.

In **DR mode**, original filenames are preserved. In **clone mode**, each disk is renamed using the `--name` value and the libvirt device target:

| Disks | Clone naming |
|-------|-------------|
| Single disk | `{name}.qcow2` |
| Multiple disks | `{name}-{device}.qcow2` per disk |

Where `{device}` is the libvirt target (`vda`, `vdb`, `sda`, etc.) — determined by the VM's virtual hardware bus (VirtIO, SATA, SCSI).

**Example** — clone a VM with two VirtIO disks and one SATA disk:

```bash
sudo vmrestore --vm my-vm --name test-clone \
  --restore-path /var/lib/libvirt/images
```

Produces:

```
test-clone-vda.qcow2    # VirtIO system disk
test-clone-vdb.qcow2    # VirtIO secondary disk
test-clone-sda.qcow2    # SATA disk
```

To restore or replace individual disks from a multi-disk backup, see [Disk Restore](#disk-restore---disk) above.


## Post-Restore

After every restore:

```bash
# Start the VM
sudo virsh start my-vm
```

**Checkpoint cleanup:** Restoring disk(s) invalidates QEMU checkpoint bitmaps. By default, vmbackup handles this automatically — its `ENABLE_AUTO_RECOVERY_ON_CHECKPOINT_CORRUPTION` setting (default: `yes`) archives the old chain and starts a fresh FULL on the next backup run. No manual cleanup is needed.

If auto-recovery has been disabled (`warn`), clean stale checkpoints manually before the next backup:

```bash
for cp in $(sudo virsh checkpoint-list my-vm --name 2>/dev/null); do
  sudo virsh checkpoint-delete my-vm --checkpointname "$cp" --metadata
done
```

## Installation

### Uninstall

**Debian / Ubuntu (.deb install):**

```bash
sudo apt remove vmrestore    # remove but keep logs
sudo apt purge vmrestore     # remove everything including logs
```

**From source (make install):**

```bash
sudo make uninstall
```

Uninstall removes the script, PATH symlink and log directory. Backup data is never touched — it lives wherever you configured `BACKUP_PATH` in vmbackup.

## Tested

vmrestore and [vmbackup](https://github.com/doutsis/vmbackup) are tested end-to-end on a fleet of Linux and Windows VMs across multiple config instances. Tests are destructive — VMs are backed up, checkpointed, destroyed and restored from scratch — validating the full lifecycle from first backup to disaster recovery.

### Test Fleet

| VM | Instance | Disks | TPM | Boot |
|----|----------|-------|-----|------|
| Linux base | default | 1× VirtIO | No | BIOS |
| Linux multi-disk | default | 2× VirtIO + 1× SATA | No | BIOS |
| Linux multi-disk clone | default | 2× VirtIO + 1× SATA | No | BIOS |
| Windows base | default | 1× VirtIO | Yes | UEFI |
| Windows multi-disk | default | 2× VirtIO + 1× SATA | Yes | UEFI |
| Windows multi-disk clone | default | 2× VirtIO + 1× SATA | Yes | UEFI |
| Linux base | prod | 1× VirtIO | No | BIOS |
| Linux multi-disk | prod | 2× VirtIO + 1× SATA | No | BIOS |
| Windows base | prod | 1× VirtIO | Yes | UEFI |
| Windows multi-disk | prod | 2× VirtIO + 1× SATA | Yes | UEFI |

The `default` and `prod` instances back up to isolated paths with separate VM filters, validating that multi-instance deployments stay fully isolated.

### Testing Phases

1. **CLI and argument validation** — all vmbackup and vmrestore flags, error paths, privilege enforcement and conflict guards
2. **Record identities** — UUID, MAC addresses, TPM presence and disk layout for every VM
3. **Build backup chains with checkfiles** — unique marker files are written inside each guest (Linux and Windows) via the QEMU agent between backup rounds. Multiple vmbackup rounds across both instances create active and archived chains, each capturing different checkfile content. This gives every restore point a verifiable fingerprint — after restore, the checkfile content proves which point in time was actually recovered
4. **Backup verification** — `vmrestore --verify` confirms integrity across both instances
5. **Prune** — archived period cleanup on live backup data
6. **Clone restore** — restore as clones with new identity, verify disk integrity, boot via QEMU agent, confirm checkfile content matches the source backup, then destroy
7. **Point-in-time restore** — restore to specific checkpoints across both active and archived chains. Each restored VM is booted and the checkfile inside the guest is read back to confirm it contains exactly the content that existed at that point in the backup history — not the latest, not a neighbour, but the precise checkpoint requested. This is the strongest proof that incremental chains and archive navigation produce correct results
8. **Single-disk restore** — replace one disk on a multi-disk VM, verify `.pre-restore` backup, disk integrity and vmbackup auto-heal after chain invalidation
9. **Destroy everything** — delete all original VMs including definitions, disks and NVRAM
10. **DR restore** — restore all VMs from backup to a clean path, verify UUID/MAC match originals, all disks intact, TPM state preserved, checkfiles survived the full backup → destroy → restore cycle, BitLocker not triggered
11. **Multi-instance backup and restore** — backup and restore across config instances (`--config-instance prod`), verifying that each instance resolves to its own backup path, lists only its own VMs, and restores produce correct identities. Covers `VMBACKUP_INSTANCE` env var equivalence and cross-instance clone and DR
12. **Windows TPM/BitLocker** — clone and DR with TPM state isolation per UUID, NVRAM separation, archived chain recovery, and BitLocker unlock without recovery prompt
13. **Auto-recovery** — corrupt `.cpt` chain marker, verify vmbackup archives the broken chain and starts fresh

Every restore verifies disk integrity (`qemu-img check`), identity against pre-test baselines, and successful boot via automated QEMU guest agent polling.

## Documentation

The full guide ships with vmrestore and is always available locally:

```
cat /opt/vmrestore/vmrestore.md
```

[vmrestore.md](vmrestore.md) covers:

- Backup structure and rotation policies
- Restore scenarios — disaster recovery, clones, point-in-time, single-disk
- TPM, BitLocker and NVRAM handling
- Troubleshooting
- Quick reference command sheet

## Issues

Found a bug or have a feature request? [Open an issue](https://github.com/doutsis/vmrestore/issues).

## License

MIT

---

<p align="center">
  <img src="docs/vibe-coded.png" alt="100% Vibe Coded" width="300">
</p>
