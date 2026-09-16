#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
ARCH=""
cd "$ROOT_DIR"

usage() {
	echo "usage: $0 --arch riscv64|x86_64" >&2
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--arch)
			[[ $# -ge 2 ]] || { usage; exit 2; }
			ARCH=$2
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "unknown argument: $1" >&2
			usage
			exit 2
			;;
	esac
done

case "$ARCH" in
	riscv64|x86_64) ;;
	*) echo "--arch must be riscv64 or x86_64" >&2; exit 2 ;;
esac

case "$ARCH" in
	riscv64) exec "$ROOT_DIR/build-riscv.sh" ;;
	x86_64) exec "$ROOT_DIR/build-x86.sh" ;;
esac
