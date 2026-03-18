# vmrestore — Changelog

## 0.5.1

- **`--list` redesign** — VM name and size on own line (no column overflow for long names). Restore points summed across all periods (not just one). Type detected from the most recently modified period. Proper pluralisation ("1 point", "8 archives"). Multi-disk VMs show `[sda, vda, vdb]` disk tags. Archive count hidden when zero.
- **Empty period skip** — `--list` and restore operations now skip empty period directories (created by rotation before the first backup runs). Previously, an empty newest period caused `--list` to show "unknown" type and restores to fail with "No backup data files".
- **`--list-restore-points` shows all periods** — previously only showed the current (latest) retention policy period. Now iterates all period directories (newest first), each with its own section header, restore points, and archived chains.
- **`--list-restore-points` shows archived chain restore points** — archived chains are expanded inline showing their restore points, so users can see exactly what's available for `--restore-point` without manually inspecting `.archives/` directories.
- **`Restore Point` column replaces `Checkpoint`** — the `--list-restore-points` output now shows a `Restore Point` column header with just the number (matching `--restore-point N`), date, and type. Internal checkpoint names (`virtnbdbackup.N`) removed — users don't interact with them.
- **Multi-disk `--disk` support** — `--disk vda,vdb,sda` restores multiple disks in one pass. `--disk all` restores every disk. Each disk gets its own `.pre-restore` backup. Refuses if any `.pre-restore` file already exists.
- **`.pre-restore` overwrite protection** — if a `.pre-restore` backup file already exists for a disk, vmrestore refuses to proceed rather than silently overwriting. Prevents accidental loss of the safety net.
- **`--list-restore-points` accepts full paths** — `--list-restore-points /path/to/.archives/chain-2026-03-04` now works like `--vm` does (splits into basename + dirname). Previously only accepted a VM name.
- **Restore point numeric sort fix** — chains with 10+ restore points now display in correct numeric order. Previously used lexicographic glob ordering (0, 1, 10, 11, ..., 2) instead of (0, 1, 2, ..., 10, 11).
- **`--version` / `-V` flag** — prints version and exits.
- **Documentation update**

## 0.5

- **`--disk` single-disk restore mode** — restore or replace a single disk from a multi-disk backup without touching the VM definition or other disks. Supports in-place replacement (`--disk vda`) and staging extract (`--disk vda --restore-path /tmp/extract`).
- **`.pre-restore` safety backup** — before in-place disk replacement, the original disk image is renamed to `.pre-restore` so the previous state is recoverable.
- **`--no-pre-restore` flag** — skip the `.pre-restore` safety backup when disk space is tight.

## 0.4

- **Multi-disk VM support** — `enumerate_disks()` discovers all disks in a backup. Restore handles VMs with multiple virtual disks (vda, vdb, sda, etc.).
- **Pre-disk-restore baseline** — foundation for the `--disk` mode added in v0.5.
- **Bug fixes** — storage pool refresh fix, logging improvements, pre-flight safety check refinements.
- **Test suite** — tests 1–12 covering DR, clone, point-in-time, verify, host-config, dry-run.
- **Packaging** — Makefile and debian/ packaging for `.deb` builds.

## 0.3

- **Disk collision protection** — predicts output file paths before restore and checks for conflicts. If target disk images already exist, restore is blocked with a clear error.
- **Staging directory** — clone restores write to a temporary staging directory, then move disks to the final location, preventing partial overwrites on failure.
- **Skip-config** — `--skip-config` skips VM definition and TPM restore (disk-only extract).
- **Post-restore integrity** — `qemu-img check` runs automatically after restore completes.
- **NVRAM isolation** — clone gets its own UEFI firmware state file.

## 0.2

- **Clone mode (`--name`)** — creates an independent copy with new UUID, new MACs, and a new name. One flag transforms a DR restore into a clone.
- **TPM/BitLocker restore** — swtpm state directory is recreated at the correct UUID path for both DR and clone restores.
- **New-identity define** — strips UUID and MACs from domain XML, renames, defines as a new VM.

## 0.1

- **Initial release** — wraps virtnbdrestore for single-command disaster recovery. Automatic backup type detection, period resolution, point-in-time restore via `--restore-point` and `--period`.
