"""
Build a kubeconfig that authenticates as a namespace ServiceAccount.

The agent must never run as the operator. We keep the operator's cluster entry
(server and CA) and swap the identity for a short-lived token, so what the agent
can do is exactly what the RBAC ladder says, and nothing the operator can do
leaks through.
"""
import json, os, subprocess, tempfile


def for_service_account(operator, token, namespace, sa):
    cluster = operator["clusters"][0]
    name = f"{sa}@{cluster['name']}"
    return {
        "apiVersion": "v1", "kind": "Config", "current-context": name,
        "clusters": [cluster],
        "users": [{"name": sa, "user": {"token": token}}],
        "contexts": [{"name": name, "context": {
            "cluster": cluster["name"], "user": sa, "namespace": namespace}}],
    }


def operator_minified():
    """The operator's CURRENT context, flattened. Read once and pinned: see
    evals/run.py:pin_context for why ambient context is not trusted twice."""
    p = subprocess.run(["kubectl", "config", "view", "--raw", "--minify", "-o", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0 or not p.stdout.strip():
        raise SystemExit("no current kubectl context. Run: make env-up ENV=<env>")
    return json.loads(p.stdout)


def mint_token(sa, namespace, kubeconfig, duration="2h"):
    return subprocess.run(
        ["kubectl", "--kubeconfig", kubeconfig, "-n", namespace, "create", "token", sa,
         f"--duration={duration}"],
        check=True, capture_output=True, text=True).stdout.strip()


def write_private(obj, prefix):
    fd, path = tempfile.mkstemp(prefix=prefix, suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(obj, fh)
    os.chmod(path, 0o600)
    return path
