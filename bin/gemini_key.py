#!/usr/bin/env python3
"""
make gemini-key

Puts the Gemini key the facilitator gave you into .env, with ACO_HARNESS set to
pi-gemini, and checks it with one tiny call. The key is asked for at a hidden
prompt: it never shows on screen and never lands in your shell history.

Only for the participants who were handed a key (bootstrap/gemini-key.sh give).
Every other line of .env is kept as it is. Stdlib only.
"""
import getpass, json, os, pathlib, re, sys, tempfile, urllib.request, urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV = ROOT / ".env"
MODEL = "gemini-3.8-flash"          # the workshop's pin: generic_agent/run.py
# A gcloud key (AIza + 35) or an AI Studio one (AQ. + more, 53 chars on 2026-10-25).
KEY = re.compile(r"^(AIza[0-9A-Za-z_-]{35}|AQ\.[0-9A-Za-z_.-]{20,})$")
SETS = ("ACO_HARNESS", "GEMINI_API_KEY")


def with_key(text, key):
    """.env with ACO_HARNESS and GEMINI_API_KEY set, every other line kept."""
    keep = [l for l in text.splitlines()
            if not re.match(rf"^\s*(export\s+)?({'|'.join(SETS)})\s*=", l)]
    while keep and not keep[-1].strip():
        keep.pop()
    return "\n".join(keep + ["", "# make gemini-key", "ACO_HARNESS=pi-gemini",
                             f"GEMINI_API_KEY={key}"]) + "\n"


def write_private(path, text):
    """Replace path in one step, readable by you only."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".env.")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def check(key):
    """-> (ok, message), from one tiny call."""
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent",
        data=json.dumps({"contents": [{"parts": [{"text": "Reply with OK"}]}],
                         "generationConfig": {"maxOutputTokens": 64}}).encode(),
        headers={"Content-Type": "application/json", "X-goog-api-key": key})
    try:
        urllib.request.urlopen(req, timeout=120)
        return True, "the key works"
    except urllib.error.HTTPError as e:
        msg = json.loads(e.read() or b"{}").get("error", {}).get("message", "")
        if e.code in (429, 503) and "free_tier" not in msg:
            return True, "the key works; the API is busy right now, so the first run may wait"
        if e.code == 402:
            return False, "the workshop's credit has run out: tell the facilitator"
        if e.code in (400, 403):
            return False, "Google does not accept this key: check you copied all of it, or ask for a new one"
        return False, f"HTTP {e.code}: {msg[:160]}"
    except OSError as e:
        # No answer is not a no: Google was slow or unreachable (2026-10-26: a
        # 120 s timeout, then fine). Save it; agent-check will tell.
        return True, f"saved, but not confirmed: Google did not answer ({e})"


def main():
    print("Paste the Gemini key you were given (it starts with AIza or AQ.). It will not show.")
    try:
        key = getpass.getpass("key › ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return 130
    if not KEY.match(key):
        print("\033[31mThat does not look like a Gemini key: it starts with AIza or AQ.\033[0m")
        return 1
    ok, message = check(key)
    if not ok:
        print(f"\033[31m{message}. .env is unchanged.\033[0m")
        return 1
    write_private(ENV, with_key(ENV.read_text() if ENV.exists() else "", key))
    print(f"\033[32m{message}.\033[0m .env now has ACO_HARNESS=pi-gemini and your key.")
    print("Next: make agent-check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
