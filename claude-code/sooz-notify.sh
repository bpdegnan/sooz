#!/usr/bin/env bash
# Text yourself via sooz.us when Claude Code finishes a LONG turn.
#
# Wire it to two events (see README.md):
#   UserPromptSubmit -> records when this turn started
#   Stop             -> if the turn ran longer than SOOZ_MIN_SECONDS, send a text
#
# The duration gate is the point. A bare Stop hook fires on EVERY turn, so
# "yes" and "thanks" would each burn an SMS from your prepaid pool.
#
# Sending is soozmsg's job: it finds the token (SOOZ_NOTIFY_TOKEN or
# ~/.config/soozmsg/config) and keeps it out of `ps`. This script never sees
# the token.
#
# Environment:
#   SOOZ_MIN_SECONDS    only text for turns at least this long (default 180)
#   SOOZ_INCLUDE_TEXT   1 = append Claude's closing words to the text. Off by
#                       default: they leave the machine via sooz and the SMS
#                       carrier, so don't enable it where the work is confidential
#   SOOZMSG             path to soozmsg (default: soozmsg, then soozmsg.sh, on PATH)
#   SOOZ_DEBUG          1 = say on stderr why it did or didn't send
#
# Needs: python3 (rather than jq so there's nothing to install, and because
# Claude's closing text contains quotes and newlines that a sed parser would
# mangle), and soozmsg.
set -u

MIN=${SOOZ_MIN_SECONDS:-180}            # 3 minutes
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sooz-hook"   # per-user, unlike /tmp

debug() { [ "${SOOZ_DEBUG:-0}" = 1 ] && printf 'sooz-notify: %s\n' "$*" >&2; return 0; }

# One python call extracts everything, so quotes, newlines and unicode in
# Claude's reply survive intact. -I: the hook runs in your repo, and a json.py
# there must not be imported. The session id becomes a filename, so it is
# reduced to safe characters.
parsed=$(python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ev   = d.get("hook_event_name", "")
sid  = re.sub(r"[^A-Za-z0-9_-]", "", d.get("session_id") or "") or "unknown"
cwd  = (d.get("cwd") or ".").rstrip("/").rsplit("/", 1)[-1][:30] or "."
last = " ".join((d.get("last_assistant_message") or "").split())[:90]
print(ev); print(sid); print(cwd); print(last)
') || { debug "input is not hook JSON"; exit 0; }

event=$(printf '%s\n' "$parsed" | sed -n 1p)
session=$(printf '%s\n' "$parsed" | sed -n 2p)
project=$(printf '%s\n' "$parsed" | sed -n 3p)
last=$(printf '%s\n' "$parsed" | sed -n 4p)

( umask 077; mkdir -p "$STATE_DIR" ) 2>/dev/null
stamp="$STATE_DIR/${session}"

# SubagentStop is deliberately NOT handled: a subagent shares its parent's
# session_id, so it would consume the parent turn's stamp, and the real Stop
# would then find nothing and stay silent.
case $event in
  UserPromptSubmit)
    date +%s > "$stamp" 2>/dev/null
    # Sessions that end without a Stop (interrupted, closed) leave a stamp.
    find "$STATE_DIR" -type f -mtime +1 -delete 2>/dev/null
    exit 0 ;;
  Stop) ;;
  *) debug "ignoring $event"; exit 0 ;;
esac

[ -f "$stamp" ] || { debug "no start time for this turn"; exit 0; }
started=$(cat "$stamp" 2>/dev/null || echo 0)
rm -f "$stamp" 2>/dev/null
# Validate before the arithmetic: under set -u a non-numeric stamp would make
# $(( ... )) abort the script. A corrupt or ancient stamp (clock change,
# leftover file) would otherwise report an absurd duration, so anything over
# a day is treated as untrustworthy too.
case $started in ''|*[!0-9]*) debug "bad start time"; exit 0 ;; esac
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -ge "$MIN" ] || { debug "turn took ${elapsed}s, under ${MIN}s"; exit 0; }
[ "$elapsed" -le 86400 ] || { debug "start time is stale"; exit 0; }

mins=$(( elapsed / 60 )); [ "$mins" -lt 1 ] && mins=1
msg="[$project] Claude done after ${mins}m"
if [ "${SOOZ_INCLUDE_TEXT:-0}" = 1 ] && [ -n "$last" ]; then
  msg="$msg: $last"
fi

sooz=${SOOZMSG:-}
if [ -z "$sooz" ]; then
  sooz=$(command -v soozmsg 2>/dev/null || command -v soozmsg.sh 2>/dev/null)
fi
[ -n "$sooz" ] || { debug "soozmsg not found (set SOOZMSG or put it on PATH)"; exit 0; }

# NEVER exit 2 from a Stop hook: that means "don't stop", which traps Claude
# in a loop. soozmsg exits 0 on network/API failures; ignore it anyway.
if [ "${SOOZ_DEBUG:-0}" = 1 ]; then
  "$sooz" -v "$msg" || true
else
  "$sooz" -q "$msg" >/dev/null 2>&1 || true
fi
exit 0
