#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Validate the lab with the Robot Framework suite.
#
#   ./run_tests.sh                 # everything
#   ./run_tests.sh --include cdp   # any robot option is passed through
#
# Every run writes to its own timestamped directory under test_results/:
#
#   test_results/results_2026-09-10_14-30-45/{report.html,log.html,output.xml}
#   test_results/latest -> results_2026-09-10_14-30-45
#
# so runs accumulate for comparison instead of overwriting each other, and
# `latest` is a stable path to hand to a browser or a CI step.
#
# The system Python is PEP 668 "externally managed", so dependencies live in
# a virtualenv under .venv/ that this script creates on first run.
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$PROJECT_DIR/.venv"
RESULTS_BASE="$PROJECT_DIR/test_results"
RUN_DIR="$RESULTS_BASE/results_$(date +%Y-%m-%d_%H-%M-%S)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# --- dependencies ----------------------------------------------------------

if [[ ! -x $VENV/bin/robot ]]; then
  log "creating test virtualenv in .venv (first run only)"
  python3 -m venv "$VENV" || die "python3 -m venv failed (apt install python3-venv)"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
      robotframework paramiko || die "could not install test dependencies"
fi

# --- validate the environment before testing it ----------------------------
# Six SSH timeouts and a wall of red is a poor way to learn the lab is down,
# so check first and name what is missing.
#
# Captured rather than piped: `grep -q` exits on the first match, and the
# resulting SIGPIPE would trip `pipefail` and report a false failure.
lab_status="$("$PROJECT_DIR/lab.sh" status)"

grep -qE '^\S+\s+up\s' <<<"$lab_status" \
  || die "no lab nodes are running -- start them with ./lab.sh start"

down=$(awk '$2 == "down" { printf "%s ", $1 }' <<<"$lab_status")
if [[ -n $down ]]; then
  log "warning: these nodes are down and their tests will fail: $down"
fi

# --- run -------------------------------------------------------------------

mkdir -p "$RUN_DIR"
log "running suite -> ${RUN_DIR#"$PROJECT_DIR"/}"

# Not `exec`: the run directory has to be recorded and reported afterwards,
# and robot's exit code passed through unchanged.
set +e
"$VENV/bin/robot" \
    --outputdir "$RUN_DIR" \
    --name "IOS-XRv9000 two-node lab" \
    "$@" \
    "$PROJECT_DIR/tests/xr_lab.robot"
rc=$?
set -e

ln -sfn "$(basename "$RUN_DIR")" "$RESULTS_BASE/latest"

log "results: ${RUN_DIR#"$PROJECT_DIR"/}"
log "         test_results/latest/report.html (log.html for detail)"
exit $rc
