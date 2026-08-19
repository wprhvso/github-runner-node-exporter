#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${RUNNER_METRICS_ROOT:-}" ]; then exit 0; fi
root="$RUNNER_METRICS_ROOT"
node_port="${RUNNER_METRICS_NODE_EXPORTER_PORT:-9100}"
agent_port="${RUNNER_METRICS_AGENT_PORT:-9099}"

rm -f "$root/textfile/step.prom"
sleep "$(runner_metrics_bounded_int "${DRAIN_SECONDS:-5}" 5 300)"

scrape() {
  local url="$1" out="$2"
  if curl -fsS --max-time 15 "$url" > "$out.tmp" 2>/dev/null; then
    mv "$out.tmp" "$out"
  else
    rm -f "$out.tmp"
    echo "::warning::could not scrape $url, the report will be incomplete"
  fi
}
scrape "http://127.0.0.1:$node_port/metrics" "$root/sample.prom"
scrape "http://127.0.0.1:$agent_port/metrics" "$root/agent.prom"
touch "$root/sample.prom" "$root/agent.prom"

sample="$root/sample.prom"
oom="$(runner_metrics_metric_sum "$sample" node_vmstat_oom_kill)"
oom="$(printf '%.0f' "${oom:-0}" 2>/dev/null || printf '0')"
cores="$(runner_metrics_cpu_cores "$sample")"
root_avail="$(runner_metrics_filesystem_avail "$sample" /)"
series="$(awk '$0 !~ /^[ \t]*#/ && $0 !~ /^[ \t]*$/ { n++ } END { print n + 0 }' "$sample" 2>/dev/null)"

if [ "${oom:-0}" -gt 0 ]; then
  echo "::warning::the kernel oom killer fired $oom time(s) on this runner"
fi

if [ "${WRITE_REPORT:-true}" != "true" ]; then exit 0; fi

{
  echo "## Runner metrics report"
  echo
  echo "remote write: ${RUNNER_METRICS_REMOTE_WRITE:-unknown}"
  echo
  echo "| Metric | Value |"
  echo "| --- | --- |"
  echo "| CPU cores | ${cores:-n/a} |"
  echo "| Memory total | $(runner_metrics_human "$(runner_metrics_metric_sum "$sample" node_memory_MemTotal_bytes)" gib) |"
  echo "| Memory available at the end | $(runner_metrics_human "$(runner_metrics_metric_sum "$sample" node_memory_MemAvailable_bytes)" gib) |"
  echo "| Swap free at the end | $(runner_metrics_human "$(runner_metrics_metric_sum "$sample" node_memory_SwapFree_bytes)" gib) |"
  echo "| Free space on / | $(runner_metrics_human "${root_avail:-}" gib) |"
  echo "| OOM kills | ${oom:-0} |"
  echo "| CPU pressure since boot | $(runner_metrics_human "$(runner_metrics_metric_sum "$sample" node_pressure_cpu_waiting_seconds_total)" s) |"
  echo "| Memory pressure since boot | $(runner_metrics_human "$(runner_metrics_metric_sum "$sample" node_pressure_memory_waiting_seconds_total)" s) |"
  echo "| IO pressure since boot | $(runner_metrics_human "$(runner_metrics_metric_sum "$sample" node_pressure_io_waiting_seconds_total)" s) |"
  echo "| Exposed series | ${series:-0} |"
} | tee "$root/report.md" >> "$GITHUB_STEP_SUMMARY"

if [ "${RUNNER_METRICS_REMOTE_WRITE:-}" = "enabled" ]; then
  {
    echo
    echo "### Remote storage"
    echo
    echo '```'
    grep -E '^prometheus_remote_storage_samples' "$root/agent.prom" 2>/dev/null | awk 'NR <= 20' || echo "no remote storage metrics"
    echo '```'
  } | tee -a "$root/report.md" >> "$GITHUB_STEP_SUMMARY"
fi
