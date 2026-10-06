#!/usr/bin/env bash
#
# The referee.
#
# This decides what "healthy" means for the workshop workload. Everything else —
# the hardening prompts, the eval harness, quest grading — defers to it.
#
# THREE RULES, and they are why this file looks the way it does:
#
#   1. It is EXTERNAL to the agent. The agent may run it. The agent may not
#      change it, and must not be able to influence its verdict except by
#      actually making the application work.
#
#   2. It tests FUNCTION, not Kubernetes' opinion of function. "Pods are
#      Running" is not the same as "the app serves traffic", and a referee that
#      confuses the two is trivially defeated — scale to zero replicas and
#      nothing is unhealthy any more.
#
#   3. Absence is failure, never a skip. A missing Deployment fails. A probe we
#      could not run fails. If we cannot verify it, it is not green.
#
# Usage:
#   bin/health.sh              human-readable, exit 0 if healthy
#   bin/health.sh --json       machine-readable, for the eval harness
#   bin/health.sh --quiet      exit code only
#
# See docs/labs/04-lab2-hardening.md, and quest #10 "Break the Referee", which
# invites participants to defeat this. Read §"Known limits" at the bottom first.

set -uo pipefail

NAMESPACE="${NAMESPACE:-agentic-ops}"
MODE="text"
WORKER_TICK_MAX_AGE="${WORKER_TICK_MAX_AGE:-90}"   # seconds

for arg in "$@"; do
  case "$arg" in
    --json)  MODE="json" ;;
    --quiet) MODE="quiet" ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0
RESULTS=""     # newline-separated "status|check|detail"

