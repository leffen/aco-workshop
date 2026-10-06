#!/usr/bin/env python3
"""
The quest board from a terminal. What make quest-list, quest-show, quest-submit
and quest-board run.

    QUEST_SERVER=<url> quests/cli.py list
    QUEST_SERVER=<url> QUEST_ID=<id> quests/cli.py show
    QUEST_SERVER=<url> QUEST_ID=<id> QUEST_ANSWER=<answer> [QUEST_HANDLE=<h>] quests/cli.py submit
    QUEST_SERVER=<url> quests/cli.py board

Everything comes in through the environment, never through argv or a shell
string: a proof string carries `:` and `,`, an answer may carry quotes, and
zsh and bash disagree about splitting. The Makefile hands ANSWER over with
`$(value ...)`, so not even make expands it.

It speaks MCP 2026-07-28 to the server's one endpoint, POST <server>/message:
`params._meta` in the body, mirrored in the MCP-Protocol-Version, Mcp-Method
and Mcp-Name headers (quests/server/mcp_protocol.py).

The claim token a handle gets on its first submission is kept in
.local/quests.json (gitignored, mode 0600), keyed by server, so a local server
and hlutur never mix and nobody retypes it.

Nothing from the server reaches the terminal unchecked. Text - quest cards,
other people's handles - is stripped of control characters and escape
sequences; a number must be an integer, or the reply is refused as malformed.
Replies are capped at 1 MiB and a deadline, and redirects are refused.

Stdlib only, on purpose: participants run this without a pip install.
"""
import io
import json
import os
import pathlib
import re
import shutil
import sys
import textwrap
import time
import unicodedata
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2026-07-28"
CLIENT_INFO = {"name": "aco-quest-cli", "version": "1.0.0"}
ROOT = pathlib.Path(__file__).resolve().parent.parent
STORE = ROOT / ".local" / "quests.json"
STORE_SHOWN = ".local/quests.json"
DEFAULT_SERVER = "https://quests.aco.hlutur.no"
TIMEOUT = 15          # seconds, for the whole exchange, not per read
MAX_REPLY = 1 << 20   # bytes
BOARD_ROWS = 10


class Failure(Exception):
    """One line for the participant, and a non-zero exit. Never a traceback."""


MALFORMED = "the quest server sent a reply this client doesn't understand"


class Malformed(Failure):
    def __init__(self):
        super().__init__(MALFORMED)


def num(value, default="?"):
    """A number from the server, as text. Anything but an integer is malformed:
    it would otherwise go to the terminal as whatever the server chose."""
    if value is None:
        return default
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    raise Malformed()


