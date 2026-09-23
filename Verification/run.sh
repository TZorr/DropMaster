#!/bin/bash
#
# Verification/run.sh
# DropMaster
#
# Builds and runs the verification harness against the engine - everything
# in DropMaster/Engine, globbed rather than listed, so a new file can never
# make the harness fail to link for a reason unrelated to the change. The
# UI and the app model stay out: whatever needs checking is decided in the
# engine.
#
# libmp3lame is C, so it is compiled with clang into objects first (once;
# an object is rebuilt only when its source is newer), with the same
# defines as the app target, and the Swift side sees it through the app's
# own bridging header.
#
# Usage: Verification/run.sh [-O]      (-O: optimised, as the Release app)
#

set -euo pipefail
cd "$(dirname "$0")/.."

OPT="-Onone"
[[ "${1:-}" == "-O" ]] && OPT="-O"

OUT="${TMPDIR:-/tmp}/dropmaster_harness"
LAME="DropMaster/LAME"
OBJECTS="$OUT.lame"
mkdir -p "$OBJECTS"
for source in "$LAME"/*.c; do
    object="$OBJECTS/$(basename "$source" .c).o"
    if [[ ! "$object" -nt "$source" || "$LAME/config.h" -nt "$object" ]]; then
        clang -c -O2 -w -arch arm64 -DHAVE_CONFIG_H=1 -I"$LAME" -I"$LAME/vector" -o "$object" "$source"
    fi
done

SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done \
    < <(find DropMaster/Engine -name '*.swift' -print0 | sort -z)

swiftc $OPT -default-isolation MainActor -swift-version 5 \
    -import-objc-header DropMaster/DropMaster-Bridging-Header.h -Xcc -I"$LAME" \
    -o "$OUT" Verification/main.swift "${SOURCES[@]}" "$OBJECTS"/*.o
"$OUT"
