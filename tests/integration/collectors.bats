#!/usr/bin/env bats

setup_file() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export SCRIPTS="$REPO_ROOT/scripts"
  export RUNNER_METRICS_ROOT="$BATS_FILE_TMPDIR/root"
  export GITHUB_ENV="$BATS_FILE_TMPDIR/env"
  : > "$GITHUB_ENV"

  RUNNER_TEMP="$BATS_FILE_TMPDIR" REMOTE_WRITE_URL=https://example.test/api/v1/write \
    bash "$SCRIPTS/install-collectors.sh"

  export NODE_EXPORTER_PORT=19100
  export RUNNER_METRICS_TEXTFILE_DIR="$RUNNER_METRICS_ROOT/textfile"
  bash "$SCRIPTS/start-node-exporter.sh"
  export NODE_EXPORTER_PID="$(awk -F= '/^RUNNER_METRICS_NODE_EXPORTER_PID=/ { print $2 }' "$GITHUB_ENV")"
}

teardown_file() {
  [ -n "${NODE_EXPORTER_PID:-}" ] && kill "$NODE_EXPORTER_PID" 2>/dev/null
  pkill -f "$BATS_FILE_TMPDIR" 2>/dev/null
  return 0
}

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export SCRIPTS="$REPO_ROOT/scripts"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  : > "$GITHUB_ENV"
  : > "$GITHUB_STEP_SUMMARY"
}

start_receiver() {
  local port="$1" status="${2:-204}" user="${3:-metrics}" password="${4:-s3cr3t}"
  RECEIVER_STATE="$BATS_TEST_TMPDIR/receiver.json"
  python3 "$BATS_TEST_DIRNAME/receiver.py" --port "$port" --user "$user" \
    --password "$password" --status "$status" --state "$RECEIVER_STATE" &
  RECEIVER_PID=$!
  for _ in $(seq 1 50); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/" && return 0
    sleep 0.2
  done
  return 1
}

stop_receiver() {
  [ -n "${RECEIVER_PID:-}" ] && kill "$RECEIVER_PID" 2>/dev/null
  return 0
}

receiver_field() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$RECEIVER_STATE" "$1"
}

@test "both collectors are downloaded and executable" {
  [ -x "$RUNNER_METRICS_ROOT/bin/node_exporter" ]
  [ -x "$RUNNER_METRICS_ROOT/bin/prometheus" ]
  "$RUNNER_METRICS_ROOT/bin/node_exporter" --version
  "$RUNNER_METRICS_ROOT/bin/prometheus" --version
}

@test "node exporter exposes every metric family the report and the relabel rules need" {
  curl -fsS "http://127.0.0.1:$NODE_EXPORTER_PORT/metrics" > "$BATS_TEST_TMPDIR/scrape.prom"
  for name in node_cpu_seconds_total node_memory_MemTotal_bytes node_memory_MemAvailable_bytes \
    node_load1 node_vmstat_oom_kill node_disk_read_bytes_total node_network_receive_bytes_total \
    node_filesystem_avail_bytes; do
    grep -q "^$name" "$BATS_TEST_TMPDIR/scrape.prom" || {
      echo "missing $name"
      return 1
    }
  done
}

@test "node exporter does not expose its own runtime metrics" {
  curl -fsS "http://127.0.0.1:$NODE_EXPORTER_PORT/metrics" > "$BATS_TEST_TMPDIR/scrape.prom"
  ! grep -qE '^(go_|promhttp_|process_)' "$BATS_TEST_TMPDIR/scrape.prom"
}

@test "the loopback interface and docker overlays are excluded" {
  curl -fsS "http://127.0.0.1:$NODE_EXPORTER_PORT/metrics" > "$BATS_TEST_TMPDIR/scrape.prom"
  ! grep -q 'node_network_receive_bytes_total{device="lo"}' "$BATS_TEST_TMPDIR/scrape.prom"
  ! grep -q 'mountpoint="/var/lib/docker/' "$BATS_TEST_TMPDIR/scrape.prom"
}

@test "a marked step reaches the exposition as a valid label" {
  RUNNER_METRICS_STEP='build "the" app' bash "$SCRIPTS/mark-step.sh"
  curl -fsS "http://127.0.0.1:$NODE_EXPORTER_PORT/metrics" > "$BATS_TEST_TMPDIR/scrape.prom"
  grep -q 'gha_step_active{step="build \\"the\\" app"} 1' "$BATS_TEST_TMPDIR/scrape.prom"
  rm -f "$RUNNER_METRICS_TEXTFILE_DIR/step.prom"
}