def rows_of(value):
    """A list of dicts from the server, or malformed."""
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, dict) for v in value):
        raise Malformed()
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """The endpoint never redirects. A redirect is a misconfigured or hostile
    server, and following one would re-send the claim token somewhere else."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Failure("the quest server redirected; refusing")


OPENER = urllib.request.build_opener(NoRedirect)


# --- untrusted text ---------------------------------------------------------------

# CSI (ESC [ ... final), OSC (ESC ] ... BEL or ST), and any other two-byte ESC form.
_ESCAPES = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b.?")


def clean(text, keep_newlines=False):
    """Strip escape sequences, control and format characters (bidi overrides
    included). Newlines survive only where asked; elsewhere they become spaces."""
    text = _ESCAPES.sub("", str(text if text is not None else ""))
    kept = []
    for ch in text:
        if ch == "\n":
            kept.append("\n" if keep_newlines else " ")
        elif ch == "\t":
            kept.append(" ")
        elif unicodedata.category(ch) in ("Cc", "Cf"):
            continue
        else:
            kept.append(ch)
    return "".join(kept)


# --- the server ------------------------------------------------------------------

def server_base(raw):
    base = (raw or DEFAULT_SERVER).strip().rstrip("/")
    if base.endswith("/message"):
        base = base[: -len("/message")]
    if not re.match(r"^https?://[^/\s]+", base):
        raise Failure(f"QUEST_SERVER must be an http:// or https:// URL, not '{clean(raw)}'")
    return base


class Client:
    def __init__(self, base, opener=OPENER.open):
        self.base = base
        self.opener = opener
        self.next_id = 1

    def call(self, tool, arguments):
        """tools/call -> (structuredContent, text). Raises Failure on anything else."""
        body = {
            "jsonrpc": "2.0", "id": self.next_id, "method": "tools/call",
            "params": {
                "name": tool, "arguments": arguments,
                "_meta": {
                    "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
                    "io.modelcontextprotocol/clientCapabilities": {},
                    "io.modelcontextprotocol/clientInfo": CLIENT_INFO,
                },
            },
        }
        self.next_id += 1
        req = urllib.request.Request(
            self.base + "/message", data=json.dumps(body).encode(), method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "MCP-Protocol-Version": PROTOCOL_VERSION,
                "Mcp-Method": "tools/call",
                "Mcp-Name": tool,
            })
        status, raw = self._send(req)
        try:
            reply = json.loads(raw)
        except ValueError:
            raise Failure(f"unexpected reply from {self.base} (HTTP {status}): not JSON")
        if not isinstance(reply, dict):
            raise Malformed()
        if "error" in reply:
            if not isinstance(reply["error"], dict):
                raise Malformed()
            raise RpcError(reply["error"])
        result = reply.get("result")
        if not isinstance(result, dict):
            raise Malformed()
        content = result.get("content") or []
        structured = result.get("structuredContent") or {}
        if not isinstance(content, list) or not isinstance(structured, dict):
            raise Malformed()
        text = " ".join(str(c.get("text", "")) for c in content if isinstance(c, dict))
        if result.get("isError"):
            raise Failure(f"the quest server reported an error: {clean(text)}")
        return structured, text

    def _send(self, req):
        deadline = time.monotonic() + TIMEOUT
        try:
            try:
                with self.opener(req, timeout=TIMEOUT) as resp:
                    return getattr(resp, "status", 200), self._read(resp, deadline)
            except urllib.error.HTTPError as exc:
                # A JSON-RPC error rides on a 4xx; its body is the answer. Read
                # outside this handler, so a timeout or reset while reading it
                # lands in the network handlers below, not in a traceback.
                http_error = exc
            with http_error:
                return http_error.code, self._read(http_error, deadline)
        except urllib.error.URLError as exc:
            raise Failure(f"can't reach {self.base}: {exc.reason}")
        except (OSError, ValueError) as exc:
            raise Failure(f"can't reach {self.base}: {exc}")

    def _read(self, resp, deadline):
        """At most MAX_REPLY bytes, before the deadline. The socket timeout is
        per read, so a server dripping a byte at a time would never trip it."""
        read = getattr(resp, "read1", None) or resp.read
        chunks, size = [], 0
        while True:
            if time.monotonic() > deadline:
                raise Failure(f"{self.base} took too long to reply; giving up")
            chunk = read(65536)
            if not chunk:
                return b"".join(chunks)
            size += len(chunk)
            if size > MAX_REPLY:
                raise Failure(f"the reply from {self.base} is too large; refusing it")
            chunks.append(chunk)


class RpcError(Failure):
    def __init__(self, error):
        error = error if isinstance(error, dict) else {}
        self.code = error.get("code")
        self.message = clean(error.get("message", "unknown error"))
        super().__init__(self.message)


# --- the token store ------------------------------------------------------------

def load_store(path):
    try:
        data = json.loads(pathlib.Path(path).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_store(path, data):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # O_NOFOLLOW: a symlink planted at the path must not redirect the token.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    # O_CREAT's mode does not apply to an existing file: narrow it before the
    # token is written, not after.
    os.fchmod(fd, 0o600)
    os.ftruncate(fd, 0)
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def try_save(path, data, out):
    """Save, or say in one line why not, and return whether it saved. Never
    raise: by now the server has claimed the handle, and a traceback here
    would lose the only copy."""
    try:
        save_store(path, data)
        return True
    except OSError as exc:
        print(f"couldn't save it to {STORE_SHOWN}: {clean(exc)}; copy the token above.",
              file=out)
        return False


# --- the commands ---------------------------------------------------------------

def width():
    return max(40, min(shutil.get_terminal_size((80, 24)).columns, 88))


def cmd_list(client, env, out, store):
    data, _ = client.call("list_quests", {})
    quests = rows_of(data.get("quests"))
    if not quests:
        print("No quests on the board.", file=out)
        return 0
    rows = [(clean(q.get("id")), clean(q.get("title")), clean(q.get("difficulty")),
             num(q.get("xp_reward"), ""), num(q.get("solvedBy"), "")) for q in quests]
    head = ("QUEST", "TITLE", "LEVEL", "XP", "SOLVED BY")
    cols = [max(len(r[i]) for r in rows + [head]) for i in range(5)]
    for r in [head] + rows:
        print("  ".join(v.ljust(cols[i]) if i < 3 else v.rjust(cols[i])
                        for i, v in enumerate(r)).rstrip(), file=out)
    print("\nThe assignment: make quest-show QUEST=<quest>", file=out)
    return 0


def _para(text, out, indent=""):
    w = width()
    for block in clean(text, keep_newlines=True).strip().split("\n\n"):
        print(textwrap.fill(" ".join(block.split()), w, initial_indent=indent,
                            subsequent_indent=indent), file=out)
        print("", file=out)


def cmd_show(client, env, out, store):
    quest = env.get("QUEST_ID", "").strip()
    if not quest:
        raise Failure("usage: make quest-show QUEST=<quest>   (make quest-list shows them)")
    card, _ = client.call("get_quest", {"quest_id": quest})
    real_out, out = out, io.StringIO()   # nothing is printed until all of it checks out
    print(f"{clean(card.get('title'))}  ({clean(card.get('id', quest))})", file=out)
    print(f"{clean(card.get('difficulty'))}, {num(card.get('xp_reward'))} XP, "
          f"solved by {num(card.get('solvedBy'), '0')}\n", file=out)
    if card.get("description"):
        _para(card["description"], out)
    if card.get("quest_text"):
        _para(card["quest_text"], out)
    objectives = rows_of(card.get("objectives"))
    if objectives:
        print("Objectives:", file=out)
        for o in objectives:
            print(textwrap.fill(clean(o.get("title")), width(), initial_indent="  - ",
                                subsequent_indent="    "), file=out)
        print("", file=out)
    print(textwrap.fill("Answer format: " + clean(card.get("answer_format", "see above")),
                        width()), file=out)
    print(f"Submit: make quest-submit QUEST={clean(card.get('id', quest))} ANSWER=<answer>",
          file=out)
    real_out.write(out.getvalue())
    return 0


def verdict(quest, s):
    """One line, plain words, from the server's structuredContent."""
    if s.get("sealed") is False:
        return f"{quest} isn't sealed yet, so it can't be graded. Nothing was recorded."
    if s.get("cooldown"):
        return (f"Too soon: wait {num(s.get('retryAfterSeconds'))}s before the next "
                f"attempt on {quest}. Do the lab instead of guessing.")
    if s.get("alreadySolved"):
        return f"You have already solved {quest}. No XP twice."
    if s.get("correct"):
        line = f"Correct: +{num(s.get('xpAwarded'), '0')} XP"
        line += " (first blood!)" if s.get("firstBlood") is True else ""
        line += f". {num(s.get('totalXp'))} XP total, rank {num(s.get('rank'))}"
        if s.get("of"):
            line += f", {num(s.get('solved'))} of {num(s['of'])} quests solved"
        return line + "."
    line = (f"Wrong. Attempt {num(s.get('attempts'))}; {quest} is now worth "
            f"{num(s.get('xpIfSolvedNow'))} XP to you")
    wait = num(s.get("retryAfterSeconds"), "0")
    return line + (f", and the next attempt opens in {wait}s." if wait != "0" else ".")


