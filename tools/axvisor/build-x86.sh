#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
LINUX_DIR=${LINUX_DIR:-"$(cd "$ROOT_DIR/../.." && pwd)"}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/.work/build-x86"}
BUILD_DIR=$(realpath -m "$BUILD_DIR")
RUST_DIR="$LINUX_DIR/drivers/virt/axvisor/rust"
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT_DIR/target"}
export CARGO_TARGET_DIR
TOOLCHAIN=${RUSTUP_TOOLCHAIN:-nightly-2026-05-28}
AXVISOR_VM_CONFIGS=${AXVISOR_VM_CONFIGS:-}
CORE_FEATURES=${AXVISOR_CORE_FEATURES:-vmx}
HOST_FEATURES=${AXVISOR_HOST_FEATURES:-}
HOST_OBJ="$LINUX_DIR/drivers/virt/axvisor/axvisor_linux_host.o"
CORE_OBJ="$LINUX_DIR/drivers/virt/axvisor/axvisor_linux_core.o"
CORE_LIB="$CARGO_TARGET_DIR/x86_64-linux-kernel/debug/libaxvisor_linux_core.a"
RUST_STAMP_DIR="$BUILD_DIR/.axvisor-rust-stamps"

find_llvm_tool() {
	local tool=$1
	if command -v "$tool" >/dev/null 2>&1; then
		command -v "$tool"
	elif command -v "$tool-18" >/dev/null 2>&1; then
		command -v "$tool-18"
	else
		echo "missing LLVM tool: $tool (or $tool-18)" >&2
		return 1
	fi
}

if command -v clang >/dev/null 2>&1 && \
   command -v llvm-ar >/dev/null 2>&1 && \
   command -v llvm-nm >/dev/null 2>&1 && \
   command -v llvm-objcopy >/dev/null 2>&1; then
	KBUILD_LLVM=1
elif command -v clang-18 >/dev/null 2>&1; then
	KBUILD_LLVM=-18
else
	echo "missing Clang compiler" >&2
	exit 1
fi
LLVM_AR=$(find_llvm_tool llvm-ar)
LLVM_LD=$(find_llvm_tool ld.lld)

CORE_CARGO_FEATURES=()
HOST_CARGO_FEATURES=()
if [[ -n "$CORE_FEATURES" ]]; then
	CORE_CARGO_FEATURES+=(--features "$CORE_FEATURES")
fi
if [[ -n "$HOST_FEATURES" ]]; then
	HOST_CARGO_FEATURES+=(--features "$HOST_FEATURES")
fi

mkdir -p "$BUILD_DIR/drivers/virt/axvisor"

if [[ -n "$AXVISOR_VM_CONFIGS" ]]; then
	export AXVISOR_VM_CONFIGS
	echo "Building with AxVisor VM configs: $AXVISOR_VM_CONFIGS"
fi

cd "$RUST_DIR"

# Cargo may consider a package fresh without recreating an explicitly named
# --emit output. Track the build identity as well, so switching between
# static/control features cannot reuse an object from the other mode.
mkdir -p "$RUST_STAMP_DIR"
HOST_KEY="target=x86_64-linux-kernel;toolchain=$TOOLCHAIN;features=$HOST_FEATURES;flags=panic=abort,opt=2,reloc=static,code=kernel"
CORE_KEY="target=x86_64-linux-kernel;toolchain=$TOOLCHAIN;features=$CORE_FEATURES;flags=panic=abort,opt=2,reloc=static,code=kernel,staticlib"
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
	--target targets/x86_64-linux-kernel.json \
	-- \
	-C panic=abort \
	-C opt-level=2 \
	-C relocation-model=static \
	-C code-model=kernel \
	--emit=obj="$HOST_OBJ"
if [[ "$FORCE_HOST" -eq 1 ]]; then printf '%s\n' "$HOST_KEY" > "$RUST_STAMP_DIR/host"; fi

cargo "+$TOOLCHAIN" rustc \
	-Z json-target-spec \
	-Z build-std=core,alloc,compiler_builtins \
	-p axvisor-linux-core \
	"${CORE_CARGO_FEATURES[@]}" \
	--target targets/x86_64-linux-kernel.json \
	-- \
	-C panic=abort \
	-C opt-level=2 \
	-C relocation-model=static \
	-C code-model=kernel \
	--crate-type=staticlib
if [[ "$FORCE_CORE" -eq 1 ]]; then printf '%s\n' "$CORE_KEY" > "$RUST_STAMP_DIR/core"; fi

