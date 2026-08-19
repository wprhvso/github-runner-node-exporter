#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root="$RUNNER_METRICS_ROOT"
raw_url="${REMOTE_WRITE_URL:-}"
raw_username="${REMOTE_WRITE_USERNAME:-}"
raw_password="${REMOTE_WRITE_PASSWORD:-}"
url="$(runner_metrics_trim_space "$raw_url")"

if [ -z "$url" ]; then
  echo "remote write url is empty, metrics are collected locally only"
  echo "RUNNER_METRICS_REMOTE_WRITE=disabled" >> "$GITHUB_ENV"
  exit 0
fi

username="$(runner_metrics_trim_space "$raw_username")"
password="$(printf '%s' "$raw_password" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [ "${#url}" -ne "${#raw_url}" ]; then echo "::warning::remote write url contained whitespace"; fi
if [ "${#username}" -ne "${#raw_username}" ]; then echo "::warning::username contained whitespace"; fi
if [ "${#password}" -ne "${#raw_password}" ]; then echo "::warning::password had surrounding whitespace, it is trimmed the same way prometheus trims the password file"; fi

scrape_interval="$(runner_metrics_trim_space "${SCRAPE_INTERVAL:-5s}")"
if ! runner_metrics_valid_duration "$scrape_interval"; then
  echo "scrape-interval must be a prometheus duration such as 5s or 1m, got '${SCRAPE_INTERVAL:-}'" >&2
  exit 1
fi

case "$url" in
  https://*) ;;
  http://127.0.0.1* | http://localhost*) ;;
  *) echo "remote write url must use https" >&2; exit 1 ;;
esac

if [ -z "$password" ] && [ -n "$username" ]; then
  echo "username is set but password is empty" >&2
  exit 1
fi

name="$(runner_metrics_one_line "${JOB_NAME_OVERRIDE:-}")"
if [ -z "$name" ] && ! command -v jq > /dev/null 2>&1; then
  echo "::warning::jq is missing on this image, falling back to the job key"
elif [ -z "$name" ]; then
  page=1
  while [ "$page" -le 10 ]; do
    jobs_url="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs?per_page=100&page=$page"
    status="$(curl -sS -o "$root/jobs.json" -w '%{http_code}' \
      -H "Authorization: Bearer ${GH_TOKEN:-}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$jobs_url" || true)"
    if [ "$status" != "200" ]; then
      echo "::warning::workflow run jobs api answered http $status, add 'permissions: actions: read' to the workflow"
      break
    fi
    name="$(jq -r --arg runner "${RUNNER_NAME:-}" '
      first(.jobs[]? | select(.status == "in_progress" and .runner_name == $runner)) | .name // empty
    ' "$root/jobs.json" 2>/dev/null || true)"
    name="$(runner_metrics_one_line "$name")"
    if [ -n "$name" ]; then break; fi
    if [ "$(jq -r '.jobs | length' "$root/jobs.json" 2>/dev/null || echo 0)" -lt 100 ]; then
      echo "::warning::could not match this job by runner name ${RUNNER_NAME:-unset}"
      break
    fi
    page=$(( page + 1 ))
  done
  rm -f "$root/jobs.json"
fi
if [ -z "$name" ]; then name="${GITHUB_JOB:-github_runner}"; fi
echo "job name: $name"

umask 077
auth=()
if [ -n "$username" ]; then
  printf '%s' "$password" > "$root/password"
  printf 'user = "%s"\n' "$(runner_metrics_curl_escape "$username:$password")" > "$root/curlrc"
  auth=(-K "$root/curlrc")
fi

status="$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" \
  --retry 2 --retry-delay 1 --retry-connrefused \
  -H 'Content-Type: application/x-protobuf' \
  -H 'Content-Encoding: snappy' \
  -H 'X-Prometheus-Remote-Write-Version: 0.1.0' \
  --data-binary '' "$url" || true)"
rm -f "$root/curlrc"
echo "preflight http status: $status"

verdict="$(runner_metrics_preflight_verdict "$status")"
case "$verdict" in
  fail:*) echo "${verdict#fail:}" >&2; exit 1 ;;
  warn:*) echo "::warning::${verdict#warn:}" ;;
esac

JOB_NAME="$name" \
REMOTE_WRITE_URL="$url" \
REMOTE_WRITE_USERNAME="$username" \
PASSWORD_FILE="$root/password" \
SCRAPE_INTERVAL="$scrape_interval" \
NODE_EXPORTER_PORT="${RUNNER_METRICS_NODE_EXPORTER_PORT:-9100}" \
  runner_metrics_render_agent_config > "$root/agent.yml"

if "$root/bin/prometheus" --agent --help > /dev/null 2>&1; then
  agent_flag="--agent"
else
  agent_flag="--enable-feature=agent"
fi
echo "agent flag: $agent_flag"

if [ -n "${AGENT_PORT:-}" ]; then
  agent_port="$AGENT_PORT"
elif ! agent_port="$(runner_metrics_free_port 9090 9098)"; then
  echo "no free port for the prometheus agent between 9090 and 9098" >&2
  exit 1
fi
GOMAXPROCS=1 GOGC=50 nohup "$root/bin/prometheus" "$agent_flag" \
  --config.file="$root/agent.yml" \
  --storage.agent.path="$root/wal" \
  --web.listen-address="127.0.0.1:$agent_port" \
  > "$root/prometheus.log" 2>&1 &
pid=$!

{
  echo "RUNNER_METRICS_AGENT_PID=$pid"
  echo "RUNNER_METRICS_AGENT_PORT=$agent_port"
  echo "RUNNER_METRICS_JOB_NAME=$name"
  echo "RUNNER_METRICS_REMOTE_WRITE=enabled"
} >> "$GITHUB_ENV"

for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$agent_port/-/ready" \
    || curl -fsS -o /dev/null "http://127.0.0.1:$agent_port/metrics"; then exit 0; fi
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done

echo "prometheus agent did not become ready" >&2
tail -n 25 "$root/prometheus.log" >&2 || true
exit 1
