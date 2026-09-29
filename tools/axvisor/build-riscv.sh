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
BUILD_STAGE=${AXVISOR_BUILD_STAGE:-all}
MODULE_BUILD_DIR="$BUILD_DIR/drivers/virt/axvisor"
HOST_OBJ="$MODULE_BUILD_DIR/axvisor_linux_host.o"
CORE_OBJ="$MODULE_BUILD_DIR/axvisor_linux_core.o"
CORE_LIB="$CARGO_TARGET_DIR/riscv64-linux-kernel/debug/libaxvisor_linux_core.a"
CORE_LINKER_SCRIPT="$LINUX_DIR/drivers/virt/axvisor/axvisor_module.lds"
RUST_STAMP_DIR="$BUILD_DIR/.axvisor-rust-stamps"

if [[ "$BUILD_STAGE" != "all" && "$BUILD_STAGE" != "module" && "$BUILD_STAGE" != "image" ]]; then
	echo "AXVISOR_BUILD_STAGE must be all, module, or image" >&2
	exit 2
fi

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

mkdir -p "$MODULE_BUILD_DIR"

if [[ -n "$AXVISOR_VM_CONFIGS" ]]; then
	export AXVISOR_VM_CONFIGS
	echo "Building with AxVisor VM configs: $AXVISOR_VM_CONFIGS"
fi