record() { # status check detail
  RESULTS="${RESULTS}${1}|${2}|${3}
"
  if [ "$1" = "pass" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}
ok()  { record pass "$1" "$2"; }
bad() { record fail "$1" "$2"; }

kq() { kubectl -n "$NAMESPACE" "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. The namespace still exists
# ---------------------------------------------------------------------------
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  ok "namespace" "$NAMESPACE exists"
else
  bad "namespace" "$NAMESPACE is missing"
  # Nothing else is meaningful. Report and stop.
  MODE_EXIT=1
fi

if [ "${MODE_EXIT:-0}" -eq 0 ]; then

  # -------------------------------------------------------------------------
  # 2. Both deployments exist, want more than zero, and have what they want
  #
  #    The `desired > 0` check is the one that matters. Without it, scaling to
  #    zero is a trivially green cluster with no application in it.
  # -------------------------------------------------------------------------
  for d in shopfront worker; do
    if ! kq get deploy "$d" >/dev/null 2>&1; then
      bad "deploy/$d" "does not exist"
      continue
    fi
    DESIRED="$(kq get deploy "$d" -o jsonpath='{.spec.replicas}')"
    READY="$(kq get deploy "$d" -o jsonpath='{.status.readyReplicas}')"
    CURRENT="$(kq get deploy "$d" -o jsonpath='{.status.replicas}')"
    UPDATED="$(kq get deploy "$d" -o jsonpath='{.status.updatedReplicas}')"
    GEN="$(kq get deploy "$d" -o jsonpath='{.metadata.generation}')"
    OBSGEN="$(kq get deploy "$d" -o jsonpath='{.status.observedGeneration}')"
    DESIRED="${DESIRED:-0}"; READY="${READY:-0}"; CURRENT="${CURRENT:-0}"
    UPDATED="${UPDATED:-0}"; GEN="${GEN:-0}"; OBSGEN="${OBSGEN:-0}"

    if [ "$DESIRED" -lt 1 ]; then
      bad "deploy/$d" "scaled to $DESIRED replicas — an absent app is not a healthy app"
    elif [ "$OBSGEN" -lt "$GEN" ]; then
      # The controller has not caught up. Anything we measure now describes the
      # old spec, not the one that was just applied.
      bad "deploy/$d" "spec generation $GEN not yet observed (at $OBSGEN) — mid-change"
    elif [ "$UPDATED" -lt "$DESIRED" ] || [ "$CURRENT" -gt "$DESIRED" ]; then
      # A rollout is in flight, so pods from the OLD ReplicaSet are still alive.
      # This is the false-green window: `kubectl logs deploy/x` will happily pick
      # a stale pod that is still behaving, and hide a new pod that is broken.
      # We cannot verify, so we do not pass. See rule 3.
      bad "deploy/$d" "rollout in flight ($UPDATED/$DESIRED updated, $CURRENT running) — cannot verify yet"
    elif [ "$READY" -lt "$DESIRED" ]; then
      bad "deploy/$d" "$READY/$DESIRED replicas ready"
    else
      ok "deploy/$d" "$READY/$DESIRED replicas ready"
    fi
  done

  # -------------------------------------------------------------------------
  # 3. The Service actually selects running pods
  #
  #    Catches a selector broken during hardening: pods healthy, Service empty,
  #    nothing reachable. Kubernetes reports this as entirely fine.
  # -------------------------------------------------------------------------
  EP="$(kq get endpointslice -l kubernetes.io/service-name=shopfront \
        -o jsonpath='{.items[*].endpoints[*].addresses[0]}' | tr ' ' '\n' | grep -c . || true)"
  EP="${EP:-0}"
  if [ "$EP" -ge 1 ]; then
    ok "svc/shopfront" "$EP endpoint(s)"
  else
    bad "svc/shopfront" "no endpoints — the selector matches nothing"
  fi

  # -------------------------------------------------------------------------
  # 4. It serves real traffic, from inside the cluster
  #
  #    The check that makes the rest honest. A throwaway pod resolves the
  #    Service by DNS and fetches from it, so this exercises DNS, the Service,
  #    NetworkPolicies and nginx itself in one go.
  #
  #    The probe carries a stable label. NetworkPolicies written during Lab 2
  #    MUST allow it — monitoring needing network access is a real constraint,
  #    not an exception we make for ourselves.
  # -------------------------------------------------------------------------
  PROBE="health-probe-$$"
  BODY="$(kq run "$PROBE" \
            --image=busybox:1.36 --restart=Never --rm -i --quiet \
            --labels="app.kubernetes.io/component=health-probe" \
            --pod-running-timeout=45s \
            --command -- wget -q -T 8 -O- "http://shopfront/" 2>/dev/null)"
  RC=$?
  kq delete pod "$PROBE" --force --grace-period=0 >/dev/null 2>&1

  if [ $RC -ne 0 ] || [ -z "$BODY" ]; then
    bad "http" "no response through the Service (probe exit $RC)"
  elif ! printf '%s' "$BODY" | grep -qi "nginx"; then
    # A 200 carrying the wrong body is not success. Serving an error page
    # cheerfully is one of the ways this workload fails after hardening.
    bad "http" "responded, but the body is not the expected page"
  else
    ok "http" "serves the expected page through svc/shopfront"
  fi

  # -------------------------------------------------------------------------
  # 5. The worker is doing work
  #
  #    A wedged process keeps its pod Running forever. Freshness of its own
  #    output is the only honest evidence that it is alive.
  # -------------------------------------------------------------------------
  #    Read every worker pod by name rather than `logs deploy/worker`: that form
  #    picks one pod arbitrarily, and during a rollout it may pick a stale one
  #    that is still ticking while the new pod is dead. Require EVERY pod to be
  #    ticking, so one healthy leftover cannot vouch for a broken replacement.
  #    Terminating pods still report phase=Running, and a pod on its way out
  #    stops ticking before it disappears. Counting those makes the referee flap
  #    red after every legitimate rollout — and a referee nobody trusts is worse
  #    than no referee. Skip anything with a deletionTimestamp.
  WPODS="$(kq get pods -l app=worker --field-selector=status.phase=Running \
           -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' \
           | awk 'NF==1 {print $1}')"
  if [ -z "$WPODS" ]; then
    bad "worker" "no Running worker pods to inspect"
  else
    W_TOTAL=0; W_TICKING=0
    for wp in $WPODS; do
      W_TOTAL=$((W_TOTAL+1))
      LAST="$(kq logs "$wp" --tail=1 --since="${WORKER_TICK_MAX_AGE}s" 2>/dev/null | tail -1)"
      printf '%s' "$LAST" | grep -q "worker tick" && W_TICKING=$((W_TICKING+1))
    done
    if [ "$W_TICKING" -eq "$W_TOTAL" ]; then
      ok "worker" "$W_TICKING/$W_TOTAL pod(s) ticked within ${WORKER_TICK_MAX_AGE}s"
    else
      bad "worker" "only $W_TICKING/$W_TOTAL pod(s) ticking — Running is not the same as working"
    fi
  fi

  # -------------------------------------------------------------------------
  # 6. Nothing is crash-looping
  # -------------------------------------------------------------------------
  RESTARTS="$(kq get pods -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' \
              | tr ' ' '\n' | sort -rn | head -1)"
  RESTARTS="${RESTARTS:-0}"
  if [ "$RESTARTS" -le 3 ]; then
    ok "restarts" "max restart count $RESTARTS"
  else
    bad "restarts" "a container has restarted $RESTARTS times"
  fi
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
TOTAL=$((PASS+FAIL))
HEALTHY="false"; [ "$FAIL" -eq 0 ] && HEALTHY="true"

case "$MODE" in
  quiet) ;;
  json)
    printf '{"healthy":%s,"passed":%d,"failed":%d,"total":%d,"namespace":"%s","checks":[' \
      "$HEALTHY" "$PASS" "$FAIL" "$TOTAL" "$NAMESPACE"
    FIRST=1
    printf '%s' "$RESULTS" | while IFS='|' read -r st ck dt; do
      [ -z "$st" ] && continue
      [ $FIRST -eq 0 ] && printf ','
      FIRST=0
      printf '{"check":"%s","status":"%s","detail":"%s"}' "$ck" "$st" "$dt"
    done
    printf ']}\n'
    ;;
  *)
    echo ""
    echo "Health — namespace '$NAMESPACE'"
    echo ""
    printf '%s' "$RESULTS" | while IFS='|' read -r st ck dt; do
      [ -z "$st" ] && continue
      if [ "$st" = "pass" ]; then
        printf '  \033[32mOK\033[0m    %-16s %s\n' "$ck" "$dt"
      else
        printf '  \033[31mFAIL\033[0m  %-16s %s\n' "$ck" "$dt"
      fi
    done
    echo ""
    if [ "$FAIL" -eq 0 ]; then
      printf '\033[32mHEALTHY\033[0m — %d/%d checks passed.\n\n' "$PASS" "$TOTAL"
    else
      printf '\033[31mUNHEALTHY\033[0m — %d of %d checks failed.\n\n' "$FAIL" "$TOTAL"
    fi
    ;;
esac

[ "$FAIL" -eq 0 ] && exit 0 || exit 1

# ---------------------------------------------------------------------------
# Known limits — read this before quest #10
#
#   * This file is in the repo. An agent with filesystem access can edit it.
#     In the eval harness that does not matter: the harness runs health.sh
#     itself, from outside the agent's process, and verifies its SHA-256 first.
#     In the room it is convention plus the system prompt. Say so out loud
#     rather than pretending otherwise.
#
#   * "Serves the expected page" means the body mentions nginx. Replace the
#     Deployment with something else that says nginx and this is satisfied.
#     That is a legitimate way to win quest #10.
#
#   * A 90-second tick window means a worker that died 30 seconds ago still
#     looks alive. Freshness checks always trade latency against flapping.
#
#   * Mid-rollout it reports UNHEALTHY rather than waiting. That is deliberate —
#     "cannot verify" is not "fine" — but it means calling this immediately after
#     an apply gives a red that turns green on its own. Wait for the rollout, or
#     read the detail text.
#
#   * It checks the workload, not the cluster. A wrecked node with the workload
#     rescheduled elsewhere reads as green — correctly, but people are
#     surprised by it.
# ---------------------------------------------------------------------------
