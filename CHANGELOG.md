# Changelog

All notable changes to [vmrestore](https://github.com/doutsis/vmrestore) will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [0.5.3] - 2026-04-12

### Fixed

- **`--help` showed wrong version** — `usage()` hardcoded `v0.5.1` while `--version` showed `0.5.2`. Version string now uses `$VERSION` variable.

### Removed

- **`--host-config` removed** — Host config backup was removed in vmbackup v0.5.3. The `--host-config` flag, `restore_host_config()` function, and `__HOST_CONFIG__` display in `--list` output have been stripped entirely. The `--host-target` flag is also removed.

### Added

- **`--config-instance` flag** — Select a named vmbackup config instance (e.g., `--config-instance prod`). Also reads `VMBACKUP_INSTANCE` environment variable as fallback. Exits with an error if the specified instance directory does not exist. Resolves hardcoded `/opt/vmbackup/config/default/vmbackup.conf` path for multi-instance deployments.

## [0.5.2] - 2026-03-29

### Changed

- **Per-checkpoint disk column in `--list-restore-points`** — Each restore point row now shows a `Disk(s)` column listing the disks backed up at that specific checkpoint. Replaces the previous top-level `Disks:` summary that showed the union across all checkpoints — which was misleading when disks were added or removed mid-chain.

- **`--list` disk tag reflects latest checkpoint** — The `[vda, vdb, ...]` disk tag in `--list` output now shows the disk set from the latest checkpoint only, matching the VM's current configuration. Previously showed the union across all checkpoints, which could include disks no longer attached to the VM.

### Fixed

- **Point-in-time restore lost disks when VM configuration changed mid-chain** — `virtnbdrestore` always read the latest `vmconfig`, silently dropping disks that existed at the target checkpoint but not at the latest (e.g. a 3-disk VM at checkpoint 0 becomes 2 disks at checkpoint 3 — restoring to checkpoint 0 would only restore 2 disks). vmrestore now detects disk configuration changes and creates a lightweight staging directory (symlinks to `.data` files + the correct checkpoint's `vmconfig`) so `virtnbdrestore` sees only the right configuration. `predict_output_files()` also used the latest config, so clone staging would silently discard restored disks that weren't predicted — a data loss scenario. It now accepts a config override when PIT staging detects a change. Works across all restore modes: DR, clone, disk restore, and dry-run. Applies to both active and archived chains.

- **`--disk` fell through to full-VM restore on single-disk VMs** — When `--disk` was used on a VM with only one disk, vmrestore counted the available disks and, finding only one, silently switched to full-VM restore mode — undefining the VM from libvirt and attempting a DR reconstruct. Single-disk VMs now follow the same disk-restore code path as multi-disk VMs: in-place disk replacement with `.pre-restore` backup, no VM definition changes, no UUID/MAC changes. `--disk` without `--restore-point` now also fails with a clear error when the requested disk doesn't exist at the latest checkpoint, showing which checkpoint it was last seen at (previously fell through to `virtnbdrestore` with an opaque error).

## [0.5.1] - 2026-03-22

### Added

- **Multi-disk `--disk` support** — `--disk vda,vdb,sda` restores multiple disks in one pass. `--disk all` restores every disk. Each disk gets its own `.pre-restore` backup. Refuses if any `.pre-restore` file already exists.
- **`.pre-restore` overwrite protection** — if a `.pre-restore` backup file already exists for a disk, vmrestore refuses to proceed rather than silently overwriting. Prevents accidental loss of the safety net.
- **`--list-restore-points` shows all periods** — previously only showed the current (latest) retention policy period. Now iterates all period directories (newest first), each with its own section header, restore points, and archived chains.
- **`--list-restore-points` shows archived chain restore points** — archived chains are expanded inline showing their restore points, so users can see exactly what's available for `--restore-point` without manually inspecting `.archives/` directories.
- **`--list-restore-points` accepts full paths** — `--list-restore-points /path/to/.archives/chain-2026-03-04` now works like `--vm` does (splits into basename + dirname). Previously only accepted a VM name.
- **`--version` / `-V` flag** — prints version and exits.

### Changed

- **`--list` redesign** — VM name and size on own line (no column overflow for long names). Restore points summed across all periods (not just one). Type detected from the most recently modified period. Proper pluralisation ("1 point", "8 archives"). Multi-disk VMs show `[sda, vda, vdb]` disk tags. Archive count hidden when zero.
- **`Restore Point` column replaces `Checkpoint`** — the `--list-restore-points` output now shows a `Restore Point` column header with just the number (matching `--restore-point N`), date, and type. Internal checkpoint names (`virtnbdbackup.N`) removed — users don't interact with them.

### Fixed

- **Empty period skip** — `--list` and restore operations now skip empty period directories (created by rotation before the first backup runs). Previously, an empty newest period caused `--list` to show "unknown" type and restores to fail with "No backup data files".
- **Restore point numeric sort fix** — chains with 10+ restore points now display in correct numeric order. Previously used lexicographic glob ordering (0, 1, 10, 11, ..., 2) instead of (0, 1, 2, ..., 10, 11).

## [0.5] - 2026-03-14

### Added

- **`--disk` single-disk restore mode** — restore or replace a single disk from a multi-disk backup without touching the VM definition or other disks. Supports in-place replacement (`--disk vda`) and staging extract (`--disk vda --restore-path /tmp/extract`).
- **`.pre-restore` safety backup** — before in-place disk replacement, the original disk image is renamed to `.pre-restore` so the previous state is recoverable.
- **`--no-pre-restore` flag** — skip the `.pre-restore` safety backup when disk space is tight.

## [0.4] - 2026-03-10

### Added

- **Multi-disk VM support** — `enumerate_disks()` discovers all disks in a backup. Restore handles VMs with multiple virtual disks (vda, vdb, sda, etc.).
- **Pre-disk-restore baseline** — foundation for the `--disk` mode added in v0.5.
- **Test suite** — tests 1–12 covering DR, clone, point-in-time, verify, host-config, dry-run.
- **Packaging** — Makefile and debian/ packaging for `.deb` builds.

### Fixed

- **Bug fixes** — storage pool refresh fix, logging improvements, pre-flight safety check refinements.

## [0.3] - 2026-03-06

### Added

- **Disk collision protection** — predicts output file paths before restore and checks for conflicts. If target disk images already exist, restore is blocked with a clear error.
- **Staging directory** — clone restores write to a temporary staging directory, then move disks to the final location, preventing partial overwrites on failure.
- **Skip-config** — `--skip-config` skips VM definition and TPM restore (disk-only extract).
- **Post-restore integrity** — `qemu-img check` runs automatically after restore completes.
- **NVRAM isolation** — clone gets its own UEFI firmware state file.

## [0.2] - 2026-03-02

### Added

- **Clone mode (`--name`)** — creates an independent copy with new UUID, new MACs, and a new name. One flag transforms a DR restore into a clone.
- **TPM/BitLocker restore** — swtpm state directory is recreated at the correct UUID path for both DR and clone restores.
- **New-identity define** — strips UUID and MACs from domain XML, renames, defines as a new VM.

## [0.1] - 2026-02-20

### Added

- **Initial release** — wraps virtnbdrestore for single-command disaster recovery. Automatic backup type detection, period resolution, point-in-time restore via `--restore-point` and `--period`.