if [[ "$BUILD_STAGE" != "image" ]]; then
	cd "$RUST_DIR"

	# Cargo may consider a package fresh without recreating an explicitly named
	# --emit output. Track the identity so mode changes cannot reuse an object.
	mkdir -p "$RUST_STAMP_DIR"
	DEPENDENCY_OPT_LEVEL=${CARGO_PROFILE_DEV_OPT_LEVEL:-default}
	HOST_KEY="target=riscv64-linux-kernel;toolchain=$TOOLCHAIN;cargo_target=$CARGO_TARGET_DIR;dependency_opt=$DEPENDENCY_OPT_LEVEL;features=$HOST_FEATURES;flags=panic=abort,opt=2,reloc=static,code=medium"
	CORE_KEY="target=riscv64-linux-kernel;toolchain=$TOOLCHAIN;cargo_target=$CARGO_TARGET_DIR;dependency_opt=$DEPENDENCY_OPT_LEVEL;features=$CORE_FEATURES;flags=panic=abort,opt=2,reloc=static,code=medium,staticlib"
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

	cargo "+$TOOLCHAIN" rustc -Z json-target-spec \
		-Z build-std=core,alloc,compiler_builtins -p axvisor-linux-host \
		"${HOST_CARGO_FEATURES[@]}" --target targets/riscv64-linux-kernel.json -- \
		-C panic=abort -C opt-level=2 -C relocation-model=static \
		-C code-model=medium --emit=obj="$HOST_OBJ"
	if [[ "$FORCE_HOST" -eq 1 ]]; then printf '%s\n' "$HOST_KEY" > "$RUST_STAMP_DIR/host"; fi

	cargo "+$TOOLCHAIN" rustc -Z json-target-spec \
		-Z build-std=core,alloc,compiler_builtins -p axvisor-linux-core \
		"${CORE_CARGO_FEATURES[@]}" --target targets/riscv64-linux-kernel.json -- \
		-C panic=abort -C opt-level=2 -C relocation-model=static \
		-C code-model=medium --crate-type=staticlib
	if [[ "$FORCE_CORE" -eq 1 ]]; then printf '%s\n' "$CORE_KEY" > "$RUST_STAMP_DIR/core"; fi

	CORE_EXTRACT=$(mktemp -d)
	trap 'rm -rf "$CORE_EXTRACT"' EXIT
	(cd "$CORE_EXTRACT" && llvm-ar x "$CORE_LIB")
	NEW_CORE_OBJ="$CORE_EXTRACT/axvisor_linux_core.o"
	ld.lld -r -T "$CORE_LINKER_SCRIPT" -o "$NEW_CORE_OBJ" "$CORE_EXTRACT"/*.o
	llvm-objcopy \
		--redefine-sym _copy_to_user=__axvisor_rust_copy_to_user \
		--redefine-sym _copy_from_user=__axvisor_rust_copy_from_user \
		"$NEW_CORE_OBJ"
	if [[ ! -f "$CORE_OBJ" ]] || ! cmp -s "$NEW_CORE_OBJ" "$CORE_OBJ"; then
		cp "$NEW_CORE_OBJ" "$CORE_OBJ"
	fi
fi

CONFIG_STAMP="$BUILD_DIR/.axvisor-config.stamp"
LINUX_COMMIT=$(git -C "$LINUX_DIR" rev-parse HEAD)
CONFIG_KEY=$({
	printf 'linux=%s\ncore=%s\nhost=%s\n' \
		"$LINUX_COMMIT" "$CORE_FEATURES" "$HOST_FEATURES"
	sha256sum "$ROOT_DIR/build-riscv.sh"
} | sha256sum | cut -d' ' -f1)
if [[ ! -f "$BUILD_DIR/.config" || ! -f "$CONFIG_STAMP" || "$(cat "$CONFIG_STAMP")" != "$CONFIG_KEY" ]]; then
	make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" defconfig
	printf '%s\n' "$CONFIG_KEY" > "$CONFIG_STAMP"
else
	echo "Reusing RISC-V kernel configuration $CONFIG_KEY"
fi
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
	-e MODULES \
	-m AXVISOR_LINUX_BRIDGE \
	-e PRINTK \
	-e SERIAL_8250 \
	-e SERIAL_8250_CONSOLE \
	-e HVC_RISCV_SBI
if [[ "$BUILD_STAGE" != "module" && -n "${AXVISOR_INITRAMFS:-}" ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
		--set-str INITRAMFS_SOURCE "$AXVISOR_INITRAMFS"
elif [[ "$BUILD_STAGE" != "module" ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -d INITRAMFS_SOURCE
fi
if [[ ",${CORE_FEATURES}," == *,control,* ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -e AXVISOR_LINUX_CONTROL
else
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -d AXVISOR_LINUX_CONTROL
fi
if [[ ",${CORE_FEATURES}," == *,conformance-test,* ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -e AXVISOR_LINUX_CONFORMANCE
else
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -d AXVISOR_LINUX_CONFORMANCE
fi
make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" olddefconfig

# Kbuild does not reliably invalidate these C objects when the AxVisor mode
# toggles between static and control. Track that state explicitly so a mode
# switch cannot reuse a runtime object built without the control helpers.
C_CONFIG_STAMP="$BUILD_DIR/.axvisor-c-objects.stamp"
C_CONFIG_KEY="$CONFIG_KEY"
if [[ ! -f "$C_CONFIG_STAMP" || "$(cat "$C_CONFIG_STAMP")" != "$C_CONFIG_KEY" ]]; then
	rm -f "$BUILD_DIR/drivers/virt/axvisor/axvisor_module.o" \
		"$BUILD_DIR/drivers/virt/axvisor/axvisor_runtime.o" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_module.o.cmd" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_runtime.o.cmd"
fi
# Kbuild's generated initramfs archive does not always notice that
# INITRAMFS_SOURCE now points at a different case asset. Invalidate it when
# either the path or contents change, while retaining it for identical runs.
INITRAMFS_STAMP="$BUILD_DIR/.axvisor-initramfs.stamp"
INITRAMFS_KEY=
if [[ "$BUILD_STAGE" != "module" ]]; then
	if [[ -n "${AXVISOR_INITRAMFS:-}" ]]; then
		INITRAMFS_KEY=$({
			printf 'path=%s\n' "$AXVISOR_INITRAMFS"
			sha256sum "$AXVISOR_INITRAMFS"
		} | sha256sum | cut -d' ' -f1)
	else
		INITRAMFS_KEY=none
	fi
	if [[ ! -f "$INITRAMFS_STAMP" || "$(cat "$INITRAMFS_STAMP")" != "$INITRAMFS_KEY" ]]; then
		rm -f "$BUILD_DIR/usr/initramfs_data.cpio" \
			"$BUILD_DIR/usr/initramfs_data.o" \
			"$BUILD_DIR/usr/initramfs_inc_data" \
			"$BUILD_DIR/usr/.initramfs_data.cpio.cmd" \
			"$BUILD_DIR/usr/.initramfs_data.o.cmd" \
			"$BUILD_DIR/usr/.initramfs_inc_data.cmd"
	fi
fi
if grep -q '^CONFIG_KVM=y\|^CONFIG_KVM=m' "$BUILD_DIR/.config"; then
	echo "CONFIG_KVM must be disabled when AxVisor owns RISC-V virtualization" >&2
	exit 1
fi
if [[ "$BUILD_STAGE" == "module" && ! -f "$BUILD_DIR/Module.symvers" ]]; then
	echo "Bootstrapping the kernel symbol table for the first module build"
	make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" -j"$(nproc)" Image
fi
if [[ "$BUILD_STAGE" == "all" || "$BUILD_STAGE" == "image" ]]; then
	make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" -j"$(nproc)" Image
	if [[ -n "$INITRAMFS_KEY" ]]; then
		printf '%s\n' "$INITRAMFS_KEY" > "$INITRAMFS_STAMP"
	fi
fi
if [[ "$BUILD_STAGE" == "all" || "$BUILD_STAGE" == "module" ]]; then
	make -C "$LINUX_DIR" ARCH=riscv LLVM=1 O="$BUILD_DIR" -j"$(nproc)" \
		drivers/virt/axvisor/axvisor_linux.ko
fi
printf '%s\n' "$C_CONFIG_KEY" > "$C_CONFIG_STAMP"

if [[ "$BUILD_STAGE" == "all" || "$BUILD_STAGE" == "image" ]]; then
	echo "Built $BUILD_DIR/arch/riscv/boot/Image"
fi
if [[ "$BUILD_STAGE" == "all" || "$BUILD_STAGE" == "module" ]]; then
	echo "Built $BUILD_DIR/drivers/virt/axvisor/axvisor_linux.ko"
fi
