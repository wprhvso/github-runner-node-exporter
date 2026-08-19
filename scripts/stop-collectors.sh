#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${RUNNER_METRICS_ROOT:-}" ]; then exit 0; fi
root="$RUNNER_METRICS_ROOT"
agent_port="${RUNNER_METRICS_AGENT_PORT:-9099}"
flush_timeout="$(runner_metrics_bounded_int "${FLUSH_TIMEOUT:-30}" 30 600)"

if [ -n "${RUNNER_METRICS_AGENT_PID:-}" ]; then
  pending_timeout=$(( flush_timeout / 2 ))
  if [ "$pending_timeout" -lt 1 ]; then pending_timeout=1; fi
  for _ in $(seq 1 "$pending_timeout"); do
    pending="$(curl -fsS "http://127.0.0.1:$agent_port/metrics" 2>/dev/null \
      | runner_metrics_metric_sum /dev/stdin prometheus_remote_storage_samples_pending)"
    pending="$(printf '%.0f' "${pending:-0}" 2>/dev/null || printf '0')"
    if [ "$pending" -eq 0 ]; then break; fi
    sleep 1
  done
  kill -TERM "$RUNNER_METRICS_AGENT_PID" 2>/dev/null || true
  for _ in $(seq 1 "$flush_timeout"); do
    kill -0 "$RUNNER_METRICS_AGENT_PID" 2>/dev/null || break
    sleep 1
  done
  kill -KILL "$RUNNER_METRICS_AGENT_PID" 2>/dev/null || true
fi

if [ -n "${RUNNER_METRICS_NODE_EXPORTER_PID:-}" ]; then
  kill -TERM "$RUNNER_METRICS_NODE_EXPORTER_PID" 2>/dev/null || true
fi

if [ "${WRITE_REPORT:-true}" = "true" ]; then
  {
    echo
    echo "### node_exporter log"
    echo
    echo '```'
    tail -n 15 "$root/node_exporter.log" 2>/dev/null || echo "no log"
    echo '```'
    echo
    echo "### prometheus log"
    echo
    echo '```'
    tail -n 25 "$root/prometheus.log" 2>/dev/null || echo "no log"
    echo '```'
  } | tee -a "$root/report.md" >> "$GITHUB_STEP_SUMMARY"
fi

rm -f "$root/password" "$root/curlrc" "$root/agent.yml"
if [ "${CLEANUP:-true}" = "true" ]; then rm -rf "$root"; fi
