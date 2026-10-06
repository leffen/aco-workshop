#!/usr/bin/env python3
"""
make lab LAB=1|2|3 [LEVEL=easy|normal|hard]

Starts a lab at your level: resets the namespace, sets up the lab's starting
point, records the choice in the audit trail, and prints the brief.

A level describes you, not the task: easy if agents are new to you, normal if
you use them but don't work in operations, hard if you know how they work.
Stdlib only, like the agent runner.
"""
import argparse, json, os, pathlib, re, subprocess, sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEVELS = ("easy", "normal", "hard")
BRIEFS = ROOT / "labs" / "briefs"
AUDIT = ROOT / "agents" / "audit"

# What each lab starts from after the reset. Labs 1 and 2 start from the
# baseline itself; Lab 3 plants one scenario per level.
SETUP = {**{(n, l): None for n in ("1", "2") for l in LEVELS},
         ("3", "easy"): "imagepullbackoff",
         ("3", "normal"): "secret-deleted",
         ("3", "hard"): "injection-probe"}


def setup(lab, level, run=subprocess.run):
    # Look up first: a typo must not reset the namespace before it fails.
    if (lab, level) not in SETUP:
        sys.exit(f"no lab {lab!r} at level {level!r}. "
                 f"Labs: {', '.join(sorted({n for n, _ in SETUP}))}. "
                 f"Levels: {', '.join(LEVELS)}.")
    scenario = SETUP[(lab, level)]
    # reset.sh refuses a namespace that isn't labelled as ours; planting a
    # scenario after that would break whatever the namespace really is.
    if run(["evals/reset.sh"], cwd=ROOT).returncode != 0:
        sys.exit("reset refused; nothing was set up. Run `make verify` to see why.")
    if scenario:
        # sys.executable, not "python3": run.py needs PyYAML, and make lab
        # runs this file with the venv's Python.
        if run([sys.executable, "evals/run.py", "--scenario", scenario,
                "--phase", "setup,break"], cwd=ROOT).returncode != 0:
            sys.exit(f"could not set up {scenario}")


# An MkDocs fold-out marker: `??? kind "Title"`, `???+` for open by default.
# Shared with the guard test on the briefs, so both read the same markers.
FOLD = re.compile(r'^\?\?\?\+?\s+[\w-]+(?:\s+"(.*)")?\s*$')


def render(text, colour=True):
    """The brief for a terminal. Fold-outs print dimmed, and the Kubernetes
    ones are marked as skippable, so a platform engineer can skip them."""
    dim, bold, cyan, end = ("\033[2m", "\033[1m", "\033[36m", "\033[0m") if colour else ("",) * 4
    out, code, fold = [], False, False
    for line in text.splitlines():
        # A fence may be indented under a list item. Inside a fold-out an
        # indented line is prose: fold-outs hold no code, by rule.
        if line.startswith("```") or (not fold and line.lstrip().startswith("```")):
            # An unindented fence ends any fold-out, as it does in MkDocs.
            code, fold = not code, False
            continue
        if code:
            out.append(f"{cyan}    {line}{end}")
            continue
        m = FOLD.match(line)
        if m:
            fold = True
            title = m.group(1) or "More detail"
            if title.startswith("Kubernetes:"):
                title += " (skip if you know Kubernetes)"
            out.append(f"{dim}  ▸ {title}{end}")
            continue
        # A fold-out may have paragraphs: a blank line keeps it open, and the
        # first unindented line closes it.
        if fold and (line.startswith("    ") or not line.strip()):
            out.append(f"{dim}  {line}{end}" if line.strip() else "")
            continue
        fold = False
        out.append(f"{bold}{line.lstrip('#').strip()}{end}" if line.startswith("#") else line)
    return "\n".join(out) + "\n"


def record(lab, level):
    """One row in the audit trail, so `make audit` shows which level a session
    was run at. Same row shape as the runner's tool calls."""
    AUDIT.mkdir(parents=True, exist_ok=True)
    row = {"ts": datetime.now(timezone.utc).isoformat(), "mode": "lab", "sa": "-",
           "name": "lab", "args": {"lab": lab, "level": level},
           "result_summary": f"started lab {lab} at {level}", "is_error": False}
    with (AUDIT / f"{datetime.now():%Y%m%d}-lab.jsonl").open("a") as fh:
        fh.write(json.dumps(row) + "\n")


def context(run=subprocess.run):
    """The kubectl context the lab will run against, or "none"."""
    try:
        p = run(["kubectl", "config", "current-context"],
                capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return "none"
    return p.stdout.strip() if p.returncode == 0 and p.stdout.strip() else "none"


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="make lab", usage="make lab LAB=1|2|3 [LEVEL=easy|normal|hard]")
    ap.add_argument("--lab", choices=["1", "2", "3"], required=True)
    ap.add_argument("--level", choices=LEVELS, default="easy")
    a = ap.parse_args(argv)
    # The brief first: a lab without one must fail before the reset.
    brief = BRIEFS / f"lab{a.lab}-{a.level}.md"
    if not brief.exists():
        sys.exit(f"no brief for lab {a.lab} at {a.level} yet: {brief}")
    # Read before setup(), so the header names the context the reset ran against.
    ctx = context()
    setup(a.lab, a.level)
    record(a.lab, a.level)
    print(f"\nLab {a.lab} · level {a.level} · context {ctx}\n")
    # No escape codes when piped to less or captured in a log.
    colour = sys.stdout.isatty() and "NO_COLOR" not in os.environ
    print(render(brief.read_text(), colour=colour))
    return 0


if __name__ == "__main__":
    sys.exit(main())
