#!/usr/bin/env bash
# Все проверки проекта одной командой (Linux/macOS/Git Bash):
#   ./scripts/check.sh
# Переменная API_DUMP=/путь/к/API-Dump.json включает проверку свойств по API Roblox.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== stylua";   stylua --check src tests scripts
echo "== selene";   selene src
echo "== tests";    lune run tests/run.luau
echo "== build";    mkdir -p build && rojo build -o build/game.rbxl
echo "== place";    lune run scripts/validate_place.luau build/game.rbxl
echo "== engine sim (server)"
lune run tests/engine/server_sim.luau build/game.rbxl 2>&1 | tee build/server_sim.log | grep -E "✓|✗|failures"
if grep -q "Stack Begin" build/server_sim.log; then echo "uncaught errors in server_sim"; exit 1; fi
echo "== engine sim (client)"
lune run tests/engine/client_sim.luau build/game.rbxl 2>&1 | tee build/client_sim.log | grep -E "✓|✗|failures"
if grep -q "Stack Begin" build/client_sim.log; then echo "uncaught errors in client_sim"; exit 1; fi
if [[ -n "${API_DUMP:-}" ]]; then
	echo "== api";  python3 scripts/check_api.py "$API_DUMP"
fi
echo "ALL CHECKS PASSED"