def cmd_submit(client, env, out, store):
    quest = env.get("QUEST_ID", "").strip()
    answer = env.get("QUEST_ANSWER", "")
    if not quest or not answer.strip():
        raise Failure("usage: make quest-submit QUEST=<quest> ANSWER=<answer> [HANDLE=<handle>]")

    saved = load_store(store)
    mine = saved.get(client.base) if isinstance(saved.get(client.base), dict) else {}
    tokens = mine.get("claim_tokens") if isinstance(mine.get("claim_tokens"), dict) else {}
    handle = env.get("QUEST_HANDLE", "").strip() or mine.get("handle", "")
    if not handle:
        raise Failure("no handle yet: the first submission claims one. "
                      f"make quest-submit QUEST={quest} ANSWER=<answer> HANDLE=<handle>")

    arguments = {"quest_id": quest, "username": handle, "answer": answer}
    if tokens.get(handle):
        arguments["claim_token"] = tokens[handle]
    try:
        s, _ = client.call("submit_answer", arguments)
    except RpcError as exc:
        if exc.message.startswith("Invalid params: unknown quest"):
            raise Failure(f"there is no quest '{clean(quest)}'. make quest-list shows them.")
        raise Failure(f"the quest server said: {exc.message}")

    print(clean(verdict(clean(quest), s)), file=out)

    token = s.get("claimToken")
    if token is not None and not isinstance(token, str):
        raise Malformed()
    if token:
        # Printed before it is saved: if the save fails, this is the only copy.
        print(f"\nYou claimed the handle '{clean(handle)}'. Its claim token: {clean(token)}",
              file=out)
        tokens[handle] = token
        saved[client.base] = {"handle": handle, "claim_tokens": tokens}
        if try_save(store, saved, out):
            print(f"It is stored in {STORE_SHOWN}, so later submissions need no HANDLE; "
                  "keep a copy if you switch laptops.", file=out)
    elif handle != mine.get("handle") and tokens.get(handle):
        saved[client.base] = {"handle": handle, "claim_tokens": tokens}
        try_save(store, saved, out)
    return 0