@test "the textfile collector reports no error after a marker was written" {
  RUNNER_METRICS_STEP=marker bash "$SCRIPTS/mark-step.sh"
  curl -fsS "http://127.0.0.1:$NODE_EXPORTER_PORT/metrics" > "$BATS_TEST_TMPDIR/scrape.prom"
  ! grep -qE '^node_textfile_scrape_error 1' "$BATS_TEST_TMPDIR/scrape.prom"
  rm -f "$RUNNER_METRICS_TEXTFILE_DIR/step.prom"
}

@test "prometheus accepts the generated config with a hostile job name" {
  echo secret > "$BATS_TEST_TMPDIR/password"
  JOB_NAME="matrix (ubuntu-24.04-arm) o'brien" \
  GITHUB_WORKFLOW=Smoke GITHUB_REPOSITORY=owner/repo GITHUB_JOB=smoke \
  GITHUB_RUN_ID=1 GITHUB_RUN_NUMBER=2 GITHUB_RUN_ATTEMPT=1 GITHUB_REF_NAME=main \
  RUNNER_OS=Linux RUNNER_ARCH=X64 SCRAPE_INTERVAL=5s NODE_EXPORTER_PORT="$NODE_EXPORTER_PORT" \
  REMOTE_WRITE_URL=https://example.test/api/v1/write REMOTE_WRITE_USERNAME=metrics \
  PASSWORD_FILE="$BATS_TEST_TMPDIR/password" \
    bash -c '. "$SCRIPTS/lib.sh"; runner_metrics_render_agent_config' > "$BATS_TEST_TMPDIR/agent.yml"

  python3 -c "import yaml" 2>/dev/null && python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d['global']['external_labels']['gha_job_name'] == \"matrix (ubuntu-24.04-arm) o'brien\", d" "$BATS_TEST_TMPDIR/agent.yml"

  "$RUNNER_METRICS_ROOT/bin/prometheus" --agent --config.file="$BATS_TEST_TMPDIR/agent.yml" \
    --storage.agent.path="$BATS_TEST_TMPDIR/wal" --web.listen-address=127.0.0.1:19198 \
    > "$BATS_TEST_TMPDIR/prometheus.log" 2>&1 &
  pid=$!
  ready=0
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null http://127.0.0.1:19198/-/ready; then ready=1; break; fi
    sleep 1
  done
  kill "$pid" 2>/dev/null
  [ "$ready" -eq 1 ] || cat "$BATS_TEST_TMPDIR/prometheus.log"
  [ "$ready" -eq 1 ]
}

@test "samples reach an endpoint that accepts the credentials" {
  start_receiver 19201
  RUNNER_METRICS_NODE_EXPORTER_PORT="$NODE_EXPORTER_PORT" AGENT_PORT=19099 \
  REMOTE_WRITE_URL="http://127.0.0.1:19201/api/v1/write" REMOTE_WRITE_USERNAME=metrics \
  REMOTE_WRITE_PASSWORD=s3cr3t JOB_NAME_OVERRIDE="integration job" \
  GITHUB_WORKFLOW=Test GITHUB_REPOSITORY=owner/repo GITHUB_JOB=test GITHUB_RUN_ID=1 \
  GITHUB_RUN_NUMBER=1 GITHUB_RUN_ATTEMPT=1 GITHUB_REF_NAME=main RUNNER_OS=Linux RUNNER_ARCH=X64 \
    bash "$SCRIPTS/start-agent.sh"
  grep -q '^RUNNER_METRICS_REMOTE_WRITE=enabled$' "$GITHUB_ENV"

  for _ in $(seq 1 40); do
    [ "$(receiver_field accepted)" -gt 0 ] && break
    sleep 1
  done
  [ "$(receiver_field accepted)" -gt 0 ]
  [ "$(receiver_field rejected)" -eq 0 ]
  [ "$(receiver_field snappy)" -gt 0 ]
  [ "$(receiver_field bytes)" -gt 0 ]

  curl -fsS http://127.0.0.1:19099/metrics > "$BATS_TEST_TMPDIR/agent.prom"
  . "$SCRIPTS/lib.sh"
  failed="$(runner_metrics_metric_sum "$BATS_TEST_TMPDIR/agent.prom" prometheus_remote_storage_samples_failed_total)"
  [ "${failed%%.*}" -eq 0 ]

  agent_pid="$(awk -F= '/^RUNNER_METRICS_AGENT_PID=/ { print $2 }' "$GITHUB_ENV")"
  RUNNER_METRICS_AGENT_PID="$agent_pid" RUNNER_METRICS_AGENT_PORT=19099 \
  RUNNER_METRICS_ROOT="$RUNNER_METRICS_ROOT" FLUSH_TIMEOUT=10 CLEANUP=false WRITE_REPORT=false \
    bash "$SCRIPTS/stop-collectors.sh"
  ! kill -0 "$agent_pid" 2>/dev/null
  [ ! -e "$RUNNER_METRICS_ROOT/password" ]
  [ ! -e "$RUNNER_METRICS_ROOT/agent.yml" ]
  stop_receiver
}

