#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dir="${RUNNER_METRICS_TEXTFILE_DIR:-}"
if [ -z "$dir" ]; then exit 0; fi

mkdir -p "$dir"
step="$(runner_metrics_label_escape "${RUNNER_METRICS_STEP:-}")"

printf '# HELP gha_step_active Currently running workflow step.\n# TYPE gha_step_active gauge\ngha_step_active{step="%s"} 1\n' \
  "$step" > "$dir/.step.prom.tmp"
mv "$dir/.step.prom.tmp" "$dir/step.prom"
