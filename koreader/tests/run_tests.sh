#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOREADER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$KOREADER_DIR"

LUAJIT_BIN=""
for c in "${KOREADER_APP_DIR:-}/luajit" "/usr/lib/koreader/luajit" "/home/jimmy/squashfs-root/usr/lib/koreader/luajit" "$(which luajit 2>/dev/null || true)"; do
    if [ -x "$c" ]; then
        LUAJIT_BIN="$c"
        break
    fi
done

if [ -z "$LUAJIT_BIN" ]; then
    echo "Error: LuaJIT binary not found." >&2
    exit 1
fi

exec "$LUAJIT_BIN" "$SCRIPT_DIR/spec_runner.lua" "$@"
