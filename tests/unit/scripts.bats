#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  . "$SCRIPTS/lib.sh"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/textfile"
  export GITHUB_ENV="$WORK/env"
  export GITHUB_STEP_SUMMARY="$WORK/summary"
  : > "$GITHUB_ENV"
  : > "$GITHUB_STEP_SUMMARY"
}

render() {
  SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-5s}" \
  JOB_NAME="${JOB_NAME:-job}" \
  REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-https://example.test/api/v1/write}" \
  REMOTE_WRITE_USERNAME="${REMOTE_WRITE_USERNAME:-user}" \
  PASSWORD_FILE="${PASSWORD_FILE:-/tmp/password}" \
    runner_metrics_render_agent_config
}

@test "mark is a no-op when the collectors never started" {
  unset RUNNER_METRICS_TEXTFILE_DIR
  run env RUNNER_METRICS_STEP=build bash "$SCRIPTS/mark-step.sh"
  [ "$status" -eq 0 ]
  [ "$(ls "$WORK/textfile" | wc -l)" -eq 0 ]
}

@test "mark writes a complete textfile metric" {
  run env RUNNER_METRICS_TEXTFILE_DIR="$WORK/textfile" RUNNER_METRICS_STEP=build bash "$SCRIPTS/mark-step.sh"
  [ "$status" -eq 0 ]
  grep -q '^# TYPE gha_step_active gauge$' "$WORK/textfile/step.prom"
  grep -qx 'gha_step_active{step="build"} 1' "$WORK/textfile/step.prom"
}

@test "mark escapes a hostile step name and leaves no partial file behind" {
  run env RUNNER_METRICS_TEXTFILE_DIR="$WORK/textfile" RUNNER_METRICS_STEP=$'we"ird\\ name\nsecond line' bash "$SCRIPTS/mark-step.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'gha_step_active' "$WORK/textfile/step.prom")" -eq 3 ]
  grep -qx 'gha_step_active{step="we\\"ird\\\\ name second line"} 1' "$WORK/textfile/step.prom"
  [ -z "$(ls "$WORK/textfile" | grep -v '^step.prom$')" ]
}

@test "mark overwrites the previous marker instead of appending" {
  env RUNNER_METRICS_TEXTFILE_DIR="$WORK/textfile" RUNNER_METRICS_STEP=one bash "$SCRIPTS/mark-step.sh"
  env RUNNER_METRICS_TEXTFILE_DIR="$WORK/textfile" RUNNER_METRICS_STEP=two bash "$SCRIPTS/mark-step.sh"
  [ "$(grep -c '^gha_step_active' "$WORK/textfile/step.prom")" -eq 1 ]
  grep -q 'step="two"' "$WORK/textfile/step.prom"
}

@test "agent config keeps a quoted job name inside the yaml scalar" {
  JOB_NAME="matrix (o'brien)" run render
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "gha_job_name: 'matrix (o''brien)'"
}

@test "agent config never breaks out of the scalar on a newline" {
  JOB_NAME=$'evil\nremote_write: []' run render
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^remote_write:')" -eq 1 ]
}

@test "agent config points the scrape target at the node exporter port" {
  NODE_EXPORTER_PORT=19100 run render
  echo "$output" | grep -q '127.0.0.1:19100'
}

