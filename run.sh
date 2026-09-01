#!/bin/zsh
# Start the whole control plane on this machine and leave it running.
#
#   ./run.sh          stop anything already running, then start everything
#   ./run.sh stop     stop everything
#   ./run.sh status   what is up, and on which ports
#
# Starting is a restart: it stops first, so running it twice is safe and you
# never end up with a half-replaced stack or a port held by the previous one.
#
# Four processes, because each is a separate concern and two of them are
# separate Restate endpoints on purpose: restate.mojo's driver is
# single-threaded and deadlocks if a handler calls one served by the same
# process, so the orchestrator and the executor cannot share one.
set -e

HERE=${0:a:h}
LR=${HERE:h}
CTL=${LABELCONTROL_ROOT:-$LR/control}
export LABELCONTROL_OPS=${LABELCONTROL_OPS:-$CTL/ops.db}
export LABELCONTROL_WORK=${LABELCONTROL_WORK:-$CTL/runs}
export LABELCONTROL_SITEGEN=${LABELCONTROL_SITEGEN:-$LR/sitegen}
# Serving through a tunnel? The public hostname must be here, because the
# tunnel forwards the original Host and anything unlisted gets a 403.
export LABELCONTROL_ALLOWED_HOSTS=${LABELCONTROL_ALLOWED_HOSTS:-}
export LABELCONTROL_PORT=${LABELCONTROL_PORT:-20000}

# Matched against full command lines. The `build/` prefix is what makes these
# specific enough -- a bare "executor" or "restate" would match other projects
# on this machine, and a start-is-restart script that kills a stranger's
# process is worse than one that leaves a stale one behind.
#
# Not absolute paths: pixi launches these as `./build/executor` from the repo
# root, so the command line reads `.../Refinery/./build/executor` and an
# absolute pattern misses the `./` in the middle. That silently made both stop
# and status report "down" for processes that were plainly running.
PATTERNS=(
  "build/labelcontrol"
  "build/orchestrator"
  "build/executor"
  "@restatedev/restate-server"
)

kill_pattern() {  # pattern -> kills, waits, escalates once
  local pat=$1
  local pids=(${(f)"$(pgrep -f $pat 2>/dev/null || true)"})
  [[ -z "$pids" ]] && return 0
  kill $pids 2>/dev/null || true
  for _ in {1..20}; do
    pgrep -f $pat > /dev/null 2>&1 || return 0
    sleep 0.25
  done
  # Still there after five seconds: it is not going to exit on its own.
  pkill -9 -f $pat 2>/dev/null || true
}

stop() {
  local any=0
  for pat in $PATTERNS; do
    if pgrep -f $pat > /dev/null 2>&1; then any=1; fi
    kill_pattern $pat
  done
  if [[ $any == 1 ]]; then echo "stopped what was running"; else echo "nothing was running"; fi
}

# macOS pgrep has no -c: it prints usage to stderr and yields nothing, so a
# `pgrep -fc` count silently reads as zero and every process looks down.
count_of() { pgrep -f $1 2>/dev/null | wc -l | tr -d " "; }

status() {
  for pat in $PATTERNS; do
    local n=$(count_of $pat)
    local pids=$(pgrep -f $pat 2>/dev/null | tr "\n" " ")
    printf "  %-20s %s\n" "${pat:t}" \
      "$([[ $n -gt 0 ]] && echo "up   pid $pids" || echo "down")"
  done
  printf "  %-20s %s\n" "port $LABELCONTROL_PORT" \
    "$(lsof -nP -iTCP:$LABELCONTROL_PORT -sTCP:LISTEN > /dev/null 2>&1 && echo "in use" || echo "free")"
  printf "  %-20s %s\n" "restate ingress" \
    "$(curl -sS -o /dev/null --max-time 3 http://127.0.0.1:8080/ 2>/dev/null && echo "reachable" || echo "unreachable — the buttons will not work")"
}

case "$1" in
  stop)   stop; exit 0 ;;
  status) status; exit 0 ;;
esac

stop

# Someone else holding the port would make the health check below fail with a
# confusing 200 from the wrong server, so say so plainly instead.
if lsof -nP -iTCP:$LABELCONTROL_PORT -sTCP:LISTEN > /dev/null 2>&1; then
  echo "port $LABELCONTROL_PORT is held by something this script did not start:"
  lsof -nP -iTCP:$LABELCONTROL_PORT -sTCP:LISTEN | tail -n +2
  echo "set LABELCONTROL_PORT to use another port."
  exit 1
fi

mkdir -p $CTL/runs
echo "control root: $CTL"

echo "starting restate-server…"
(npx --yes @restatedev/restate-server > $CTL/restate-server.log 2>&1 &)
sleep 20

# Both of these must run under `pixi run`: restate.mojo resolves
# librestatemojo from $CONDA_PREFIX/lib and falls back to a dev-relative path
# when it is unset, which fails at dlopen rather than at build.
echo "starting executor (:9080) and orchestrator (:9081)…"
(cd $LR/Refinery && pixi run executor > $CTL/executor.log 2>&1 &)
(cd $LR/Refinery && pixi run orchestrator > $CTL/orchestrator.log 2>&1 &)
sleep 18

npx --yes @restatedev/restate deployments register http://localhost:9080 --force --yes > /dev/null 2>&1
npx --yes @restatedev/restate deployments register http://localhost:9081 --force --yes > /dev/null 2>&1

echo "starting the site…"
(cd $HERE && pixi run serve > $CTL/site.log 2>&1 &)
sleep 10

if curl -sS -o /dev/null --max-time 10 http://127.0.0.1:$LABELCONTROL_PORT/; then
  echo
  echo "  label control:  http://127.0.0.1:$LABELCONTROL_PORT"
  echo "  restate UI:     http://127.0.0.1:9070"
  echo "  logs:           $CTL/*.log"
  if [[ -n "$LABELCONTROL_ALLOWED_HOSTS" ]]; then
    echo "  also answering: $LABELCONTROL_ALLOWED_HOSTS"
  fi
  echo
  echo "  stop with: ./run.sh stop      state: ./run.sh status"
else
  echo "the site did not come up — check $CTL/site.log"
  exit 1
fi
