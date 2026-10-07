"""
Turn a Claude Code transcript into the record evals/run.py expects.

Accepts either stream-json from `claude -p --output-format stream-json --verbose`,
or an interactive session file: both carry the same assistant/user message shapes;
only headless output ends in a `result` line.

The debugging PATH is the teaching material, so every tool call is kept, paired
with its result. The final answer is the least interesting field here.
"""
import json

SUMMARY_CHARS = 300


def _text(content):
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in content or [] if isinstance(b, dict))


def _message(e):
    """The event's message object, or {}. Not every event's `message` is one:
    system/permission_denied carries the refusal as plain text."""
    m = e.get("message")
    return m if isinstance(m, dict) else {}


def summarise(events):
    calls, by_id, last_text, turns, result = [], {}, "", 0, None
    peak = None     # largest single request: what must fit the context window
    for e in events:
        kind = e.get("type")
        if kind == "assistant":
            turns += 1
            u = _message(e).get("usage")
            if u:
                size = sum(u.get(k) or 0 for k in (
                    "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
                peak = size if peak is None else max(peak, size)
            content = _message(e).get("content")
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    last_text = b["text"].strip()
                elif b.get("type") == "tool_use":
                    call = {"name": b["name"], "args": b.get("input", {}),
                            "result_summary": "", "is_error": False}
                    by_id[b["id"]] = call
                    calls.append(call)
        elif kind == "user":
            content = _message(e).get("content")
            for b in content if isinstance(content, list) else []:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in by_id:
                    call = by_id[b["tool_use_id"]]
                    call["result_summary"] = _text(b.get("content"))[:SUMMARY_CHARS]
                    call["is_error"] = bool(b.get("is_error"))
        elif kind == "result":
            result = e

    r = result or {}
    usage = r.get("usage", {})
    subtype = r.get("subtype", "success")
    # An unauthenticated run reports subtype "success" with is_error set and the
    # error text in `result`. Trust is_error over the subtype, and never let an
    # error message pass as the agent's report. What the agent itself wrote
    # before the error still counts: a run that ran out of turns keeps it.
    if r.get("is_error"):
        error = (r.get("result") if subtype == "success" else subtype) or subtype
        report = last_text
    else:
        error = None if subtype == "success" else subtype
        report = r.get("result") or last_text
    return {
        "report": report,
        "iterations": r.get("num_turns", turns),
        "tool_calls": calls,
        "input_tokens": (usage.get("input_tokens", 0)
                         + usage.get("cache_creation_input_tokens", 0)
                         + usage.get("cache_read_input_tokens", 0)) if result else None,
        "output_tokens": usage.get("output_tokens") if result else None,
        "peak_context_tokens": peak,
        "cost_usd": r.get("total_cost_usd"),
        "session_id": r.get("session_id"),
        # Calls the permission layer refused before they reached any tool.
        "permission_denials": [d.get("tool_name") for d in r.get("permission_denials", [])],
        "error": error,
    }


def read_jsonl(lines):
    """Parse JSONL, skipping blank and non-JSON lines (the CLI may print warnings)."""
    out = []
    for line in lines:
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out
