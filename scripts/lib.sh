#!/usr/bin/env bash

LC_ALL=C
export LC_ALL

runner_metrics_trim_space() {
  printf '%s' "$1" | tr -d '[:space:]'
}

runner_metrics_one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   '
}

runner_metrics_yaml_escape() {
  runner_metrics_one_line "$1" | sed "s/'/''/g"
}

runner_metrics_curl_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

runner_metrics_label_escape() {
  runner_metrics_one_line "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

runner_metrics_arch() {
  case "$1" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

runner_metrics_is_positive_int() {
  case "$1" in
    "" | *[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

runner_metrics_bounded_int() {
  local value="$1" fallback="$2" max="$3"
  case "$value" in
    "" | *[!0-9]*) printf '%s' "$fallback"; return 0 ;;
  esac
  value="$((value + 0))"
  if [ "$value" -gt "$max" ]; then value="$max"; fi
  printf '%s' "$value"
}

runner_metrics_awk_parser() {
  cat <<'AWK'
    function prom_name(line,   brace, space, cut) {
      brace = index(line, "{")
      space = index(line, " ")
      cut = brace
      if (cut == 0 || (space > 0 && space < cut)) cut = space
      if (cut == 0) return line
      return substr(line, 1, cut - 1)
    }
    function prom_labels(line,   from, to, i) {
      from = index(line, "{")
      if (from == 0) return ""
      to = 0
      for (i = length(line); i > from; i--) {
        if (substr(line, i, 1) == "}") { to = i; break }
      }
      if (to == 0) return ""
      return substr(line, from + 1, to - from - 1)
    }
    function prom_value(line,   fields, parts) {
      fields = split(line, parts, " ")
      if (fields < 2) return ""
      return parts[fields]
    }
    function prom_label(labels, key,   pattern, start, rest, out, c, escaped, i) {
      pattern = key "=\""
      start = index(labels, pattern)
      if (start == 0) return ""
      rest = substr(labels, start + length(pattern))
      out = ""
      escaped = 0
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (escaped) { out = out c; escaped = 0; continue }
        if (c == "\\") { escaped = 1; continue }
        if (c == "\"") break
        out = out c
      }
      return out
    }
AWK
}

runner_metrics_metric_sum() {
  local file="$1" name="$2"
  [ -r "$file" ] || return 0
  awk -v name="$name" "$(runner_metrics_awk_parser)"'
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    prom_name($0) == name { v += prom_value($0) + 0; n++ }
    END { if (n) printf "%.6f", v }
  ' "$file"
}

runner_metrics_cpu_cores() {
  local file="$1"
  [ -r "$file" ] || { printf '0'; return 0; }
  awk "$(runner_metrics_awk_parser)"'
    /^[ \t]*#/ { next }
    prom_name($0) == "node_cpu_seconds_total" {
      cpu = prom_label(prom_labels($0), "cpu")
      if (cpu != "" && !(cpu in seen)) { seen[cpu] = 1; n++ }
    }
    END { printf "%d", n + 0 }
  ' "$file"
}

runner_metrics_filesystem_avail() {
  local file="$1" mountpoint="${2:-/}"
  [ -r "$file" ] || return 0
  awk -v want="$mountpoint" "$(runner_metrics_awk_parser)"'
    /^[ \t]*#/ { next }
    prom_name($0) == "node_filesystem_avail_bytes" {
      if (prom_label(prom_labels($0), "mountpoint") == want) { printf "%.0f", prom_value($0) + 0; exit }
    }
  ' "$file"
}

runner_metrics_human() {
  awk -v v="$1" -v unit="$2" 'BEGIN {
    if (v == "") { print "n/a"; exit }
    if (unit == "gib") { printf "%.2f GiB\n", v / 1073741824; exit }
    printf "%.1f s\n", v
  }'
}

runner_metrics_render_agent_config() {
  esc() { runner_metrics_yaml_escape "$1"; }
  cat <<EOF
global:
  scrape_interval: '$(esc "$SCRAPE_INTERVAL")'
  external_labels:
    gha_repository: '$(esc "${GITHUB_REPOSITORY:-}")'
    gha_workflow: '$(esc "${GITHUB_WORKFLOW:-}")'
    gha_job: '$(esc "${GITHUB_JOB:-}")'
    gha_job_name: '$(esc "${JOB_NAME:-}")'
    gha_run_id: '$(esc "${GITHUB_RUN_ID:-}")'
    gha_run_number: '$(esc "${GITHUB_RUN_NUMBER:-}")'
    gha_run_attempt: '$(esc "${GITHUB_RUN_ATTEMPT:-}")'
    gha_ref_name: '$(esc "${GITHUB_REF_NAME:-}")'
    gha_runner_os: '$(esc "${RUNNER_OS:-}")'
    gha_runner_arch: '$(esc "${RUNNER_ARCH:-}")'
scrape_configs:
  - job_name: github_runner
    static_configs:
      - targets: ["127.0.0.1:${NODE_EXPORTER_PORT:-9100}"]
        labels:
          instance: '$(esc "${GITHUB_WORKFLOW:-}/${JOB_NAME:-}#${GITHUB_RUN_NUMBER:-}.${GITHUB_RUN_ATTEMPT:-}")'
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_cpu_seconds_total|node_memory_(MemTotal|MemAvailable|MemFree|Cached|Buffers|SwapTotal|SwapFree)_bytes|node_load(1|5)|node_vmstat_(oom_kill|pgmajfault|pswpin|pswpout)|node_disk_(read|written)_bytes_total|node_disk_io_time_seconds_total|node_network_(receive|transmit)_bytes_total|node_filesystem_(avail|size)_bytes|node_pressure_(cpu|io|memory)_(waiting|stalled)_seconds_total|gha_.*'
        action: keep
      - source_labels: [__name__, mode]
        regex: 'node_cpu_seconds_total;(guest|guest_nice|irq|nice|softirq)'
        action: drop
remote_write:
  - url: '$(esc "$REMOTE_WRITE_URL")'
    basic_auth:
      username: '$(esc "$REMOTE_WRITE_USERNAME")'
      password_file: '$(esc "$PASSWORD_FILE")'
    metadata_config:
      send: false
    queue_config:
      max_shards: 1
      batch_send_deadline: 5s
      min_backoff: 250ms
      max_backoff: 5s
EOF
}

runner_metrics_valid_version() {
  case "$1" in
    "" | v*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$'
}

runner_metrics_release_tag() {
  grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 \
    | sed 's/.*"\([^"]*\)"$/\1/; s/^v//'
}

runner_metrics_valid_duration() {
  printf '%s' "$1" | grep -Eq '^([0-9]+(ms|s|m|h|d|w|y))+$'
}

runner_metrics_preflight_verdict() {
  case "$1" in
    401 | 403) printf 'fail:endpoint rejected the basic auth credentials with http %s' "$1" ;;
    404) printf 'warn:endpoint answered http 404, check that the url ends with /api/v1/write' ;;
    5??) printf 'warn:endpoint answered http %s, check the receiver and its auth file' "$1" ;;
    000 | "") printf 'warn:endpoint did not answer the preflight request' ;;
    *) printf 'ok:' ;;
  esac
}
