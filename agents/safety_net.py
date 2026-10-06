"""
The safety net: restore the last healthy state when a turn ends red.

The runner does this, not the agent. It holds the operator's credentials and
the agent doesn't. The lesson it demonstrates is "guardrails make mistakes
survivable" (Gate B plan, H3). It can't raise a pass rate: it restores the
spec the agent started from, which fails the hardening checks. It should drive
"left broken" to zero.

On by default in harden mode. `make agent MODE=harden SAFETY_NET=off` turns it
off, so participants can watch the difference.

Stdlib only, like the rest of the runner.
"""
import copy, json, os, pathlib, subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
KINDS = "deployments,services,networkpolicies"
OWNER = "agentic-cloud-ops"
SERVER_METADATA = ("uid", "resourceVersion", "generation", "creationTimestamp", "managedFields")
SERVER_ANNOTATIONS = ("deployment.kubernetes.io/revision",
                      "kubectl.kubernetes.io/last-applied-configuration")


def enabled(mode, env=os.environ):
    v = env.get("ACO_SAFETY_NET", "")
    if v == "":
        return mode == "harden"
    return v.lower() not in ("0", "off", "false", "no")


def restorable(obj):
    """The object as something that can be written back: intent, not server state."""
    r = copy.deepcopy(obj)
    r.pop("status", None)
    meta = r.get("metadata", {})
    for k in SERVER_METADATA:
        meta.pop(k, None)
    notes = {k: v for k, v in meta.get("annotations", {}).items() if k not in SERVER_ANNOTATIONS}
    if notes:
        meta["annotations"] = notes
    else:
        meta.pop("annotations", None)
    return r


def key(o):
    return o["kind"], o["metadata"]["name"]


def drifted(snap, live):
    """What differs from the snapshot, or is gone from the cluster."""
    now = {key(o): o for o in live}
    return [key(o) for o in snap if now.get(key(o)) != o]


def strays(snap, live):
    """NetworkPolicies added since the snapshot. A new deny policy is the one
    addition that can break traffic by merely existing."""
    had = {key(o) for o in snap}
    return [o["metadata"]["name"] for o in live
            if o["kind"] == "NetworkPolicy" and key(o) not in had]


def message(restored, removed):
    def name(kind, n):
        return n if kind == "Deployment" else f"{kind} {n}"
    names = [name(*k) for k in restored]
    what = " and ".join([", ".join(names[:-1]), names[-1]] if len(names) > 1 else names)
    verb = "were" if len(names) > 1 else "was"
    msg = f"safety net: the referee was red at the end, so {what} {verb} restored to the last healthy state"
    if removed:
        msg += ", and " + " and ".join(f"NetworkPolicy {n}" for n in removed) + \
               (" were" if len(removed) > 1 else " was") + " removed"
    return msg


# --- the cluster side: kubectl and the referee, always as the operator --------
def kubectl(kubeconfig, ns, *args, stdin=None):
    return subprocess.run(["kubectl", "--kubeconfig", kubeconfig, "-n", ns, *args],
                          input=stdin, capture_output=True, text=True, timeout=180)


def live(ns, kubeconfig):
    p = kubectl(kubeconfig, ns, "get", KINDS, "-o", "json")
    if p.returncode != 0:
        raise RuntimeError(f"safety net: could not read {ns}: {p.stderr.strip()[:200]}")
    return [restorable(o) for o in json.loads(p.stdout)["items"]]


def snapshot(ns, kubeconfig):
    return live(ns, kubeconfig)


def healthy(kubeconfig, ns):
    env = {**os.environ, "KUBECONFIG": kubeconfig, "NAMESPACE": ns}
    p = subprocess.run([str(ROOT / "bin" / "health.sh"), "--json"], capture_output=True,
                       text=True, timeout=180, env=env)
    try:
        return bool(json.loads(p.stdout).get("healthy"))
    except ValueError:
        return False


def restore(ns, kubeconfig, snap):
    """Write the snapshot back, remove policies added since, wait for rollouts.

    `replace`, not server-side apply. Apply only takes over the fields in the
    manifest, so a field the agent added survives it: runAsNonRoot did, on k3d
    (2026-10-04). Replace writes the whole object."""
    owner = kubectl(kubeconfig, "default", "get", "ns", ns, "-o",
                    "jsonpath={.metadata.labels.app\\.kubernetes\\.io/part-of}")
    if owner.stdout.strip() != OWNER:
        raise RuntimeError(f"safety net: {ns} is not labelled as ours; refusing to restore")
    now = live(ns, kubeconfig)
    restored, removed = drifted(snap, now), strays(snap, now)
    for o in snap:
        if key(o) not in restored:
            continue
        doc = json.dumps(o)
        p = kubectl(kubeconfig, ns, "replace", "-f", "-", stdin=doc)
        if p.returncode != 0 and "NotFound" in p.stderr:
            p = kubectl(kubeconfig, ns, "create", "-f", "-", stdin=doc)
        if p.returncode != 0:
            raise RuntimeError(f"safety net: could not restore {key(o)}: {p.stderr.strip()[:200]}")
    for n in removed:
        kubectl(kubeconfig, ns, "delete", "networkpolicy", n, "--ignore-not-found")
    for kind, n in restored:
        if kind == "Deployment":
            kubectl(kubeconfig, ns, "rollout", "status", f"deployment/{n}", "--timeout=150s")
    return restored, removed


class SafetyNet:
    """Holds the last healthy state across a session's turns.

    `say` prints the one line; `record` writes it to the audit trail, so
    `make audit` shows it. Nothing the runner does on the participant's behalf
    is hidden. `record` comes per turn: the audit file is named after the
    turn's session, which only exists once the turn has run."""

    def __init__(self, ns, kubeconfig, say):
        self.ns, self.kubeconfig, self.say = ns, kubeconfig, say
        self.snap = snapshot(ns, kubeconfig) if healthy(kubeconfig, ns) else None

    def after_turn(self, record):
        if healthy(self.kubeconfig, self.ns):
            self.snap = snapshot(self.ns, self.kubeconfig)
            return "not needed"
        if self.snap is None:
            return "unavailable: red before the agent started"
        restored, removed = restore(self.ns, self.kubeconfig, self.snap)
        msg = message(restored, removed) if restored or removed else \
            "safety net: the referee was red at the end, and nothing differed from the last healthy state"
        self.say(msg)
        record(msg, {"restored": [f"{k}/{n}" for k, n in restored], "removed": removed})
        return "restored" if healthy(self.kubeconfig, self.ns) else "restored, still red"
