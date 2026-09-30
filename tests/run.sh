#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Uses the actual sibling qbcore/qbsql code; no FiveM server or database.
"${LUA:-lua}" tests/purchase.lua "${1:-server/main.lua}"
"${LUA:-lua}" tests/shell_exit.lua "${2:-client/main.lua}"
