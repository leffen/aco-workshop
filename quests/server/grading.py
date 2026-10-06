#!/usr/bin/env python3
"""
Grading: normalise a submission, compare it to a sealed hash, score it.

============================================================================
WORKSHOP NOTE: why the answers are not in this repository
============================================================================

`quests.yaml` ships to the participant's machine along with everything else,
so an `answer:` field in it would be a spoiler with extra steps. Instead the
file carries

    answer_sha256 = sha256("<pepper>:<quest_id>:<normalised answer>")

and the pepper lives in `QUEST_PEPPER`, which is set in `mcp-lab03/.env` and
is not committed. The plaintext sits in `answers.yaml` beside `seal.py`, which
regenerates the hashes; sealing under a real pepper is what makes that file
harmless to read.

Same idea as `fl-devblog`'s per-person completion codes, minus the HMAC.

Normalisation lives HERE and nowhere else. `seal.py` imports it and so does
the server, because the day the two disagree is the day every answer in the
room is suddenly wrong and nobody can see why.
============================================================================
"""

import hashlib
import hmac
import os
import re
import secrets
from dataclasses import dataclass
from typing import Optional

# The pepper the committed hashes were sealed under. Good enough to run the
# stack locally, useless as a secret: it is right here.
DEV_PEPPER = "dev-quest-pepper-change-in-production"

# Scoring, mirrored in quests.yaml:meta.scoring so the quest board can print it.
WRONG_ATTEMPT_PENALTY = 0.10   # of base xp, per wrong attempt
MINIMUM_AWARD = 0.0            # no floor - see below
FIRST_BLOOD_BONUS = 0.25       # +25% for the first correct submission

# There used to be a floor at half the base XP and no rate limit at all, which
# made guessing strictly cheaper than probing: `the-405-wall` is two HTTP status
# codes, a few dozen guesses covers the plausible space, and the worst outcome
# was still 75 XP. Under those rules brute force was a strategy rather than a
# mistake - which is backwards for a quest whose whole subject is sending the
# right request.
#
# So: the award can now reach zero, and wrong answers buy waiting time. The
# schedule is deliberately gentle for the first two tries - a typo should not
# cost a minute - and then bites.
COOLDOWN_SECONDS = {1: 0, 2: 30, 3: 120}
COOLDOWN_MAX = 480             # 8 minutes, from the fourth wrong answer on


def cooldown_after(wrong_attempts: int) -> int:
    """How long to wait before the next attempt, given wrong answers so far."""
    if wrong_attempts <= 0:
        return 0
    return COOLDOWN_SECONDS.get(wrong_attempts, COOLDOWN_MAX)


def pepper() -> str:
    return os.getenv("QUEST_PEPPER") or DEV_PEPPER


def using_dev_pepper() -> bool:
    """True when nobody has set QUEST_PEPPER. Worth a loud log line on boot."""
    return not os.getenv("QUEST_PEPPER")


def normalize(answer: str, case_sensitive: bool = False) -> str:
    """
    Whitespace is noise. Comma spacing is noise. Case usually is too.

    `the-slashed-o` is the exception that sets `case_sensitive: true` - base64
    is case-significant, and "W4V..." is not the same value as "w4v...".
    """
    text = re.sub(r"\s+", "", str(answer or ""))
    return text if case_sensitive else text.lower()


def seal(quest_id: str, answer: str, case_sensitive: bool = False,
         with_pepper: Optional[str] = None) -> str:
    """The hash that goes in quests.yaml."""
    payload = f"{with_pepper or pepper()}:{quest_id}:{normalize(answer, case_sensitive)}"
    return hashlib.sha256(payload.encode()).hexdigest()


def check(quest_id: str, submitted: str, expected_sha256: str,
          case_sensitive: bool = False) -> bool:
    """Constant-time compare of the sealed submission against the sealed answer."""
    actual = seal(quest_id, submitted, case_sensitive)
    return hmac.compare_digest(actual, str(expected_sha256 or ""))


# ---------------------------------------------------------------------------
# Handles and claim tokens
# ---------------------------------------------------------------------------
#
# The handle is the one from website/schema.sql: an invented nickname, not a
# name, <=HANDLE_MAX chars, untrusted, escaped wherever it renders. We collect nothing
# else - no Keycloak subject, no email, no IP.
#
# The first submission under a handle claims it and gets a token back. Every
# later submission must present that token. Without this, anyone can submit as
# anyone, and the score card is a joke by 10:30.

# 255 in the source. Cut to 32 in this fork: handles go on a projector, and a
# 255-character one breaks the board for everyone.
HANDLE_MAX = 32
_HANDLE_STRIP = re.compile(r"[\x00-\x1f\x7f]")


def clean_handle(raw: str) -> str:
    """Trim, drop control characters, cap the length. Never returns None."""
    handle = _HANDLE_STRIP.sub("", str(raw or "")).strip()
    return handle[:HANDLE_MAX]


def mint_claim_token() -> str:
    return secrets.token_urlsafe(24)


def hash_claim_token(token: str) -> str:
    return hashlib.sha256(f"{pepper()}:claim:{token}".encode()).hexdigest()


def claim_token_matches(token: str, stored_hash: str) -> bool:
    return hmac.compare_digest(hash_claim_token(str(token or "")), str(stored_hash or ""))


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

@dataclass
class Award:
    xp: int
    base_xp: int
    wrong_attempts: int
    first_blood: bool
    penalty_factor: float


def award_for(base_xp: int, wrong_attempts: int, first_blood: bool) -> Award:
    """
    award = base x max(0, 1 - 0.10 x wrong) + base x 0.25 if first blood

    Ten wrong answers take the base award to nothing. Nobody is locked out - the
    quest still completes and still counts as solved - but the XP is gone, and
    the cooldown means guessing costs time as well.
    """
    factor = max(MINIMUM_AWARD, 1.0 - WRONG_ATTEMPT_PENALTY * max(0, wrong_attempts))
    # First blood still pays on a zero-factor solve: getting there first is a
    # different achievement from getting there cleanly.
    xp = base_xp * factor
    if first_blood:
        xp += base_xp * FIRST_BLOOD_BONUS
    return Award(
        xp=int(round(xp)),
        base_xp=base_xp,
        wrong_attempts=wrong_attempts,
        first_blood=first_blood,
        penalty_factor=factor,
    )
