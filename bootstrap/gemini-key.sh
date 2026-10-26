#!/usr/bin/env bash
# Gemini API keys for the workshop room, behind a hard spend limit. For the
# facilitator, not the participants.
#
#   bootstrap/gemini-key.sh up    PROJECT [BILLING_ACCOUNT]   project, API, keys, check
#   bootstrap/gemini-key.sh check PROJECT                     one tiny call per key
#   bootstrap/gemini-key.sh down  PROJECT                     delete the keys
#
#   KEYS=8        how many keys: one per table, so a leaked one can go alone
#   BUDGET=50     USD: a budget alert at 50/90/100 %. An alert, not a limit
#   DRY_RUN=1     print every command and run none
#
# The limit itself cannot be scripted: Google offers no API for it. It is
# prepaid credit with auto-reload off (at $0 every key on the billing account
# fails with HTTP 402), plus AI Studio's project spend cap. `up` ends with
# those steps, and `check` tells a project still on the free tier (20
# requests a day: not enough, see runthrough/2026-10-25-pi-gemini) from a paid one.
#
# Keys are written to .local/gemini-keys/<project>/key-N.env (git-ignored,
# mode 600), ready to paste into a participant's .env. Never printed.
# Safe to re-run: what exists is kept.
set -uo pipefail
cd "$(dirname "$0")/.."

CMD="${1:-}" PROJECT="${2:-}" BILLING="${3:-}"
KEYS="${KEYS:-8}" BUDGET="${BUDGET:-50}" DRY="${DRY_RUN:-0}"
API=generativelanguage.googleapis.com
MODEL=gemini-3.8-flash          # the workshop's pin: generic_agent/run.py
OUT=".local/gemini-keys/$PROJECT"

