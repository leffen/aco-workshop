#!/usr/bin/env bash
# Gemini API keys for the participants who need one, each their own, behind a
# hard spend limit. For the facilitator, not the participants.
#
#   bootstrap/gemini-key.sh up     PROJECT [BILLING_ACCOUNT]   project and API, once
#   bootstrap/gemini-key.sh give   PROJECT NAME                a key for NAME, as a one-time link
#   bootstrap/gemini-key.sh who    PROJECT                     who holds a key; has the link been opened?
#   bootstrap/gemini-key.sh revoke PROJECT NAME                cut NAME's key off, burn an unopened link
#   bootstrap/gemini-key.sh check  PROJECT                     one tiny call per key
#   bootstrap/gemini-key.sh down   PROJECT                     delete every workshop key
#
#   TTL=28800      give: seconds the link lives (8 h). One view, then it is gone
#   CLIPBOARD=1    give: no link; the key goes to the macOS clipboard, for a DM
#   OTS=https://eu.onetimesecret.com   give: the one-time-secret server (EU data)
#   BUDGET=50      up, with a billing account: a budget alert. An alert, not a limit
#   DRY_RUN=1      print every gcloud command and run none
#
# One key per person, made when they ask: nobody holds a key you did not hand
# them, a leak has a name on it, and revoke cuts off one person, not the room.
# The participant runs `make gemini-key` and pastes the key at a hidden prompt.
#
# The spend limit itself cannot be scripted: Google offers no API for it. It is
# prepaid credit with auto-reload off (at $0 every key on the billing account
# fails with HTTP 402), plus AI Studio's project spend cap. `up` lists them.
#
# The key is never printed. `give` keeps only the link's receipt, in
# .local/gemini-keys/<project>/shares.tsv (git-ignored), so `who` can tell
# whether a link was opened and `revoke` can burn one that was not.
set -uo pipefail
cd "$(dirname "$0")/.."

CMD="${1:-}" PROJECT="${2:-}" ARG="${3:-}"
BUDGET="${BUDGET:-50}" DRY="${DRY_RUN:-0}" TTL="${TTL:-28800}"
OTS="${OTS:-https://eu.onetimesecret.com}"
API=generativelanguage.googleapis.com
MODEL=gemini-3.8-flash          # the workshop's pin: generic_agent/run.py
PREFIX="ACO workshop"           # every key's display name starts with this
OUT=".local/gemini-keys/$PROJECT"
SHARES="$OUT/shares.tsv"