@test "stop and report are no-ops before start ever ran" {
  unset RUNNER_METRICS_ROOT
  run bash "$SCRIPTS/report.sh"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/stop-collectors.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "stop tolerates a dead pid and a garbage flush timeout" {
  mkdir -p "$WORK/root"
  : > "$WORK/root/node_exporter.log"
  run env RUNNER_METRICS_ROOT="$WORK/root" RUNNER_METRICS_AGENT_PID=999999 \
    RUNNER_METRICS_NODE_EXPORTER_PID=999998 FLUSH_TIMEOUT=not-a-number CLEANUP=true \
    bash "$SCRIPTS/stop-collectors.sh"
  [ "$status" -eq 0 ]
  [ ! -d "$WORK/root" ]
}

@test "stop keeps the workspace when cleanup is disabled and always removes the secrets" {
  mkdir -p "$WORK/root"
  echo secret > "$WORK/root/password"
  echo secret > "$WORK/root/curlrc"
  run env RUNNER_METRICS_ROOT="$WORK/root" CLEANUP=false WRITE_REPORT=false bash "$SCRIPTS/stop-collectors.sh"
  [ "$status" -eq 0 ]
  [ -d "$WORK/root" ]
  [ ! -e "$WORK/root/password" ]
  [ ! -e "$WORK/root/curlrc" ]
}

@test "report renders the summary table from a scraped sample" {
  mkdir -p "$WORK/root"
  cp "$BATS_TEST_DIRNAME/../fixtures/sample.prom" "$WORK/root/sample.prom"
  run env RUNNER_METRICS_ROOT="$WORK/root" RUNNER_METRICS_REMOTE_WRITE=disabled \
    DRAIN_SECONDS=0 RUNNER_METRICS_NODE_EXPORTER_PORT=1 RUNNER_METRICS_AGENT_PORT=1 bash "$SCRIPTS/report.sh"
  [ "$status" -eq 0 ]
  grep -q '| CPU cores | 4 |' "$GITHUB_STEP_SUMMARY"
  grep -q '| Memory total | 15.62 GiB |' "$GITHUB_STEP_SUMMARY"
  grep -q '| Free space on / | 39.12 GiB |' "$GITHUB_STEP_SUMMARY"
  grep -q '| OOM kills | 2 |' "$GITHUB_STEP_SUMMARY"
  grep -q '| CPU pressure since boot | 12.5 s |' "$GITHUB_STEP_SUMMARY"
}

@test "report warns the job when the oom killer fired" {
  mkdir -p "$WORK/root"
  cp "$BATS_TEST_DIRNAME/../fixtures/sample.prom" "$WORK/root/sample.prom"
  run env RUNNER_METRICS_ROOT="$WORK/root" DRAIN_SECONDS=0  RUNNER_METRICS_NODE_EXPORTER_PORT=1 RUNNER_METRICS_AGENT_PORT=1 \
    bash "$SCRIPTS/report.sh"
  echo "$output" | grep -q '^::warning::the kernel oom killer fired 2 time'
}

@test "report degrades to n/a when nothing was scraped" {
  mkdir -p "$WORK/root"
  : > "$WORK/root/sample.prom"
  run env RUNNER_METRICS_ROOT="$WORK/root" DRAIN_SECONDS=0  RUNNER_METRICS_NODE_EXPORTER_PORT=1 RUNNER_METRICS_AGENT_PORT=1 \
    bash "$SCRIPTS/report.sh"
  [ "$status" -eq 0 ]
  grep -q '| Memory total | n/a |' "$GITHUB_STEP_SUMMARY"
  grep -q '| OOM kills | 0 |' "$GITHUB_STEP_SUMMARY"
  grep -q '| Exposed series | 0 |' "$GITHUB_STEP_SUMMARY"
}

@test "start agent refuses a plaintext endpoint before writing the password" {
  mkdir -p "$WORK/root"
  run env RUNNER_METRICS_ROOT="$WORK/root" REMOTE_WRITE_URL=http://example.test/api/v1/write \
    REMOTE_WRITE_USERNAME=user REMOTE_WRITE_PASSWORD=pass bash "$SCRIPTS/start-agent.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'must use https'
  [ ! -e "$WORK/root/password" ]
}

@test "start agent turns into a no-op on an empty url" {
  mkdir -p "$WORK/root"
  run env RUNNER_METRICS_ROOT="$WORK/root" REMOTE_WRITE_URL="  " bash "$SCRIPTS/start-agent.sh"
  [ "$status" -eq 0 ]
  grep -q '^RUNNER_METRICS_REMOTE_WRITE=disabled$' "$GITHUB_ENV"
}

@test "install rejects an architecture it has no binaries for" {
  run env RUNNER_TEMP="$WORK" PATH="$BATS_TEST_DIRNAME/../stubs:$PATH" UNAME_M=ppc64le \
    bash "$SCRIPTS/install-collectors.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'unsupported architecture ppc64le'
}

@test "install rejects a version that is not a release" {
  run env RUNNER_TEMP="$WORK" NODE_EXPORTER_VERSION="v1.9.1" bash "$SCRIPTS/install-collectors.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'without the leading v'
}
