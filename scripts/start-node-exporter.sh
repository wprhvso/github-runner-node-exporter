#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root="$RUNNER_METRICS_ROOT"
if [ -n "${NODE_EXPORTER_PORT:-}" ]; then
  port="$NODE_EXPORTER_PORT"
elif ! port="$(runner_metrics_free_port 9100 9199)"; then
  echo "no free port for node_exporter between 9100 and 9199" >&2
  exit 1
fi

GOMAXPROCS=1 GOGC=50 nohup "$root/bin/node_exporter" \
  --web.listen-address="127.0.0.1:$port" \
  --web.disable-exporter-metrics \
  --collector.disable-defaults \
  --collector.cpu \
  --collector.meminfo \
  --collector.vmstat \
  --collector.loadavg \
  --collector.diskstats \
  --collector.netdev \
  --collector.netdev.device-exclude='^(lo|veth.*|tap.*)$' \
  --collector.filesystem \
  --collector.filesystem.mount-points-exclude='^/(dev|proc|run|sys|var/lib/docker/.+|var/lib/containers/.+)($|/)' \
  --collector.pressure \
  --collector.textfile \
  --collector.textfile.directory="$root/textfile" \
  > "$root/node_exporter.log" 2>&1 &
pid=$!

echo "RUNNER_METRICS_NODE_EXPORTER_PID=$pid" >> "$GITHUB_ENV"
echo "RUNNER_METRICS_NODE_EXPORTER_PORT=$port" >> "$GITHUB_ENV"

for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/metrics"; then exit 0; fi
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done

echo "node_exporter did not answer on 127.0.0.1:$port" >&2
tail -n 20 "$root/node_exporter.log" >&2 || true
exit 1
