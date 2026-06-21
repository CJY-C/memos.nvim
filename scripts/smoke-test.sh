#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v nvim >/dev/null 2>&1; then
  echo "error: nvim is not installed or not in PATH" >&2
  exit 1
fi

echo "==> Running headless load check..."
nvim --headless -u NONE \
  -i NONE \
  "+set rtp^=${ROOT_DIR}" \
  "+lua require('memos').setup({})" \
  +qa

echo "==> Load check passed."

echo "==> Running automated unit tests via Plenary..."
nvim --headless -u NONE \
  -i NONE \
  "+set rtp^=${ROOT_DIR}" \
  -c "lua require('plenary.test_harness').test_directory('${ROOT_DIR}/tests')" \
  -c "qa!"

echo "==> Unit tests completed."
echo "Next manual checks in Neovim:"
echo "  :Memos"
echo "  :MemosCreate"
echo "  :MemosSave"
echo "  :MemosTemplate"