@test "the job fails fast when the endpoint rejects the credentials" {
  start_receiver 19202
  run env RUNNER_METRICS_ROOT="$RUNNER_METRICS_ROOT" AGENT_PORT=19098 \
    REMOTE_WRITE_URL="http://127.0.0.1:19202/api/v1/write" REMOTE_WRITE_USERNAME=metrics \
    REMOTE_WRITE_PASSWORD=wrong JOB_NAME_OVERRIDE=job GITHUB_JOB=job \
    bash "$SCRIPTS/start-agent.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'rejected the basic auth credentials with http 401'
  ! curl -fsS -o /dev/null http://127.0.0.1:19098/metrics
  stop_receiver
}

@test "a 404 endpoint only warns and the agent still runs" {
  start_receiver 19203 404
  run env RUNNER_METRICS_ROOT="$RUNNER_METRICS_ROOT" AGENT_PORT=19097 \
    RUNNER_METRICS_NODE_EXPORTER_PORT="$NODE_EXPORTER_PORT" \
    REMOTE_WRITE_URL="http://127.0.0.1:19203/api/v1/write" REMOTE_WRITE_USERNAME=metrics \
    REMOTE_WRITE_PASSWORD=s3cr3t JOB_NAME_OVERRIDE=job GITHUB_JOB=job GITHUB_WORKFLOW=Test \
    GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=1 GITHUB_RUN_NUMBER=1 GITHUB_RUN_ATTEMPT=1 \
    GITHUB_REF_NAME=main RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_ENV="$GITHUB_ENV" \
    bash "$SCRIPTS/start-agent.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::endpoint answered http 404'
  curl -fsS -o /dev/null http://127.0.0.1:19097/metrics
  kill "$(awk -F= '/^RUNNER_METRICS_AGENT_PID=/ { print $2 }' "$GITHUB_ENV")" 2>/dev/null
  stop_receiver
}

@test "an endpoint that is not listening only warns" {
  run env RUNNER_METRICS_ROOT="$RUNNER_METRICS_ROOT" AGENT_PORT=19096 \
    RUNNER_METRICS_NODE_EXPORTER_PORT="$NODE_EXPORTER_PORT" \
    REMOTE_WRITE_URL="http://127.0.0.1:19299/api/v1/write" REMOTE_WRITE_USERNAME=metrics \
    REMOTE_WRITE_PASSWORD=s3cr3t JOB_NAME_OVERRIDE=job GITHUB_JOB=job GITHUB_WORKFLOW=Test \
    GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=1 GITHUB_RUN_NUMBER=1 GITHUB_RUN_ATTEMPT=1 \
    GITHUB_REF_NAME=main RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_ENV="$GITHUB_ENV" \
    bash "$SCRIPTS/start-agent.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::endpoint did not answer'
  kill "$(awk -F= '/^RUNNER_METRICS_AGENT_PID=/ { print $2 }' "$GITHUB_ENV")" 2>/dev/null
}

@test "the report describes the running runner" {
  RUNNER_METRICS_ROOT="$BATS_TEST_TMPDIR/report-root" \
  RUNNER_METRICS_NODE_EXPORTER_PORT="$NODE_EXPORTER_PORT" RUNNER_METRICS_AGENT_PORT=1 \
  DRAIN_SECONDS=1 RUNNER_METRICS_REMOTE_WRITE=disabled \
    bash -c 'mkdir -p "$RUNNER_METRICS_ROOT"; bash "$SCRIPTS/report.sh"'
  grep -q '^## Runner metrics report$' "$GITHUB_STEP_SUMMARY"
  cores="$(sed -n 's/^| CPU cores | \(.*\) |$/\1/p' "$GITHUB_STEP_SUMMARY")"
  [ "$cores" -eq "$(nproc)" ]
  series="$(sed -n 's/^| Exposed series | \(.*\) |$/\1/p' "$GITHUB_STEP_SUMMARY")"
  [ "$series" -gt 20 ]
  grep -qE '^\| Memory total \| [0-9]+\.[0-9]{2} GiB \|$' "$GITHUB_STEP_SUMMARY"
  grep -qE '^\| Free space on / \| [0-9]+\.[0-9]{2} GiB \|$' "$GITHUB_STEP_SUMMARY"
}