say()  { printf '==> %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
fail() { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { printf '  + %s\n' "$*" >&2; [ "$DRY" = 1 ] || "$@"; }

usage() { sed -n '5,10p' "$0" | sed 's/^# //'; exit 2; }
[ -n "$PROJECT" ] || usage

preconditions() {
  command -v gcloud >/dev/null || fail "gcloud is not installed: https://cloud.google.com/sdk/docs/install"
  [ "$DRY" = 1 ] || [ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ] \
    || fail "gcloud is not logged in. Run: gcloud auth login"
}

# A person's name becomes part of a key's display name: plain words only.
person() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || fail "NAME must be lowercase letters, digits and dashes, e.g. kari or table-3"
}

# The full resource name of the live (not deleted) key with this display name.
# By name, not ID: a deleted key is kept for 30 days, its ID can't be reused,
# and describe/get-key-string still answer for it. list leaves it out.
live_key() {
  gcloud services api-keys list --project="$PROJECT" \
    --filter="displayName=\"$1\"" --format='value(name)' 2>/dev/null | head -n 1
}

# Every live workshop key: "name<TAB>display name". A failed list is not an
# empty one, so it fails rather than return nothing.
workshop_keys() {
  gcloud services api-keys list --project="$PROJECT" \
    --filter="displayName~\"^$PREFIX \"" --format='value(name,displayName)' 2>/dev/null
}

key_string() {
  gcloud services api-keys get-key-string "$1" --format='value(keyString)' 2>/dev/null </dev/null
}

# Make a key. gcloud reports the new key, keyString and all, on stderr
# (2026-10-26): keep it, and show only an error, with any key line taken out.
create_key() {
  local err
  err=$(run gcloud services api-keys create --project="$PROJECT" \
    --display-name="$1" --api-target=service="$API" 2>&1 >/dev/null) \
    || { warn "could not create $1: $(printf '%s\n' "$err" | grep -v keyString | tail -n 3)"; return 1; }
  printf '%s\n' "$err" | grep '^  + '
}

delete_key() {   # delete reports the key string on stderr too: as above
  local err
  err=$(run gcloud services api-keys delete "$1" --quiet 2>&1 >/dev/null </dev/null) \
    || { warn "could not delete $1: $(printf '%s\n' "$err" | grep -v keyString | tail -n 3)"; return 1; }
  printf '%s\n' "$err" | grep '^  + '
}

# onetimesecret, API v2 (api.onetimesecret.com/doc/api-v2.json, 2026-10-24).
# The key reaches Python through the environment, never argv. The response
# carries the secret back (record.secret.secret_value), so only the two
# identifiers are read from it, and nothing else is printed.
ots() {   # conceal | state RECEIPT | burn RECEIPT
  python3 -I - "$OTS" "$@" <<'PY'
import json, os, sys, urllib.request, urllib.error
base, op, *rest = sys.argv[1:]

def call(method, path, body=None):
    req = urllib.request.Request(base + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read() or b"{}")
        except ValueError:
            err = {}
        sys.exit(f"onetimesecret: HTTP {e.code} {err.get('error') or err.get('message') or ''}".strip())
    except OSError as e:
        sys.exit(f"onetimesecret: {e}")

if op == "conceal":
    d = call("POST", "/api/v2/guest/secret/conceal", {"secret": {
        "kind": "conceal", "share_domain": "", "secret": os.environ["ACO_SECRET"],
        "ttl": int(os.environ["ACO_TTL"])}})
    rec = d.get("record") or {}
    sid = (rec.get("secret") or {}).get("identifier")
    rid = (rec.get("receipt") or {}).get("identifier")
    if not sid or not rid:
        sys.exit("onetimesecret: no identifiers in the reply (has the API changed?)")
    print(f"{base}/secret/{sid}\t{rid}")
elif op == "state":
    d = call("GET", f"/api/v2/guest/receipt/{rest[0]}")
    print(((d.get("record") or {}).get("state")) or "unknown")
elif op == "burn":
    call("POST", f"/api/v2/guest/receipt/{rest[0]}/burn", {"continue": "true"})
    print("burned")
PY
}

up() {
  preconditions
  if gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
    say "project $PROJECT exists; keeping it"
  else
    say "creating project $PROJECT"
    run gcloud projects create "$PROJECT" --name="ACO workshop" || fail "could not create $PROJECT (project IDs are global: try another)"
  fi

  if [ -n "$ARG" ]; then
    say "linking billing account $ARG"
    run gcloud billing projects link "$PROJECT" --billing-account="$ARG" >/dev/null \
      || fail "could not link $ARG. Your accounts: gcloud billing accounts list"
    if gcloud billing budgets list --billing-account="$ARG" \
         --format='value(displayName)' 2>/dev/null | grep -qx "$PROJECT"; then
      say "budget alert $PROJECT exists; keeping it"
    else
      say "budget alert: $BUDGET USD (email at 50, 90, 100 %)"
      run gcloud billing budgets create --billing-account="$ARG" \
        --display-name="$PROJECT" --budget-amount="${BUDGET}USD" \
        --filter-projects="projects/$PROJECT" \
        --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
        >/dev/null || warn "no budget alert (needs Billing Account Administrator). The prepaid credit still limits spend."
    fi
  fi

  say "enabling the Gemini API"
  run gcloud services enable "$API" apikeys.googleapis.com --project="$PROJECT" || fail "could not enable $API"

  cat <<EOF

==> Now in AI Studio, as only you can (Google has no API for these):

  1. https://aistudio.google.com/projects → Import project → $PROJECT
  2. Its Billing Tier column → Set up billing → choose PREPAY, buy the credit
     you are willing to lose (about \$1.50 per participant for the three easy labs,
     measured 2026-10-26). A billing account of its own: at \$0 every project on it stops.
  3. https://aistudio.google.com/billing → auto-reload: leave it OFF.
     That is the hard limit: at \$0 the keys fail with HTTP 402.
  4. https://aistudio.google.com/spend → Monthly spend cap → the same amount.
     Experimental, and like the credit it lags about 10 minutes.

  Then, for each participant who asks: bootstrap/gemini-key.sh give $PROJECT <name>
  After the workshop:                  bootstrap/gemini-key.sh down $PROJECT

EOF
}

give() {
  preconditions
  person "$ARG"
  local label="$PREFIX $ARG" name key share receipt
  name=$(live_key "$label")
  if [ -n "$name" ]; then
    say "$ARG already has a key; handing out the same one again"
  else
    say "a key for $ARG, allowed the Gemini API only"
    create_key "$label" || exit 1
    [ "$DRY" = 1 ] && { echo "  (dry run: no link)"; return; }
    name=$(live_key "$label")
  fi
  key=$(key_string "$name") && [ -n "$key" ] || fail "could not read the key for $ARG"

  if [ "${CLIPBOARD:-0}" = 1 ]; then
    command -v pbcopy >/dev/null || fail "CLIPBOARD=1 needs pbcopy (macOS)"
    printf '%s' "$key" | pbcopy
    say "the key is on your clipboard: paste it into a direct message to $ARG"
    echo "    $ARG then runs: make gemini-key"
    return
  fi

  share=$(ACO_SECRET="$key" ACO_TTL="$TTL" ots conceal) \
    || fail "no link made. The key exists; try again, or CLIPBOARD=1 bootstrap/gemini-key.sh give $PROJECT $ARG"
  receipt=${share#*$'\t'} share=${share%%$'\t'*}
  mkdir -p "$OUT" && chmod 700 "$OUT"
  (umask 077; printf '%s\t%s\t%s\n' "$ARG" "$receipt" "$(date +%FT%T)" >> "$SHARES")
  say "one-time link for $ARG, valid $((TTL / 3600)) h, one view:"
  echo ""
  echo "    $share"
  echo ""
  echo "    Send it to $ARG alone. They open it, copy the key, and run: make gemini-key"
  echo "    If they find it already opened, someone else saw it: bootstrap/gemini-key.sh revoke $PROJECT $ARG"
}

who() {
  preconditions
  local keys n=0 label person receipt state
  keys=$(workshop_keys) || fail "could not list the keys in $PROJECT"
  [ -n "$keys" ] || { say "no workshop keys in $PROJECT"; return; }
  say "live keys in $PROJECT"
  while IFS=$'\t' read -r _ label; do
    person=${label#"$PREFIX "} n=$((n + 1))
    receipt=$(awk -F'\t' -v p="$person" '$1 == p {r = $2} END {print r}' "$SHARES" 2>/dev/null)
    if [ -n "$receipt" ]; then state="link $(ots state "$receipt" 2>/dev/null || echo unknown)"
    else state="no link on record"; fi
    printf '    %-24s %s\n' "$person" "$state"
  done <<< "$keys"
  echo "  $n key(s). A link that is 'revealed' has been opened; 'new' or 'shared' not yet."
}

revoke() {
  preconditions
  person "$ARG"
  local name receipt
  name=$(live_key "$PREFIX $ARG")
  receipt=$(awk -F'\t' -v p="$ARG" '$1 == p {r = $2} END {print r}' "$SHARES" 2>/dev/null)
  if [ -n "$receipt" ] && [ "$DRY" != 1 ]; then
    ots burn "$receipt" >/dev/null 2>&1 && echo "  burned $ARG's link" || echo "  $ARG's link was already opened or expired"
  fi
  if [ -z "$name" ]; then say "$ARG has no live key"; return; fi
  delete_key "$name" && say "$ARG's key is deleted: it stops working at once. Nobody else is affected."
}

check() {
  preconditions
  local keys key label
  if [ "$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null)" = True ]; then
    say "billing is linked to $PROJECT"
  else
    warn "no billing on $PROJECT (or gcloud cannot see it): free tier, 20 requests a day"
  fi
  keys=$(workshop_keys) || fail "could not list the keys in $PROJECT"
  [ -n "$keys" ] || { say "no workshop keys yet: bootstrap/gemini-key.sh give $PROJECT <name>"; return; }
  say "one tiny call per key to $MODEL"
  while IFS=$'\t' read -r name label; do
    printf '  %-24s ' "${label#"$PREFIX "}"
    key=$(key_string "$name") || { echo "FAIL: could not read the key"; continue; }
    ACO_KEY="$key" python3 -I - "$MODEL" <<'PY'
import json, os, sys, urllib.request, urllib.error
req = urllib.request.Request(
    f"https://generativelanguage.googleapis.com/v1beta/models/{sys.argv[1]}:generateContent",
    data=json.dumps({"contents": [{"parts": [{"text": "Reply with OK"}]}],
                     "generationConfig": {"maxOutputTokens": 64}}).encode(),
    headers={"Content-Type": "application/json", "X-goog-api-key": os.environ["ACO_KEY"]})
try:
    urllib.request.urlopen(req, timeout=120)
    print("OK")
except urllib.error.HTTPError as e:
    msg = json.loads(e.read() or b"{}").get("error", {}).get("message", "")
    if e.code == 402:
        print("NO CREDIT (402): buy prepaid credit in AI Studio")
    elif e.code == 429 and "free_tier" in msg:
        print("FREE TIER (429): set up billing in AI Studio")
    elif e.code in (429, 503):
        print(f"BUSY ({e.code}): the key works, the API is throttling. Try again shortly")
    else:
        print(f"FAIL ({e.code}): {msg[:160]}")
except Exception as e:
    print(f"FAIL: {e}")
PY
  done <<< "$keys"
}

down() {
  preconditions
  local keys label receipt
  keys=$(workshop_keys) || fail "could not list the keys in $PROJECT; nothing deleted"
  if [ -z "$keys" ]; then
    say "no workshop keys in $PROJECT"
    [ "$DRY" = 1 ] || rm -rf "$OUT"
    return
  fi
  say "about to delete every workshop key in $PROJECT; anyone still using one is cut off:"
  printf '%s\n' "$keys" | cut -f2 | sed "s/^$PREFIX /    /"
  if [ "${YES:-}" != yes ] && [ "$DRY" != 1 ]; then
    read -r -p "Type the project ID to confirm: " confirm
    [ "$confirm" = "$PROJECT" ] || { echo "Aborted."; exit 1; }
  fi
  while IFS=$'\t' read -r name label; do delete_key "$name"; done <<< "$keys"
  if [ -f "$SHARES" ] && [ "$DRY" != 1 ]; then
    while IFS=$'\t' read -r _ receipt _; do ots burn "$receipt" >/dev/null 2>&1; done < "$SHARES"
  fi
  [ "$DRY" = 1 ] || rm -rf "$OUT"
  say "done. Deleted keys stop working at once; Google keeps them 30 days, unusable."
  echo "    The project and its billing are kept. Unused prepaid credit is not refunded."
  echo "    To stop all spend on it as well: gcloud billing projects unlink $PROJECT"
}

case "$CMD" in
  up|give|who|revoke|check|down) "$CMD" ;;
  *) usage ;;
esac
