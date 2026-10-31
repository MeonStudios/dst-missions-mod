#!/usr/bin/env sh
# Render the mission card states without launching DST.
# Override the interpreter with LUA=... if it is not in the default location.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
LUA="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"

"$LUA" "$DIR/dump.lua"
python "$DIR/render.py" "$@"
echo "Previews: $DIR/out/"
