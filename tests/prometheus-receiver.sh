#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

root="${PROMETHEUS_RECEIVER_ROOT:-$RUNNER_TEMP/prometheus-receiver}"
mkdir -p "$root/bin" "$root/data"

machine="$(uname -m)"
arch="$(runner_metrics_arch "$machine")"

version="${PROMETHEUS_VERSION:-}"
if [ -z "$version" ]; then
  version="$(curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/prometheus/prometheus/releases/latest | runner_metrics_release_tag)"
fi
runner_metrics_valid_version "$version"

curl -fsSL --retry 3 "https://github.com/prometheus/prometheus/releases/download/v${version}/prometheus-${version}.linux-${arch}.tar.gz" \
  | tar -xz -C "$root/bin" --strip-components=1 "prometheus-${version}.linux-${arch}/prometheus"

port="$(runner_metrics_free_port 19400 19499)"
cat > "$root/prometheus.yml" <<EOF
global:
  scrape_interval: 60s
EOF

nohup "$root/bin/prometheus" \
  --config.file="$root/prometheus.yml" \
  --storage.tsdb.path="$root/data" \
  --storage.tsdb.retention.time=1h \
  --web.enable-remote-write-receiver \
  --web.listen-address="127.0.0.1:$port" \
  > "$root/prometheus.log" 2>&1 &

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/-/ready"; then
    {
      echo "PROMETHEUS_RECEIVER_PID=$!"
      echo "PROMETHEUS_RECEIVER_BASE=http://127.0.0.1:$port"
      echo "PROMETHEUS_RECEIVER_URL=http://127.0.0.1:$port/api/v1/write"
    } >> "$GITHUB_ENV"
    echo "prometheus $version listening on 127.0.0.1:$port"
    exit 0
  fi
  sleep 1
done

echo "the prometheus receiver did not become ready" >&2
tail -n 25 "$root/prometheus.log" >&2 || true
exit 1
