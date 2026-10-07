"""
Slash commands at the agent's `you ›` prompt: the make targets a lab needs
between goals, so a lab runs in one window.

    you › /break        runs  make lab1-break
    you › /health       runs  make health

These run as you, never as the agent, and the agent never sees them. They are
not tools on purpose. A make target runs with your credentials, not the
agent's ServiceAccount: `make reset` in the agent's hands would step around
the RBAC ladder. A break the agent planted itself would tell it the answer.
And a referee the agent runs on your behalf is no longer an independent
check. The runner runs them between turns, exactly as if you had typed the
make command in another terminal, and prints that command so you learn it.

Stdlib only, like the rest of the runner.
"""
import json, os, pathlib, re, subprocess
from dataclasses import dataclass
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
AUDIT = ROOT / "agents" / "audit"


@dataclass(frozen=True)
class Command:
    target: str
    help: str
    usage: str = ""
    params: tuple = ()      # the make variables the arguments fill, in order
    changes: bool = False   # changes the namespace: the agent starts afresh
    divider: bool = True    # mark it in the audit trail, if it changes things


COMMANDS = {
    "health":   Command("health", "the referee: is the application working?"),
    "audit":    Command("audit", "every tool call so far, one line each"),
    "ladder":   Command("ladder", "what each rung of the RBAC ladder may do"),
    "break":    Command("lab1-break", "Lab 1: plant an ImagePullBackOff in shopfront",
                        changes=True),
    "chaos":    Command("chaos", "Lab 3: break something, at random or the scenario named",
                        "[scenario]", ("SCENARIO",), changes=True),
    "reset":    Command("reset", "the namespace back to its baseline", changes=True),
    "insecure": Command("insecure", "Lab 2: back to the insecure baseline", changes=True),
    "catch-up": Command("catch-up", "put the namespace where lab N ends", "1|2", ("LAB",),
                        changes=True),
    "lab":      Command("lab", "start a lab: reset, set it up, print the brief",
                        "1|2|3 [easy|normal|hard]", ("LAB", "LEVEL"), changes=True,
                        divider=False),     # make lab marks its own start
}
# Handled by the REPL itself.
BUILTINS = {
    "new":  "forget the conversation; your next goal starts a fresh one",
    "help": "this list",
    "exit": "leave, as an empty line does",
}
# The mode each lab's agent runs in, for the hint after /lab.
LAB_MODE = {"1": "deploy", "2": "harden", "3": "incident"}

# An argument becomes a make variable: VAR=value on make's command line. make
# expands `$` there, so only plain words get that far.
ARG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def plan(line):
    """`/name args` -> (name, argv). argv is None for a builtin.

    Raises ValueError with a message for the participant: an unknown command,
    too many arguments, or an argument that isn't a plain word."""
    name, *args = line[1:].split()
    if name in BUILTINS:
        if args:
            raise ValueError(f"/{name} takes no arguments")
        return name, None
    c = COMMANDS.get(name)
    if c is None:
        raise ValueError(f"no command /{name}. /help lists them")
    if len(args) > len(c.params):
        raise ValueError(f"usage: /{name} {c.usage}".rstrip())
    for a in args:
        if not ARG.match(a):
            raise ValueError(f"{a!r} is not a plain word. usage: /{name} {c.usage}")
    return name, ["make", "--no-print-directory", c.target,
                  *(f"{p}={a}" for p, a in zip(c.params, args))]


def help_text():
    rows = [(f"/{n} {c.usage}".rstrip(), c.help, " ".join(["make", c.target, *(
        f"{p}=…" for p in c.params)])) for n, c in COMMANDS.items()]
    width = max(len(r[0]) for r in rows) + 2
    out = ["Run as you, between goals. The agent does not see them.\n"]
    out += [f"  {cmd:{width}}{text}  \033[2m({make})\033[0m" for cmd, text, make in rows]
    out.append("")
    out += [f"  {'/' + n:{width}}{text}" for n, text in BUILTINS.items()]
    return "\n".join(out) + "\n"


def environment(operator_kubeconfig, ns):
    """Your environment, pinned to the cluster the session started on.

    Not the agent's: its KUBECONFIG holds the ServiceAccount token. And not
    the ambient context either, which can move under a running session. The
    make variables of the `make agent` that started us are dropped, so they
    don't leak into this make."""
    env = {k: v for k, v in os.environ.items()
           if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
    return {**env, "KUBECONFIG": operator_kubeconfig, "NAMESPACE": ns}


def run(argv, env, popen=subprocess.Popen):
    """Run a make command in the foreground. -> its exit status, 130 if you
    stopped it. Ctrl-C reaches make too, as it shares the terminal; this waits
    for it to finish rather than leave it running behind the prompt."""
    try:
        p = popen(argv, cwd=ROOT, env=env)
    except FileNotFoundError:
        print(f"\033[31m{argv[0]} is not installed. Run the command in a terminal instead.\033[0m")
        return 127
    try:
        return p.wait()
    except KeyboardInterrupt:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        return 130


def record(argv, status):
    """A divider in the audit trail, so `make audit` shows where you changed
    the namespace between the agent's calls. Same row shape as `make lab`'s."""
    AUDIT.mkdir(parents=True, exist_ok=True)
    command = " ".join(a for a in argv if a != "--no-print-directory")
    row = {"ts": datetime.now(timezone.utc).isoformat(), "mode": "you", "sa": "-",
           "name": "make", "args": {"command": command},
           "result_summary": f"you ran {command}, exit {status}", "is_error": status != 0}
    with (AUDIT / f"{datetime.now():%Y%m%d}-you.jsonl").open("a") as fh:
        fh.write(json.dumps(row) + "\n")
