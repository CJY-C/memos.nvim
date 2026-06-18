#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${MEMOS_ENV_FILE:-}"
SLEEP_SECONDS="${MEMOS_COLD_TEST_SLEEP_SECONDS:-1800}"
RUNS="${MEMOS_COLD_TEST_RUNS:-1}"
PAGE_SIZE="${MEMOS_COLD_TEST_PAGE_SIZE:-50}"

ORDER_BYS=(
  "create_time desc"
  "update_time desc"
  "pinned desc, update_time desc"
)

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
    --sleep-seconds)
      if [[ $# -lt 2 ]]; then
        echo "error: --sleep-seconds requires a number" >&2
        exit 1
      fi
      SLEEP_SECONDS="$2"
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
      ORDER_BYS+=("$2")
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--env-file /path/to/memos.env] [--sleep-seconds N] [--runs N] [--page-size N] [--order-by VALUE]"
      echo
      echo "Runs list-only latency tests for each orderBy value, sleeping between tests"
      echo "so the server has time to cool down. Default sleep is 1800 seconds."
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

for index in "${!ORDER_BYS[@]}"; do
  order_by="${ORDER_BYS[$index]}"
  echo "==> cold orderBy test $((index + 1))/${#ORDER_BYS[@]}: ${order_by}"
  args=()
  if [[ -n "${ENV_FILE}" ]]; then
    args+=(--env-file "${ENV_FILE}")
  fi
  args+=(--skip-write --runs "${RUNS}" --page-size "${PAGE_SIZE}" --order-by "${order_by}")
  "${ROOT_DIR}/scripts/latency-test.sh" "${args[@]}"

  if [[ "$((index + 1))" -lt "${#ORDER_BYS[@]}" ]]; then
    echo "==> sleeping ${SLEEP_SECONDS}s before next orderBy test"
    sleep "${SLEEP_SECONDS}"
  fi
done
