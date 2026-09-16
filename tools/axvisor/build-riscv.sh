#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
LINUX_DIR=${LINUX_DIR:-"$(cd "$ROOT_DIR/../.." && pwd)"}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/.work/build-riscv"}
RUST_DIR="$LINUX_DIR/drivers/virt/axvisor/rust"
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT_DIR/target"}
export CARGO_TARGET_DIR
TOOLCHAIN=${RUSTUP_TOOLCHAIN:-nightly-2026-05-28}
AXVISOR_VM_CONFIGS=${AXVISOR_VM_CONFIGS:-}
HOST_OBJ="$LINUX_DIR/drivers/virt/axvisor/axvisor_linux_host.o"
CORE_OBJ="$LINUX_DIR/drivers/virt/axvisor/axvisor_linux_core.o"
CORE_LIB="$CARGO_TARGET_DIR/riscv64-linux-kernel/debug/libaxvisor_linux_core.a"
RUST_STAMP_DIR="$BUILD_DIR/.axvisor-rust-stamps"

# Keep the default RISC-V static build equivalent to the historical path while
# allowing control/shell variants to be selected without editing Cargo files.
CORE_FEATURES=${AXVISOR_CORE_FEATURES:-sstc}
HOST_FEATURES=${AXVISOR_HOST_FEATURES:-}
CORE_CARGO_FEATURES=()
HOST_CARGO_FEATURES=()
if [[ -n "$CORE_FEATURES" ]]; then
	CORE_CARGO_FEATURES+=(--features "$CORE_FEATURES")
fi
if [[ -n "$HOST_FEATURES" ]]; then
	HOST_CARGO_FEATURES+=(--features "$HOST_FEATURES")
fi

mkdir -p "$BUILD_DIR"

if [[ -n "$AXVISOR_VM_CONFIGS" ]]; then
	export AXVISOR_VM_CONFIGS
	echo "Building with AxVisor VM configs: $AXVISOR_VM_CONFIGS"
fi

cd "$RUST_DIR"

# Cargo may consider a package fresh without recreating an explicitly named
# --emit output.  Track the build identity as well, so switching between
# static/control features cannot reuse an object from the other mode.
mkdir -p "$RUST_STAMP_DIR"
HOST_KEY="target=riscv64-linux-kernel;toolchain=$TOOLCHAIN;features=$HOST_FEATURES;flags=panic=abort,opt=2,reloc=static,code=medium"
CORE_KEY="target=riscv64-linux-kernel;toolchain=$TOOLCHAIN;features=$CORE_FEATURES;flags=panic=abort,opt=2,reloc=static,code=medium,staticlib"
FORCE_HOST=0
FORCE_CORE=0
if [[ ! -f "$HOST_OBJ" || ! -f "$RUST_STAMP_DIR/host" || "$(cat "$RUST_STAMP_DIR/host")" != "$HOST_KEY" ]]; then
	touch "$RUST_DIR/axvisor-linux-host/src/lib.rs"
	FORCE_HOST=1
fi
if [[ ! -f "$CORE_LIB" || ! -f "$RUST_STAMP_DIR/core" || "$(cat "$RUST_STAMP_DIR/core")" != "$CORE_KEY" ]]; then
	touch "$RUST_DIR/axvisor-linux-core/src/lib.rs"
	FORCE_CORE=1
fi

cargo "+$TOOLCHAIN" rustc \
	-Z json-target-spec \
	-Z build-std=core,alloc,compiler_builtins \
	-p axvisor-linux-host \
	"${HOST_CARGO_FEATURES[@]}" \
	--target targets/riscv64-linux-kernel.json \
	-- \
	-C panic=abort \
	-C opt-level=2 \
	-C relocation-model=static \
	-C code-model=medium \
	--emit=obj="$HOST_OBJ"
if [[ "$FORCE_HOST" -eq 1 ]]; then printf '%s\n' "$HOST_KEY" > "$RUST_STAMP_DIR/host"; fi

