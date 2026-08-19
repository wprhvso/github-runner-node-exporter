#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root="${RUNNER_METRICS_ROOT:-$RUNNER_TEMP/runner-metrics}"
mkdir -p "$root/bin" "$root/textfile" "$root/wal"

machine="$(uname -m)"
if ! arch="$(runner_metrics_arch "$machine")"; then
  echo "unsupported architecture $machine" >&2
  exit 1
fi

url="$(runner_metrics_trim_space "${REMOTE_WRITE_URL:-}")"

fetch() { curl -fsSL --retry 3 --retry-delay 2 "$@"; }
api() { fetch -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

resolve() {
  local repo="$1" tag
  if [ "${GITHUB_API_URL:-https://api.github.com}" = "https://api.github.com" ] && [ -n "${GH_TOKEN:-}" ]; then
    tag="$(api -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$repo/releases/latest" | runner_metrics_release_tag)"
  else
    tag="$(api "https://api.github.com/repos/$repo/releases/latest" | runner_metrics_release_tag)"
  fi
  if ! runner_metrics_valid_version "$tag"; then
    echo "could not resolve the latest release of $repo" >&2
    return 1
  fi
  printf '%s' "$tag"
}

install_release() {
  local repo="$1" name="$2" version="$3"
  fetch "https://github.com/prometheus/$repo/releases/download/v${version}/${name}-${version}.linux-${arch}.tar.gz" \
    | tar -xz -C "$root/bin" --strip-components=1 "${name}-${version}.linux-${arch}/${name}"
  [ -x "$root/bin/$name" ]
}

node_exporter_version="${NODE_EXPORTER_VERSION:-latest}"
prometheus_version="${PROMETHEUS_VERSION:-latest}"

if [ "$node_exporter_version" = latest ]; then
  node_exporter_version="$(resolve prometheus/node_exporter)"
elif ! runner_metrics_valid_version "$node_exporter_version"; then
  echo "node-exporter-version must be a version without the leading v, or latest" >&2
  exit 1
fi

install_release node_exporter node_exporter "$node_exporter_version" &
node_exporter_pid=$!

prometheus_pid=""
if [ -n "$url" ]; then
  if [ "$prometheus_version" = latest ]; then
    prometheus_version="$(resolve prometheus/prometheus)"
  elif ! runner_metrics_valid_version "$prometheus_version"; then
    echo "prometheus-version must be a version without the leading v, or latest" >&2
    exit 1
  fi
  install_release prometheus prometheus "$prometheus_version" &
  prometheus_pid=$!
  echo "node_exporter $node_exporter_version, prometheus $prometheus_version, arch $arch"
else
  echo "node_exporter $node_exporter_version, arch $arch, prometheus skipped"
fi

status=0
wait "$node_exporter_pid" || status=1
if [ -n "$prometheus_pid" ]; then wait "$prometheus_pid" || status=1; fi
if [ "$status" -ne 0 ]; then
  echo "downloading the collectors failed" >&2
  exit 1
fi

{
  echo "RUNNER_METRICS_ROOT=$root"
  echo "RUNNER_METRICS_TEXTFILE_DIR=$root/textfile"
} >> "$GITHUB_ENV"