CORE_EXTRACT=$(mktemp -d)
trap 'rm -rf "$CORE_EXTRACT"' EXIT
(cd "$CORE_EXTRACT" && "$LLVM_AR" x "$CORE_LIB")
"$LLVM_LD" -r -o "$CORE_OBJ" "$CORE_EXTRACT"/*.o

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
	rm -f "$BUILD_DIR/drivers/virt/axvisor/axvisor_linux.o" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_linux.o.cmd"
fi

CONFIG_STAMP="$BUILD_DIR/.axvisor-config.stamp"
LINUX_COMMIT=$(git -C "$LINUX_DIR" rev-parse HEAD)
CONFIG_KEY=$({
	printf 'linux=%s\ninitramfs=%s\ncore=%s\nhost=%s\n' \
		"$LINUX_COMMIT" "${AXVISOR_INITRAMFS:-}" "$CORE_FEATURES" "$HOST_FEATURES"
	sha256sum "$ROOT_DIR/build-x86.sh"
} | sha256sum | cut -d' ' -f1)
if [[ ! -f "$BUILD_DIR/.config" || ! -f "$CONFIG_STAMP" || "$(cat "$CONFIG_STAMP")" != "$CONFIG_KEY" ]]; then
        make -C "$LINUX_DIR" LLVM="$KBUILD_LLVM" O="$BUILD_DIR" x86_64_defconfig
        printf '%s\n' "$CONFIG_KEY" > "$CONFIG_STAMP"
else
        echo "Reusing x86 kernel configuration $CONFIG_KEY"
fi

# Enforce the case-independent options on every invocation. This is cheap,
# keeps cached configurations equivalent to a fresh defconfig path, and
# prevents stale settings such as CONFIG_WERROR from turning warnings into
# errors.
"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
	-d KVM -e CMA -e DMA_CMA -e VIRT_DRIVERS -e AXVISOR_LINUX_BRIDGE \
	-d VIRTIO_BLK -d VIRTIO_NET \
	-e PRINTK -e SERIAL_8250 -e SERIAL_8250_CONSOLE -e BLK_DEV_INITRD \
	-e DEVTMPFS -e DEVTMPFS_MOUNT -e EXT2_FS -e TUN -d DEBUG_INFO -d WERROR
if [[ -n "${AXVISOR_INITRAMFS:-}" ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
		--set-str INITRAMFS_SOURCE "$AXVISOR_INITRAMFS"
else
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" -d INITRAMFS_SOURCE
fi
if [[ ",${CORE_FEATURES}," == *,control,* ]]; then
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
		-e AXVISOR_LINUX_CONTROL -e VIRTIO_BLK
else
	"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
		-d AXVISOR_LINUX_CONTROL -d VIRTIO_BLK
fi

# Always refresh generated Kconfig files.  This is non-interactive and cheap,
# while avoiding stale auto.conf state when the cached configuration is reused.
make -C "$LINUX_DIR" LLVM="$KBUILD_LLVM" O="$BUILD_DIR" olddefconfig

# Kbuild does not reliably invalidate these C objects when the AxVisor mode
# toggles between static and control. Track that state explicitly so a mode
# switch cannot reuse a runtime object built without the control helpers.
C_CONFIG_STAMP="$BUILD_DIR/.axvisor-c-objects.stamp"
C_CONFIG_KEY="$CONFIG_KEY"
C_OBJECTS_STALE=0
if [[ ! -f "$C_CONFIG_STAMP" || "$(cat "$C_CONFIG_STAMP")" != "$C_CONFIG_KEY" ]]; then
	C_OBJECTS_STALE=1
	rm -f "$BUILD_DIR/drivers/virt/axvisor/axvisor_module.o" \
		"$BUILD_DIR/drivers/virt/axvisor/axvisor_runtime.o" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_module.o.cmd" \
		"$BUILD_DIR/drivers/virt/axvisor/.axvisor_runtime.o.cmd"
fi

if grep -q '^CONFIG_KVM=y\|^CONFIG_KVM=m' "$BUILD_DIR/.config"; then
	echo "CONFIG_KVM must be disabled when AxVisor owns hardware virtualization" >&2
	exit 1
fi
make -C "$LINUX_DIR" LLVM="$KBUILD_LLVM" O="$BUILD_DIR" \
	-j"$(nproc)" bzImage
printf '%s\n' "$C_CONFIG_KEY" > "$C_CONFIG_STAMP"

echo "Built $BUILD_DIR/arch/x86/boot/bzImage"
