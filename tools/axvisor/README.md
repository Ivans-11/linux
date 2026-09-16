# AxVisor on Linux

This Linux branch hosts the Linux provider for the AxVisor crates in
`tgoskits`. The provider source is integrated directly into
`drivers/virt/axvisor`; generated build outputs remain outside version control.

Run the commands below from `tools/axvisor`.

The Linux provider implements all current
`axvisor_api` traits and the build links the pinned `axvisor_core` into the
kernel image. `ax-percpu` uses its external-base backend so Linux keeps
ownership of its architecture thread-pointer registers. Memory operations are
backed by Linux page allocators and address translation.
`TaskIf::spawn_task_raw` dispatches through a Linux kthread, with completion
objects for `join_task` and single-CPU affinity support. Wait-queue operations
use generation-based wakeups and remain a lightweight bring-up implementation.
On RISC-V, the provider snapshots Linux's boot FDT address during initcall so
AxVisor can generate a guest FDT, and translates non-RAM physical addresses
through cached `ioremap` mappings (the direct map is used only for RAM).

## RISC-V validation

Prerequisites are Clang/LLD, make, a Rust toolchain with `rust-src` for the
repository-local `lp64` target, and `qemu-system-riscv64`.

```sh
./build-host.sh --arch riscv64
./run-case.sh --case riscv64-static-linux
```

Static guest VM configurations are supplied by the selected case manifest.
The case runner stages the case's `vm.toml` and passes it to the host build;
no repository-level absolute path or separate architecture-specific config is
required.

The host kernel is intentionally built with `CONFIG_KVM=n`.  AxVisor and
native Linux KVM must not own the same RISC-V H-extension state concurrently;
the control-mode provider will expose `/dev/kvm` only when native KVM is absent.

The static-guest path has been exercised through guest Linux kernel startup,
including virtual PLIC/timer handling. Passing a host virtio device through to
the guest requires an identity-mapped guest RAM region (`MapIdentical`) so the
device's DMA addresses match the host physical addresses. With that mapping,
the RISC-V guest successfully mounted the 32 MiB ext4 rootfs and entered
`/bin/sh`; an allocated-but-relocated RAM region cannot be used for DMA
passthrough.

The bridge uses a repository-local RISC-V target specification with `lp64`
(soft-float) ABI to match Linux's RISC-V kernel objects. It intentionally does
not enable floating-point ISA extensions.

The AxVisor crates are obtained from the `axvisor-core` branch of the
`Ivans-11/tgoskits` Git repository, as declared in their `Cargo.toml` files.
`Cargo.lock` records the exact resolved revision and avoids a separate
source-mode switch.

## Reproducible sources and tests

The host source is this Linux tree, based on the upstream Linux v6.12 commit
`adc218676eef25575469234709c2d87185ca223a`. The AxVisor driver and required
architecture integration are versioned directly in the same branch.

Firecracker, lkvm, gVisor, guest kernels, initramfs files, and rootfs images are
test payloads, not host source dependencies. They must be resolved by the
selected case's payload/image declarations and the shared asset catalog
(`tests/assets.toml`), then cached under `.work/`; the host build does
not fetch them. A case that still relies on a locally generated initramfs is
kept `planned` rather than silently reading another host checkout or a stale
`.work` image.

Declarative cases live in `tests/cases`, while the outer host-QEMU settings live
in `tests/hosts`. List and inspect cases with:

```sh
./run-case.sh --list
./run-case.sh --case riscv64-static-linux --dry-run
```

The KVM smoke program is checked into `tests/programs/kvm_smoke.c` and is
copied byte-for-byte from the upstream test definition. Its case declares the
source/target pair, and the generic runner builds it, along with the tiny
repository-owned init process, into a minimal initramfs. The generated image is
cached below `.work/assets/` and is never committed. The lkvm case declares a
Nix-built host asset tree containing lkvm, BusyBox, and its runtime closure,
plus a shell initramfs; the same mechanism
can add Firecracker, gVisor or QEMU binaries without adding tool-specific
branches to the runner.

The cases currently checked in and validated are:

- RISC-V static Linux;
- RISC-V control smoke;
- RISC-V control lkvm-Linux;
- RISC-V control Firecracker-Linux;
- x86_64 static Linux;
- x86_64 control smoke;
- x86_64 control Firecracker-Linux;
- x86_64 control gVisor-KVM.

The runner builds the host when needed, drives the declared
serial interactions, stops at the first success or failure marker, and writes
the case log and status under `.work/logs/`.

For x86_64 cases, the runner selects VMX or SVM from `/proc/cpuinfo`. The
selection can be forced for cross-builds and targeted regression runs:

```sh
AXVISOR_X86_ACCEL=vmx ./run-case.sh --case x86_64-control-smoke
AXVISOR_X86_ACCEL=svm ./run-case.sh --case x86_64-control-smoke
```

`AXVISOR_X86_ACCEL` accepts `auto` (the default), `vmx`, or `svm`. A forced
backend that conflicts with `AXVISOR_CORE_FEATURES` is rejected.

The common build entry point selects only the architecture:

```sh
./build-host.sh --arch riscv64
./build-host.sh --arch x86_64
```
