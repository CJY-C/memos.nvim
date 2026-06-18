#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${MEMOS_ENV_FILE:-}"
RUNS="${MEMOS_LATENCY_RUNS:-}"
PAGE_SIZE="${MEMOS_LATENCY_PAGE_SIZE:-}"
ORDER_BY="${MEMOS_LATENCY_ORDER_BY:-}"
SKIP_WRITE="${MEMOS_LATENCY_SKIP_WRITE:-}"
WARMUP="${MEMOS_LATENCY_WARMUP:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        echo "error: --env-file requires a path" >&2
        exit 1
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    --runs)
      if [[ $# -lt 2 ]]; then
        echo "error: --runs requires a number" >&2
        exit 1
      fi
      RUNS="$2"
      shift 2
      ;;
    --page-size)
      if [[ $# -lt 2 ]]; then
        echo "error: --page-size requires a number" >&2
        exit 1
      fi
      PAGE_SIZE="$2"
      shift 2
      ;;
    --order-by)
      if [[ $# -lt 2 ]]; then
        echo "error: --order-by requires a value" >&2
        exit 1
      fi
      ORDER_BY="$2"
      shift 2
      ;;
    --skip-write)
      SKIP_WRITE="1"
      shift
      ;;
    --warmup)
      WARMUP="1"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [--env-file /path/to/memos.env] [--runs N] [--page-size N] [--order-by VALUE] [--skip-write] [--warmup]"
      echo
      echo "Credentials can come from saved memos.nvim accounts, MEMOS_HOST/MEMOS_TOKEN,"
      echo "or a systemd EnvironmentFile passed with --env-file or MEMOS_ENV_FILE."
      echo
      echo "Options:"
      echo "  --runs N        run the benchmark N times"
      echo "  --page-size N   list N memos per request"
      echo "  --order-by V    override list orderBy, for example 'create_time desc'"
      echo "  --skip-write    only test list requests"
      echo "  --warmup        run a lightweight auth request before measuring"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v nvim >/dev/null 2>&1; then
  echo "error: nvim is not installed or not in PATH" >&2
  exit 1
fi

if [[ -n "${ENV_FILE}" ]]; then
  export MEMOS_ENV_FILE="${ENV_FILE}"
fi
if [[ -n "${RUNS}" ]]; then
  export MEMOS_LATENCY_RUNS="${RUNS}"
fi
if [[ -n "${PAGE_SIZE}" ]]; then
  export MEMOS_LATENCY_PAGE_SIZE="${PAGE_SIZE}"
fi
if [[ -n "${ORDER_BY}" ]]; then
  export MEMOS_LATENCY_ORDER_BY="${ORDER_BY}"
fi
if [[ -n "${SKIP_WRITE}" ]]; then
  export MEMOS_LATENCY_SKIP_WRITE="${SKIP_WRITE}"
fi
if [[ -n "${WARMUP}" ]]; then
  export MEMOS_LATENCY_WARMUP="${WARMUP}"
fi

nvim --headless -u NONE \
  -i NONE \
  "+set rtp+=${ROOT_DIR}" \
  "+lua local env_file = os.getenv('MEMOS_ENV_FILE'); require('memos').setup({ env_file = env_file })" \
  "+lua require('memos.latency').run({})" \
  +qa
