#!/usr/bin/env bash
# Cross-compile a2hostd for the Smart Zynq (ARM, static binary).
#
#   boards/a2n20v2-SmartZynq/tools/build_a2hostd.sh
#
# Needs an arm-none-linux-gnueabihf (or arm-linux-gnueabihf) GCC. I use Arm's
# prebuilt "Arm GNU Toolchain 13.3.rel1, x86_64 host, AArch32 GNU/Linux target
# with hard float". Point A2ZYNQ_TOOLCHAIN at its bin/ directory, or have the
# compiler on your PATH. The binary is linked statically, so it runs on the
# old Ubuntu 16.04 userland in Xillinux without caring about its libc.
#
# Output: boards/a2n20v2-SmartZynq/build/a2hostd
# The build happens in a scratch copy, so no .o files land in the source tree.
set -euo pipefail
BOARD="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$BOARD/build"
mkdir -p "$OUT"

if [ -n "${A2ZYNQ_TOOLCHAIN:-}" ]; then
    export PATH="$A2ZYNQ_TOOLCHAIN:$PATH"
fi
PREFIX=""
for p in arm-none-linux-gnueabihf- arm-linux-gnueabihf-; do
    if command -v "${p}g++" >/dev/null 2>&1; then PREFIX="$p"; break; fi
done
if [ -z "$PREFIX" ]; then
    echo "No ARM cross compiler found. Install one (see docs/BUILDING.md) and" >&2
    echo "set A2ZYNQ_TOOLCHAIN=/path/to/toolchain/bin" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$BOARD/src/a2hostd/." "$WORK/"
make -C "$WORK" clean >/dev/null
make -C "$WORK" -j"$(nproc)" \
    CXX="${PREFIX}g++" CC="${PREFIX}gcc" \
    CXXFLAGS="-std=c++14 -O2 -Wall -Wextra -pthread -static"
"${PREFIX}strip" -o "$OUT/a2hostd" "$WORK/a2hostd"
file "$OUT/a2hostd" 2>/dev/null || true
md5sum "$OUT/a2hostd"
echo "a2hostd is in $OUT/a2hostd"
