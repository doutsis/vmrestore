# vmrestore

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/release/doutsis/vmrestore)](https://github.com/doutsis/vmrestore/releases)

The restore half of the [vmbackup](https://github.com/doutsis/vmbackup) ecosystem. vmbackup backs up KVM/libvirt virtual machines — vmrestore brings them back.

vmrestore is a standalone script with no shared code or runtime coupling to vmbackup, but it exclusively restores backups created by vmbackup. The two are complementary halves of one system.

It wraps [virtnbdrestore](https://github.com/abbbi/virtnbdbackup) to provide single-command disaster recovery, clone restores and point-in-time recovery — with full identity management, TPM/BitLocker support and pre-flight safety checks.

## Why vmrestore

[vmbackup](https://github.com/doutsis/vmbackup) captures everything needed to rebuild a VM — disk images, VM configuration, TPM state, NVRAM, BitLocker recovery keys and checksums. But restoring all of that involves more than just running virtnbdrestore. You need to reconstruct disk images, re-define the VM in libvirt with the correct UUID and MAC addresses, restore TPM state to the right path, isolate NVRAM for clones, check for disk collisions and refresh storage pools.

vmrestore orchestrates the full restore lifecycle so you can go from "VM is gone" to "VM is running" in one command.

## Quick Start

**Debian / Ubuntu:**

```bash
wget https://github.com/doutsis/vmrestore/releases/download/v0.4/vmrestore_0.4_all.deb
sudo dpkg -i vmrestore_0.4_all.deb
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

- **Disaster recovery and clone modes** — DR preserves original identity (UUID, MAC, name); clone creates a fully independent copy with new identity. One flag (`--name`) controls the mode
- **Point-in-time recovery** — restore to any checkpoint in a backup chain, any period, or any archived chain
- **TPM and BitLocker support** — TPM state is restored automatically. BitLocker unlocks without recovery keys in both DR and clone mode
- **UEFI/NVRAM isolation** — clone mode copies NVRAM to a new file so the original and clone don't share firmware state
- **Pre-flight safety checks** — disk collision detection, free space verification, running VM detection. Blocks dangerous restores before they start
- **Auto-detection** — backup type, period, restore points, chain layout, TPM state and storage pool are all resolved automatically from the backup structure
- **Dry-run mode** — preview every action vmrestore would take without writing anything
- **Standalone script** — self-contained bash. No shared code with vmbackup, no modules, no database — but purpose-built to restore what vmbackup creates

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

### Disaster Recovery (DR)

Rebuilds the VM with its original identity — same name, UUID and MAC addresses. The restored VM is a direct replacement for the original.

```bash
# VM is gone — restore from latest backup
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images

# VM still defined in libvirt — force undefine + restore
sudo vmrestore --vm my-vm --restore-path /var/lib/libvirt/images --force
```

### Clone

Creates an independent copy with new identity. The original VM is untouched.

```bash
sudo vmrestore --vm my-vm --name test-clone \
  --restore-path /var/lib/libvirt/images
```

### Point-in-Time

```bash
# Specific period
sudo vmrestore --vm my-vm --period 2026-W09 \
  --restore-path /var/lib/libvirt/images

# Specific checkpoint within a period
sudo vmrestore --vm my-vm --restore-point 3 \
  --restore-path /var/lib/libvirt/images

# Archived chain
sudo vmrestore --vm /mnt/backups/vm/my-vm/2026-W09/.archives/chain-2026-02-28 \
  --restore-path /tmp/restore
```

## Comparison: DR vs Clone

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

## Prerequisites

| Package | Version | Purpose |
|---------|---------|---------|
| `virtnbdbackup` | ≥ 2.28 | Provides `virtnbdrestore` (disk restore engine) |
| `libvirt-daemon-system` | — | `virsh` domain management |
| `qemu-utils` | — | `qemu-img` for post-restore disk checks |
| `bash` | ≥ 5.0 | Required for associative arrays |

**vmrestore only works with backups created by [vmbackup](https://github.com/doutsis/vmbackup).** It reads vmbackup's configuration to resolve the backup path and depends on the specific on-disk structure, metadata files and naming conventions that vmbackup produces. vmrestore has no runtime coupling to vmbackup — no shared code, no sourced modules — but the two scripts are designed as complementary halves of one backup-and-restore system.

## Post-Restore

After every restore:

```bash
# Start the VM
sudo virsh start my-vm

# Clean stale checkpoint metadata (required before next vmbackup run)
for cp in $(sudo virsh checkpoint-list my-vm --name 2>/dev/null); do
  sudo virsh checkpoint-delete my-vm --checkpointname "$cp" --metadata
done
```

## Documentation

Full technical documentation is included in [vmrestore.md](vmrestore.md) (installed to `/opt/vmrestore/vmrestore.md`). It covers backup structure, rotation policies, restore scenarios, TPM/BitLocker/NVRAM handling, single-file recovery via virtnbdmap, troubleshooting and a quick reference command sheet.

## Issues

Found a bug or have a feature request? [Open an issue](https://github.com/doutsis/vmrestore/issues).

## License

MIT

---

<p align="center">
  <img src="docs/vibe-coded.png" alt="100% Vibe Coded" width="300">
</p>
