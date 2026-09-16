#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
ARCH=${1:-}
TESTS=${2:-}
INIT_SOURCE=${3:-}
ASSETS=${4:-}
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/.work/assets/initramfs"}

if [[ "$ARCH" != "riscv64" && "$ARCH" != "x86_64" ]]; then
	echo "usage: $0 riscv64|x86_64 source:target[,source:target...] [init-source] [asset:target,...]" >&2
	exit 2
fi

case "$ARCH" in
	riscv64) TARGET="riscv64-unknown-linux-gnu" ;;
	x86_64) TARGET="x86_64-unknown-linux-gnu" ;;
esac

CC=${CC:-clang}
COMMON=(-target "$TARGET" -fuse-ld=lld -Wall -Werror -ffreestanding -fno-stack-protector
	-nostdlib -static -Wl,--build-id=none)
if [[ "$ARCH" == "riscv64" ]]; then
	# Match the baseline rv64gc ISA exposed by QEMU; newer compressed-byte
	# instructions (Zcb) are not available on all of the supported machines.
	COMMON+=( -march=rv64imafdc -mabi=lp64d )
fi
BUILD_DIR="$ROOT_DIR/.work/test-programs/$ARCH"
TREE="$BUILD_DIR/tree"

if [[ -n "$INIT_SOURCE" ]]; then
	INIT_SOURCE_PATH="$ROOT_DIR/$INIT_SOURCE"
elif [[ -n "$TESTS" ]]; then
	INIT_SOURCE_PATH="$ROOT_DIR/tests/programs/init.c"
else
	INIT_SOURCE_PATH="$ROOT_DIR/tests/programs/host_init.c"
fi

if [[ ! -f "$INIT_SOURCE_PATH" ]]; then
	echo "init source does not exist: $INIT_SOURCE_PATH" >&2
	exit 1
fi

IFS=',' read -r -a asset_specs <<< "$ASSETS"
for spec in "${asset_specs[@]}"; do
	[[ -n "$spec" ]] || continue
	if [[ "$spec" != *:* ]]; then
		echo "invalid asset specification (expected source:target): $spec" >&2
		exit 1
	fi
	source=${spec%%:*}
	target=${spec#*:}
	target_path="$TREE/${target#/}"
	if [[ "$target_path" == *".."* ]]; then
		echo "invalid asset target: $target" >&2
		exit 1
	fi
	if [[ ! -e "$source" ]]; then
		echo "asset source does not exist: $source" >&2
		exit 1
	fi
done

IFS=',' read -r -a specs <<< "$TESTS"
for spec in "${specs[@]}"; do
	[[ -n "$spec" ]] || continue
	if [[ "$spec" != *:* ]]; then
		echo "invalid test file specification (expected source:target): $spec" >&2
		exit 1
	fi
	source=${spec%%:*}
	target=${spec#*:}
	source_path="$ROOT_DIR/$source"
	target_path="$TREE/${target#/}"
	if [[ ! -f "$source_path" ]]; then
		echo "test source does not exist: $source_path" >&2
		exit 1
	fi
done

# Include every input and this builder in the cache key.  A source replacement
# must never silently reuse an initramfs produced from an older file.
digest_input=$(mktemp)
trap 'rm -f "$digest_input"' EXIT
printf 'arch=%s\ntests=%s\ninit=%s\n' "$ARCH" "$TESTS" "$INIT_SOURCE_PATH" > "$digest_input"
printf 'assets=%s\n' "$ASSETS" >> "$digest_input"
sha256sum "$INIT_SOURCE_PATH" "$ROOT_DIR/build-test-initramfs.sh" >> "$digest_input"
for spec in "${specs[@]}"; do
	[[ -n "$spec" ]] || continue
	source=${spec%%:*}
	sha256sum "$ROOT_DIR/$source" >> "$digest_input"
done
for spec in "${asset_specs[@]}"; do
	[[ -n "$spec" ]] || continue
	source=${spec%%:*}
	if [[ -d "$source" ]]; then
		find "$source" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >> "$digest_input"
	else
		sha256sum "$source" >> "$digest_input"
	fi
done
digest=$(sha256sum "$digest_input" | cut -d' ' -f1)
raw="$OUT_DIR/$ARCH-$digest.cpio"
image="$raw.gz"

# Compute the key before creating the disposable staging tree.  This makes
# repeated runs reuse the exact initramfs instead of recompiling init and
# repacking the same files every time.
if [[ -f "$image" ]]; then
	printf '%s\n' "$image"
	exit 0
fi

mkdir -p "$BUILD_DIR" "$OUT_DIR"
if [[ -d "$TREE" ]]; then
	# Nix closure entries originate in the read-only /nix/store.  The staged
	# copy is disposable, so make it writable before replacing it on rebuild.
	chmod -R u+w "$TREE" 2>/dev/null || true
fi
rm -rf "$TREE"
mkdir -p "$TREE/dev" "$TREE/proc" "$TREE/sys" "$TREE/tmp" "$TREE/test"

if [[ "$INIT_SOURCE_PATH" == *.c ]]; then
	"$CC" "${COMMON[@]}" "$INIT_SOURCE_PATH" -o "$TREE/init"
else
	cp "$INIT_SOURCE_PATH" "$TREE/init"
fi
chmod 0755 "$TREE/init"

for spec in "${asset_specs[@]}"; do
	[[ -n "$spec" ]] || continue
	source=${spec%%:*}
	target=${spec#*:}
	target_path="$TREE/${target#/}"
	if [[ -d "$source" ]]; then
		mkdir -p "$target_path"
		cp -a "$source"/. "$target_path"/
		# Nix store trees are read-only.  The staging tree is disposable and
		# may receive case test binaries after assets are copied.
		chmod -R u+w "$target_path" 2>/dev/null || true
	else
		mkdir -p "$(dirname "$target_path")"
		cp "$source" "$target_path"
		chmod 0755 "$target_path"
	fi
done

for spec in "${specs[@]}"; do
	[[ -n "$spec" ]] || continue
	source=${spec%%:*}
	target=${spec#*:}
	source_path="$ROOT_DIR/$source"
	target_path="$TREE/${target#/}"
	mkdir -p "$(dirname "$target_path")"
	"$CC" "${COMMON[@]}" "$source_path" -o "$target_path"
	chmod 0755 "$target_path"
done

(cd "$TREE" && find . -print | LC_ALL=C sort | cpio -o -H newc > "$raw")
gzip -n -c "$raw" > "$image"
rm -f "$raw"
printf '%s\n' "$image"
