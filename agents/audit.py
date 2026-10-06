#!/usr/bin/env python3
"""
The audit trail: every tool call the agent made, one line each.

    agents/audit.py                 everything in agents/audit/*.jsonl
    agents/audit.py --session <id>  an APPROVE=manual run, from Claude Code's
                                    own session file

The moment this exists for: at the end of Lab 2, participants read their own
log and find something they approved without really reading it.
"""
import argparse, json, pathlib, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from agents.transcript import read_jsonl, summarise

AUDIT = pathlib.Path(__file__).resolve().parent / "audit"
PROJECTS = pathlib.Path.home() / ".claude" / "projects"


def reason(summary, width=160):
    """The first line of a result, whitespace collapsed, cut to `width`."""
    first = " ".join((summary or "").strip().split("\n")[0].split())
    return first if len(first) <= width else first[:width - 1] + "\u2026"


def render(rows, colour=True):
    if not rows:
        return "no tool calls recorded yet. Run: make agent MODE=<mode>\n"
    red, dim, end = ("\033[31m", "\033[2m", "\033[0m") if colour else ("", "", "")
    lines = [f"{dim}{'time':8}  {'tool':30}  {'arguments':60}  result{end}"]
    calls = refused = 0
    for r in rows:
        if r.get("mode") == "lab":
            # `make lab` marks where a lab started and at which level. It is
            # not a tool call, so it is a divider and is not counted.
            a = r.get("args", {})
            lines.append(f"{dim}--- lab {a.get('lab')} \u00b7 {a.get('level')} ---{end}")
            continue
        calls += 1
        name = r["name"].removeprefix("mcp__k8s__")
        args = json.dumps(r.get("args", {}))[:60]
        verdict = f"{red}REFUSED{end}" if r.get("is_error") else "ok"
        refused += bool(r.get("is_error"))
        lines.append(f"{r.get('ts', '')[11:19]:8}  {name:30}  {args:60}  {verdict}")
        if r.get("is_error"):
            # Why it failed, so an RBAC refusal reads differently from a write
            # that failed on bad YAML.
            lines.append(f"          {dim}{reason(r.get('result_summary', ''))}{end}")
    lines.append(f"\n{calls} calls, {refused} refused")
    return "\n".join(lines) + "\n"


def load_audit(directory=AUDIT):
    rows = []
    for f in sorted(directory.glob("*.jsonl")):
        rows += read_jsonl(f.read_text().splitlines())
    # Time order, not file order: the lab file's name sorts after every
    # session's, which put a lab's start after its own calls. ISO UTC
    # timestamps sort as strings; a row without one goes first.
    return sorted(rows, key=lambda r: r.get("ts", ""))


def load_session(session_id, root=PROJECTS):
    """Glob rather than rebuild the project slug: it is the resolved cwd with
    '/' and '.' replaced, which is easy to get wrong (spike, 2026-09-28)."""
    files = list(root.glob(f"*/{session_id}.jsonl"))
    if not files:
        raise SystemExit(f"no session file for {session_id} under {root}")
    return summarise(read_jsonl(files[0].read_text().splitlines()))["tool_calls"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session")
    a = ap.parse_args()
    rows = load_session(a.session) if a.session else load_audit()
    sys.stdout.write(render(rows, colour=sys.stdout.isatty()))


if __name__ == "__main__":
    main()
