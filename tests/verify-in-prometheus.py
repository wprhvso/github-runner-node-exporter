import argparse
import base64
import json
import os
import sys
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--base", required=True)
parser.add_argument("--run-id", required=True)
parser.add_argument("--job-name", required=True)
parser.add_argument("--window", default="30m")
parser.add_argument("--step", action="append", default=[])
args = parser.parse_args()

selector = f'gha_run_id="{args.run_id}"'
failures = []


def query(expression):
    url = args.base + "/api/v1/query?" + urllib.parse.urlencode({"query": expression})
    request = urllib.request.Request(url)
    user = os.environ.get("QUERY_USERNAME", "")
    if user:
        token = base64.b64encode(f"{user}:{os.environ.get('QUERY_PASSWORD', '')}".encode()).decode()
        request.add_header("Authorization", "Basic " + token)
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    if payload.get("status") != "success":
        raise SystemExit(f"query failed: {expression}: {payload}")
    return payload["data"]["result"]


def check(name, condition, detail=""):
    mark = "ok" if condition else "FAILED"
    print(f"{mark:>6}  {name}{'  ' + detail if detail else ''}")
    if not condition:
        failures.append(name)


print(f"run {args.run_id} on {args.base}\n")

for metric in [
    "node_cpu_seconds_total",
    "node_memory_MemTotal_bytes",
    "node_memory_MemAvailable_bytes",
    "node_load1",
    "node_disk_read_bytes_total",
    "node_network_receive_bytes_total",
    "node_filesystem_avail_bytes",
    "node_vmstat_oom_kill",
]:
    series = query(f"count(count_over_time({metric}{{{selector}}}[{args.window}]))")
    count = int(float(series[0]["value"][1])) if series else 0
    check(f"{metric} arrived", count > 0, f"{count} series")

noisy = query(
    f'count(count_over_time(node_cpu_seconds_total{{{selector},mode=~"nice|irq|softirq|guest|guest_nice"}}[{args.window}]))'
)
check("the noisy cpu modes were dropped", not noisy)

labels = query(f"count by (gha_job_name, gha_repository, gha_runner_os, instance) "
               f"(count_over_time(node_load1{{{selector}}}[{args.window}]))")
check("the external labels are attached", len(labels) == 1, str(labels[0]["metric"]) if labels else "no series")
if labels:
    check("gha_job_name is the readable job name", labels[0]["metric"].get("gha_job_name") == args.job_name,
          labels[0]["metric"].get("gha_job_name", ""))

steps = query(f"sum by (step) (count_over_time(gha_step_active{{{selector}}}[{args.window}]))")
seen = {series["metric"]["step"]: int(float(series["value"][1])) for series in steps}
print(f"\n  steps seen in prometheus: {json.dumps(seen, ensure_ascii=False)}\n")

for expected in args.step:
    check(f"step {expected!r} is visible", expected in seen, f"{seen.get(expected, 0)} samples")

check("no unexpected step showed up", set(seen) <= set(args.step), str(sorted(set(seen) - set(args.step))))
check("every step was sampled repeatedly, not once", all(count > 1 for count in seen.values()), str(seen))

overlap = query(f"max_over_time(sum(gha_step_active{{{selector}}})[{args.window}:1s])")
peak = float(overlap[0]["value"][1]) if overlap else 0
check("at most one step is active at a time", peak <= 1, f"peak {peak}")

if failures:
    print(f"\n{len(failures)} check(s) failed: {', '.join(failures)}", file=sys.stderr)
    sys.exit(1)
print("\nevery check passed")
