#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  . "$REPO_ROOT/scripts/lib.sh"
  FIXTURES="$BATS_TEST_DIRNAME/../fixtures"
}

@test "arch maps known machines and rejects the rest" {
  [ "$(runner_metrics_arch x86_64)" = amd64 ]
  [ "$(runner_metrics_arch amd64)" = amd64 ]
  [ "$(runner_metrics_arch aarch64)" = arm64 ]
  [ "$(runner_metrics_arch arm64)" = arm64 ]
  run runner_metrics_arch armv7l
  [ "$status" -ne 0 ]
  run runner_metrics_arch ""
  [ "$status" -ne 0 ]
}

@test "trim_space removes every kind of whitespace" {
  [ "$(runner_metrics_trim_space $'  https://example.test/api/v1/write\n')" = "https://example.test/api/v1/write" ]
  [ "$(runner_metrics_trim_space $'\t \n')" = "" ]
}

@test "one_line folds newlines and tabs into spaces" {
  [ "$(runner_metrics_one_line $'a\nb\tc\r')" = "a b c " ]
}

@test "yaml escape doubles single quotes and never emits a newline" {
  [ "$(runner_metrics_yaml_escape "o'brien")" = "o''brien" ]
  [ "$(runner_metrics_yaml_escape $'a\nb')" = "a b" ]
  [ "$(runner_metrics_yaml_escape 'plain')" = "plain" ]
}

@test "curl escape backslashes before quotes" {
  [ "$(runner_metrics_curl_escape 'a"b')" = 'a\"b' ]
  [ "$(runner_metrics_curl_escape 'a\b')" = 'a\\b' ]
  [ "$(runner_metrics_curl_escape 'a\"b')" = 'a\\\"b' ]
}

@test "label escape produces a valid prometheus label value" {
  [ "$(runner_metrics_label_escape 'say "hi"')" = 'say \"hi\"' ]
  [ "$(runner_metrics_label_escape 'a\b')" = 'a\\b' ]
  [ "$(runner_metrics_label_escape $'multi\nline')" = 'multi line' ]
}

@test "bounded int falls back on garbage and clamps the maximum" {
  [ "$(runner_metrics_bounded_int 7 5 300)" = 7 ]
  [ "$(runner_metrics_bounded_int "" 5 300)" = 5 ]
  [ "$(runner_metrics_bounded_int abc 5 300)" = 5 ]
  [ "$(runner_metrics_bounded_int -3 5 300)" = 5 ]
  [ "$(runner_metrics_bounded_int 3.5 5 300)" = 5 ]
  [ "$(runner_metrics_bounded_int 100000 5 300)" = 300 ]
  [ "$(runner_metrics_bounded_int 0 5 300)" = 0 ]
}

@test "version validation accepts releases and rejects junk" {
  runner_metrics_valid_version 1.9.1
  runner_metrics_valid_version 3.0.0-rc.0
  run runner_metrics_valid_version v1.9.1
  [ "$status" -ne 0 ]
  run runner_metrics_valid_version latest
  [ "$status" -ne 0 ]
  run runner_metrics_valid_version ""
  [ "$status" -ne 0 ]
  run runner_metrics_valid_version '1.9.1; rm -rf /'
  [ "$status" -ne 0 ]
}

@test "release tag parsing strips the leading v and takes the first match" {
  tag="$(printf '{"tag_name": "v1.9.1", "assets": [{"tag_name": "v0.0.1"}]}' | runner_metrics_release_tag)"
  [ "$tag" = 1.9.1 ]
}

@test "metric sum adds every series of one metric and ignores prefixes" {
  [ "$(runner_metrics_metric_sum "$FIXTURES/sample.prom" node_memory_MemTotal_bytes)" = "16768000000.000000" ]
  [ "$(runner_metrics_metric_sum "$FIXTURES/sample.prom" node_vmstat_oom_kill)" = "2.000000" ]
  [ "$(runner_metrics_metric_sum "$FIXTURES/sample.prom" node_load1)" = "3.140000" ]
}

@test "metric sum is silent for an unknown metric and an unreadable file" {
  [ "$(runner_metrics_metric_sum "$FIXTURES/sample.prom" node_nothing_here)" = "" ]
  [ "$(runner_metrics_metric_sum /nonexistent node_load1)" = "" ]
}

@test "metric sum reads values of series whose labels contain spaces" {
  [ "$(runner_metrics_metric_sum "$FIXTURES/sample.prom" gha_step_active)" = "1.000000" ]
}

@test "metric sum does not confuse a metric with a longer sibling" {
  [ "$(runner_metrics_metric_sum "$FIXTURES/sample.prom" node_disk_read)" = "" ]
  [ "$(runner_metrics_metric_sum "$FIXTURES/sample.prom" node_pressure_cpu_waiting_seconds_total)" = "12.500000" ]
}

@test "cpu cores counts distinct cpus, not series" {
  [ "$(runner_metrics_cpu_cores "$FIXTURES/sample.prom")" = 4 ]
  [ "$(runner_metrics_cpu_cores /nonexistent)" = 0 ]
}

@test "filesystem avail matches the mountpoint exactly" {
  [ "$(runner_metrics_filesystem_avail "$FIXTURES/sample.prom" /)" = "42000000000" ]
  [ "$(runner_metrics_filesystem_avail "$FIXTURES/sample.prom" /mnt)" = "9000000000" ]
  [ "$(runner_metrics_filesystem_avail "$FIXTURES/sample.prom" /nope)" = "" ]
}

@test "filesystem avail survives a device label containing a quote or a space" {
  [ "$(runner_metrics_filesystem_avail "$FIXTURES/sample.prom" /data)" = "7000000000" ]
}

@test "human renders bytes, seconds and the missing value" {
  [ "$(runner_metrics_human 1073741824 gib)" = "1.00 GiB" ]
  [ "$(runner_metrics_human 12.5 s)" = "12.5 s" ]
  [ "$(runner_metrics_human "" gib)" = "n/a" ]
  [ "$(runner_metrics_human "" s)" = "n/a" ]
}

@test "preflight verdict fails only on rejected credentials" {
  [ "$(runner_metrics_preflight_verdict 401)" = "fail:endpoint rejected the basic auth credentials with http 401" ]
  [ "$(runner_metrics_preflight_verdict 403)" = "fail:endpoint rejected the basic auth credentials with http 403" ]
  case "$(runner_metrics_preflight_verdict 404)" in warn:*) ;; *) return 1 ;; esac
  case "$(runner_metrics_preflight_verdict 500)" in warn:*) ;; *) return 1 ;; esac
  case "$(runner_metrics_preflight_verdict 503)" in warn:*) ;; *) return 1 ;; esac
  case "$(runner_metrics_preflight_verdict 504)" in warn:*) ;; *) return 1 ;; esac
  case "$(runner_metrics_preflight_verdict 000)" in warn:*) ;; *) return 1 ;; esac
  case "$(runner_metrics_preflight_verdict "")" in warn:*) ;; *) return 1 ;; esac
  [ "$(runner_metrics_preflight_verdict 400)" = "ok:" ]
  [ "$(runner_metrics_preflight_verdict 204)" = "ok:" ]
}

@test "release tag parsing survives compact json" {
  tag="$(printf '{"url":"x","tag_name":"v3.6.0","name":"3.6.0"}' | runner_metrics_release_tag)"
  [ "$tag" = 3.6.0 ]
}

@test "release tag parsing yields nothing when the field is missing" {
  [ "$(printf '{"message": "Not Found"}' | runner_metrics_release_tag)" = "" ]
}

@test "duration validation accepts prometheus durations only" {
  runner_metrics_valid_duration 5s
  runner_metrics_valid_duration 1m30s
  runner_metrics_valid_duration 500ms
  run runner_metrics_valid_duration 5
  [ "$status" -ne 0 ]
  run runner_metrics_valid_duration "5 s"
  [ "$status" -ne 0 ]
  run runner_metrics_valid_duration ""
  [ "$status" -ne 0 ]
}