cargo "+$TOOLCHAIN" rustc \
	-Z json-target-spec \
	-Z build-std=core,alloc,compiler_builtins \
	-p axvisor-linux-core \
	"${CORE_CARGO_FEATURES[@]}" \
	--target targets/riscv64-linux-kernel.json \
	-- \
	-C panic=abort \
	-C opt-level=2 \
	-C relocation-model=static \
	-C code-model=medium \
	--crate-type=staticlib
if [[ "$FORCE_CORE" -eq 1 ]]; then printf '%s\n' "$CORE_KEY" > "$RUST_STAMP_DIR/core"; fi

CORE_EXTRACT=$(mktemp -d)
trap 'rm -rf "$CORE_EXTRACT"' EXIT
(cd "$CORE_EXTRACT" && llvm-ar x "$CORE_LIB")
ld.lld -r -o "$CORE_OBJ" "$CORE_EXTRACT"/*.o
# Zerocopy's RISC-V implementation emits generic helper names that collide
# with Linux's usercopy symbols.  They are private to the Rust object and can
# be renamed without changing the AxVisor API.
llvm-objcopy \
	--redefine-sym _copy_to_user=__axvisor_rust_copy_to_user \
	--redefine-sym _copy_from_user=__axvisor_rust_copy_from_user \
	"$CORE_OBJ"

# Kbuild resolves prebuilt members in the out-of-tree object directory.
mkdir -p "$BUILD_DIR/drivers/virt/axvisor"
# Install prebuilt members without touching mtimes when their contents are
# unchanged.  Invalidate the composite only when a member really changed.
PREBUILT_CHANGED=0
for pair in \
	"$HOST_OBJ:$BUILD_DIR/drivers/virt/axvisor/axvisor_linux_host.o" \
	"$CORE_OBJ:$BUILD_DIR/drivers/virt/axvisor/axvisor_linux_core.o"; do
	source=${pair%%:*}
	destination=${pair#*:}
	if [[ ! -f "$destination" ]] || ! cmp -s "$source" "$destination"; then
		cp "$source" "$destination"
		PREBUILT_CHANGED=1
	fi
done
if [[ "$PREBUILT_CHANGED" -eq 1 ]]; then
	# The composite Kbuild object may otherwise remain fresh after replacing
	# prebuilt members, leaving newly exported C ABI symbols unresolved.
	rm -f "$BUILD_DIR/drivers/virt/axvisor/axvisor_linux.o" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_linux.o.cmd"
fi

make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" defconfig
"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
	-d KVM \
	--set-val THREAD_SIZE_ORDER 4 \
	-e CMA \
	-e DMA_CMA \
	-e VIRT_DRIVERS \
	-e BLK_DEV_INITRD \
	-e DEVTMPFS \
	-e DEVTMPFS_MOUNT \
	-e EXT2_FS \
	-e TUN \
	-e AXVISOR_LINUX_BRIDGE \
	-e PRINTK \
	-e SERIAL_8250 \
	-e SERIAL_8250_CONSOLE \
	-e HVC_RISCV_SBI
if [[ -n "${AXVISOR_INITRAMFS:-}" ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
		--set-str INITRAMFS_SOURCE "$AXVISOR_INITRAMFS"
else
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -d INITRAMFS_SOURCE
fi
if [[ ",${CORE_FEATURES}," == *,control,* ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -e AXVISOR_LINUX_CONTROL
else
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -d AXVISOR_LINUX_CONTROL
fi
make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" olddefconfig

# Kbuild does not reliably invalidate these C objects when the AxVisor mode
# toggles between static and control. Track that state explicitly so a mode
# switch cannot reuse a runtime object built without the control helpers.
C_CONFIG_STAMP="$BUILD_DIR/.axvisor-c-objects.stamp"
C_CONFIG_KEY=$({
	printf 'linux=%s\ninitramfs=%s\ncore=%s\nhost=%s\n' \
		"$(git -C "$LINUX_DIR" rev-parse HEAD)" "${AXVISOR_INITRAMFS:-}" \
		"$CORE_FEATURES" "$HOST_FEATURES"
	sha256sum "$ROOT_DIR/build-riscv.sh"
} | sha256sum | cut -d' ' -f1)
if [[ ! -f "$C_CONFIG_STAMP" || "$(cat "$C_CONFIG_STAMP")" != "$C_CONFIG_KEY" ]]; then
	rm -f "$BUILD_DIR/drivers/virt/axvisor/axvisor_module.o" \
		"$BUILD_DIR/drivers/virt/axvisor/axvisor_runtime.o" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_module.o.cmd" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_runtime.o.cmd"
fi
# Kbuild's generated initramfs archive does not always notice that
# INITRAMFS_SOURCE now points at a different case asset.  Remove the
# generated archive before the final kernel build so a previous case's
# initramfs cannot be silently reused.
if [[ -n "${AXVISOR_INITRAMFS:-}" ]]; then
	rm -f "$BUILD_DIR/usr/initramfs_data.cpio" \
		"$BUILD_DIR/usr/initramfs_data.o" \
		"$BUILD_DIR/usr/initramfs_inc_data" \
		"$BUILD_DIR/usr/.initramfs_data.cpio.cmd" \
		"$BUILD_DIR/usr/.initramfs_data.o.cmd" \
		"$BUILD_DIR/usr/.initramfs_inc_data.cmd"
fi
# Materialize the final linker script before applying the Rust section/symbol
# aliases; the Image target may regenerate it if it does not exist yet.
make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" arch/riscv/kernel/vmlinux.lds

# ax-percpu and zerocopy use the freestanding linker symbol spelling.  Linux
# exposes the same regions as __per_cpu_* / __start___ex_table; add aliases to
# the generated RISC-V linker script after configuration is finalized.
python3 - "$BUILD_DIR/arch/riscv/kernel/vmlinux.lds" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
aliases = (
    " _percpu_start = __per_cpu_start;"
    " _percpu_end = __per_cpu_end;"
    " _percpu_load_start = __per_cpu_load;"
    " _percpu_load_end = __per_cpu_end;"
    " _ex_table_start = __start___ex_table;"
    " _ex_table_end = __stop___ex_table;"
)
if "_percpu_start = __per_cpu_start" not in s or "_ex_table_start = __start___ex_table" not in s:
    # The generated script is frequently emitted as one long line, and the
    # section closing text varies with kernel configuration.  Insert aliases
    # immediately before /DISCARD/, which is stable across those variants.
    marker = " /DISCARD/ :"
    if marker not in s:
        raise SystemExit("cannot locate stable linker-script insertion point")
    s = s.replace(marker, aliases + marker, 1)
# Rust's `ax_percpu::def_percpu` emits a `.percpu` input section. Fold it into
# Linux's canonical per-CPU output section so the provider's template and
# offsets are covered by `__per_cpu_load`/`__per_cpu_end`.
if "*(.percpu)" not in s:
    s = s.replace(
        "*(.data..percpu) *(.data..percpu..shared_aligned)",
        "*(.data..percpu) *(.percpu) *(.data..percpu..shared_aligned)",
        1,
    )
# Rust objects are emitted into many `.text.<crate>` orphan sections.  Linux's
# generated script otherwise places those orphans between `.exit.text` and
# `__init_end`, where initmem cleanup poisons them after boot.  Pull all Rust
# text sections into the permanent kernel `.text` output explicitly.
if "*(.text.axvisor* .text._R* .text.__AxVisorApi*)" not in s:
    s = s.replace(
        "  _etext = .;",
        "  *(.text.axvisor* .text._R* .text.__AxVisorApi*)\n  _etext = .;",
        1,
    )
p.write_text(s)
PY

if grep -q '^CONFIG_KVM=y\|^CONFIG_KVM=m' "$BUILD_DIR/.config"; then
	echo "CONFIG_KVM must be disabled when AxVisor owns RISC-V virtualization" >&2
	exit 1
fi
make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" -j"$(nproc)" Image
printf '%s\n' "$C_CONFIG_KEY" > "$C_CONFIG_STAMP"

echo "Built $BUILD_DIR/arch/riscv/boot/Image"
