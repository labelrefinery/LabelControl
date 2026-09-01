#!/bin/zsh
# Start the whole control plane on this machine and leave it running.
#
#   ./run.sh          start everything, print the URL
#   ./run.sh stop     stop everything
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

stop() {
  pkill -f "build/labelcontrol" 2>/dev/null || true
  pkill -f "build/orchestrator" 2>/dev/null || true
  pkill -f "build/executor" 2>/dev/null || true
  pkill -f "restate-server" 2>/dev/null || true
  echo "stopped"
}

if [[ "$1" == "stop" ]]; then stop; exit 0; fi

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

if curl -sS -o /dev/null --max-time 10 http://127.0.0.1:10001/; then
  echo
  echo "  label control:  http://127.0.0.1:10001"
  echo "  restate UI:     http://127.0.0.1:9070"
  echo "  logs:           $CTL/*.log"
  echo
  echo "  stop with: ./run.sh stop"
else
  echo "the site did not come up — check $CTL/site.log"
  exit 1
fi