say()  { printf '==> %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
fail() { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { printf '  + %s\n' "$*" >&2; [ "$DRY" = 1 ] || "$@"; }

usage() { sed -n '5,7p' "$0" | sed 's/^# //'; exit 2; }
[ -n "$PROJECT" ] || usage

preconditions() {
  command -v gcloud >/dev/null || fail "gcloud is not installed: https://cloud.google.com/sdk/docs/install"
  [ "$DRY" = 1 ] || [ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ] \
    || fail "gcloud is not logged in. Run: gcloud auth login"
}

# The full resource name of the live (not deleted) key with this display name.
live_key() {
  gcloud services api-keys list --project="$PROJECT" \
    --filter="displayName=\"$1\"" --format='value(name)' 2>/dev/null | head -n 1
}

billing_enabled() {
  gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null
}

up() {
  preconditions
  if gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
    say "project $PROJECT exists; keeping it"
  else
    say "creating project $PROJECT"
    run gcloud projects create "$PROJECT" --name="ACO workshop" || fail "could not create $PROJECT (project IDs are global: try another)"
  fi

  if [ -n "$BILLING" ]; then
    say "linking billing account $BILLING"
    run gcloud billing projects link "$PROJECT" --billing-account="$BILLING" >/dev/null \
      || fail "could not link $BILLING. Your accounts: gcloud billing accounts list"
    if gcloud billing budgets list --billing-account="$BILLING" \
         --format='value(displayName)' 2>/dev/null | grep -qx "$PROJECT"; then
      say "budget alert $PROJECT exists; keeping it"
    else
      say "budget alert: $BUDGET USD (email at 50, 90, 100 %)"
      run gcloud billing budgets create --billing-account="$BILLING" \
        --display-name="$PROJECT" --budget-amount="${BUDGET}USD" \
        --filter-projects="projects/$PROJECT" \
        --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
        >/dev/null || warn "no budget alert (needs Billing Account Administrator). The prepaid credit still limits spend."
    fi
  elif [ "$(billing_enabled)" != True ]; then
    warn "no billing account given, and $PROJECT has none: its keys stay on the free tier"
  fi

  say "enabling the Gemini API"
  run gcloud services enable "$API" apikeys.googleapis.com --project="$PROJECT" || fail "could not enable $API"

  [ "$DRY" = 1 ] || { mkdir -p "$OUT" && chmod 700 "$OUT"; }
  say "$KEYS key(s), each allowed the Gemini API only"
  for i in $(seq 1 "$KEYS"); do
    label="ACO workshop $i" file="$OUT/key-$i.env"
    # Found by display name, not by ID: a deleted key is kept for 30 days,
    # its ID can't be reused, and describe/get-key-string still answer for it.
    # list leaves deleted keys out.
    name=$(live_key "$label")
    if [ -n "$name" ]; then
      echo "  $label exists"
    else
      # create reports the new key, keyString and all, on stderr (2026-10-26):
      # keep it, and show only an error, with any key line taken out.
      err=$(run gcloud services api-keys create --project="$PROJECT" \
        --display-name="$label" --api-target=service="$API" 2>&1 >/dev/null) \
        || { warn "could not create $label: $(printf '%s\n' "$err" | grep -v keyString | tail -n 3)"; continue; }
      printf '%s\n' "$err" | grep '^  + '
      [ "$DRY" = 1 ] && continue
      name=$(live_key "$label")
    fi
    key=$(gcloud services api-keys get-key-string "$name" \
            --format='value(keyString)' 2>/dev/null) || { warn "could not read $label"; continue; }
    (umask 077; printf '# %s, project %s\nACO_HARNESS=pi-gemini\nGEMINI_API_KEY=%s\n' \
       "$label" "$PROJECT" "$key" > "$file")
  done
  [ "$DRY" = 1 ] || echo "  written to $OUT/"

  cat <<EOF

==> Now in AI Studio, as only you can (Google has no API for these):

  1. https://aistudio.google.com/projects → Import project → $PROJECT
  2. Its Billing Tier column → Set up billing → choose PREPAY, buy the credit
     you are willing to lose (about \$2 per participant for all three labs).
     A billing account of its own: at \$0 every project on it stops.
  3. https://aistudio.google.com/billing → auto-reload: leave it OFF.
     That is the hard limit: at \$0 the keys fail with HTTP 402.
  4. https://aistudio.google.com/spend → Monthly spend cap → the same amount.
     Experimental, and like the credit it lags about 10 minutes.

  Then: bootstrap/gemini-key.sh check $PROJECT
  After the workshop: bootstrap/gemini-key.sh down $PROJECT

EOF
  [ "$DRY" = 1 ] || check
}

check() {
  ls "$OUT"/key-*.env >/dev/null 2>&1 || fail "no keys in $OUT. Run: bootstrap/gemini-key.sh up $PROJECT"
  if [ "$(billing_enabled)" = True ]; then say "billing is linked to $PROJECT"
  else warn "no billing on $PROJECT (or gcloud cannot see it): free tier, 20 requests a day"; fi
  say "one tiny call per key to $MODEL"
  for file in "$OUT"/key-*.env; do
    printf '  %-10s ' "$(basename "$file" .env)"
    python3 -I - "$file" "$MODEL" <<'PY'
import json, sys, urllib.request, urllib.error
key = next(l.split("=", 1)[1].strip() for l in open(sys.argv[1]) if l.startswith("GEMINI_API_KEY="))
req = urllib.request.Request(
    f"https://generativelanguage.googleapis.com/v1beta/models/{sys.argv[2]}:generateContent",
    data=json.dumps({"contents": [{"parts": [{"text": "Reply with OK"}]}],
                     "generationConfig": {"maxOutputTokens": 64}}).encode(),
    headers={"Content-Type": "application/json", "X-goog-api-key": key})
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
  done
}

down() {
  preconditions
  # Every live key `up` made, by display name: list leaves deleted ones out.
  # A failed list is not an empty one: never drop the local copies then.
  names=$(gcloud services api-keys list --project="$PROJECT" \
            --filter='displayName~"^ACO workshop "' --format='value(name)') \
    || fail "could not list the keys in $PROJECT; nothing deleted"
  if [ -z "$names" ]; then
    say "no workshop keys in $PROJECT"
    [ "$DRY" = 1 ] || rm -rf "$OUT"
    exit 0
  fi
  say "about to delete these keys in $PROJECT; anyone still using one is cut off:"
  for name in $names; do
    printf '    %s\n' "$(gcloud services api-keys describe "$name" --format='value(displayName)' 2>/dev/null)"
  done
  if [ "${YES:-}" != yes ] && [ "$DRY" != 1 ]; then
    read -r -p "Type the project ID to confirm: " confirm
    [ "$confirm" = "$PROJECT" ] || { echo "Aborted."; exit 1; }
  fi
  for name in $names; do
    # delete reports the key string on stderr too: as in up.
    err=$(run gcloud services api-keys delete "$name" --quiet 2>&1 >/dev/null) \
      || { warn "could not delete $name: $(printf '%s\n' "$err" | grep -v keyString | tail -n 3)"; continue; }
    printf '%s\n' "$err" | grep '^  + '
  done
  [ "$DRY" = 1 ] || rm -rf "$OUT"
  say "done. Deleted keys stop working at once; Google keeps them 30 days, unusable."
  echo "    The project and its billing are kept. Unused prepaid credit is not refunded."
  echo "    To stop all spend on it as well: gcloud billing projects unlink $PROJECT"
}

case "$CMD" in
  up) up ;;
  check) check ;;
  down) down ;;
  *) usage ;;
esac
