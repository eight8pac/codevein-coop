#!/bin/sh
# Builds CoopNative.asi with Zig's bundled clang (no Visual Studio needed). Usage: ZIG=/path/to/zig sh native/build.sh
set -e
cd "$(dirname "$0")"
M=third_party/minhook
mkdir -p build
"${ZIG:-zig}" cc -target x86_64-windows-gnu -O2 -shared -o build/CoopNative.asi coopnative.c \
  $M/src/buffer.c $M/src/hook.c $M/src/trampoline.c $M/src/hde/hde64.c -I$M/include -lshell32 -lole32
echo "built native/build/CoopNative.asi"
