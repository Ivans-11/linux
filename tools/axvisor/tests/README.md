# AxVisor Linux tests

The test tree separates outer host settings from guest case definitions:

- `hosts/` describes the outer Linux-host/QEMU environment;
- `cases/` describes one static, control, provider, or benchmark case;
- `assets.toml` is the single immutable asset catalog. It maps guest image
  archives, downloads, pinned source builds, and Nix-built host trees to
  labels and default staging targets;
- `.work/cases/` contains staged case payloads; `.work/logs/` contains case logs and statuses.

Case manifests deliberately keep workload parameters and guest operations in the
case. `test_files` entries are source/target pairs for files compiled into the
host initramfs; the generic initramfs builder does not have a registry of named
tests. The runner performs only the common staging/build/launch/interaction
flow, applies the declared timeout and result markers, and records the case
log. It must not contain Firecracker-, lkvm-, or gVisor-specific branches.

An initramfs cache key includes the architecture, builder, init source, and all
test-source hashes. Replacing a test source therefore cannot silently reuse an
old image from `.work/`. External binaries and complete base initramfs images
must be declared by an immutable catalog entry before a case is executable;
they are never taken from another host checkout or an arbitrary pre-existing
`.work` file.

Asset entries use three generic backends: `download` verifies a URL with a
  SHA-256 checksum, `source-build` uses either a pinned Git revision or a
  checksummed source archive and runs the recipe named by the entry, and `nix`
  evaluates a pinned expression under `tests/assets/nix/`. A Nix asset may be a
  directory rather than a single file; this is how the lkvm host tree carries
  its dynamic loader and complete runtime closure. The resolver records the
  resolved source/recipe identity in `.work/assets/`, so a changed recipe cannot
  silently reuse an old artifact. To populate the RISC-V host asset explicitly:

```sh
./build-assets.py --arch riscv64 --asset host-initramfs-riscv64
```

The active manifests cover four RISC-V cases (static Linux, control smoke,
control lkvm-Linux, and control Firecracker-Linux) and four x86_64 cases
(static Linux, control smoke, control Firecracker-Linux, and control
gVisor-KVM).

The manifests record each case's workload semantics independently of the
architecture-specific launch backend. The official Firecracker benchmark
series is outside this scope. A case is marked `active` only after its payload
assets and launch path are reproducibly wired into the runner; unfinished cases
remain `planned` in the development worktree.

Case manifests are versioned together with this repository; no external host
checkout is required to interpret or execute them. A case may declare
`payload_assets` (copied into the guest payload) and
`host_initramfs_assets` (copied into the AxVisor host initramfs). Both use the
same catalog and resolver, so adding a Firecracker, gVisor or QEMU asset only
requires a new catalog entry and, for source builds, a recipe script.