def cmd_board(client, env, out, store):
    data, _ = client.call("get_scoreboard", {"limit": BOARD_ROWS})
    players = rows_of(data.get("players"))
    if not players:
        print("Nobody on the board yet. First blood is worth 25% extra.", file=out)
        return 0
    hw = max(len("HANDLE"), *(len(clean(p.get("handle"))) for p in players))
    lines = [f"{'#':>3}  {'HANDLE'.ljust(hw)}  {'XP':>5}  SOLVED"] + [f"{num(p.get('rank'), ''):>3}  {clean(p.get('handle')).ljust(hw)}  "
             f"{num(p.get('xp'), '0'):>5}  {num(p.get('solved'), '0'):>6}" for p in players]
    print("\n".join(lines), file=out)   # all rows checked before any is printed
    return 0


COMMANDS = {"list": cmd_list, "show": cmd_show, "submit": cmd_submit, "board": cmd_board}


def main(argv=None, environ=None, opener=OPENER.open, store=STORE, out=None):
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if environ is None else environ
    out = out or sys.stdout
    if len(argv) != 1 or argv[0] not in COMMANDS:
        print(f"usage: quests/cli.py {'|'.join(COMMANDS)}", file=out)
        return 2
    try:
        client = Client(server_base(env.get("QUEST_SERVER")), opener=opener)
        return COMMANDS[argv[0]](client, env, out, store)
    except Failure as exc:
        print(clean(str(exc)), file=out)
        return 1
    except (AttributeError, TypeError, KeyError, ValueError):
        # A shape this client did not anticipate. Still one line, never a traceback.
        print(MALFORMED, file=out)
        return 1


if __name__ == "__main__":
    sys.exit(main())
