#!/bin/sh
# soozmsg — notify sooz.us when a long EDA job starts, finishes, or dies.
#
#   soozmsg "openroad flow done"              # text me
#   soozmsg open  "sky130 corner sweep"       # open a subtask (silent)
#   soozmsg close "sky130 corner sweep"       # close it, text me
#   soozmsg run "openroad flow" -- openroad -exit flow.tcl
#   soozmsg batch start    --cid=corner_tt_27
#   soozmsg batch complete --cid=corner_tt_27
#   soozmsg doctor                            # check config, no network
#
# Config, in precedence order: environment -> config file. Tokens are never
# taken on the command line, where they'd land in shell history and `ps`.
#   ~/.config/soozmsg/config  (or $SOOZMSG_CONFIG), key = value lines:
#       url = https://sooz.us
#       notify_token = ...
#       batch_token = ...
#   env: SOOZ_URL, SOOZ_NOTIFY_TOKEN, SOOZ_BATCH_TOKEN
#
# DESIGN RULE: this must never break your build. Any network/HTTP failure
# warns on stderr and exits 0. Pass --strict to opt into nonzero exits.
# (Usage errors always exit 2 — that's your typo, not a flaky network.)
# `run` always runs the command and returns the command's own status.
#
# POSIX sh. Only dependency is curl.

set -u

VERSION='1.0.0'
PROG=$(basename "$0")

DEFAULT_URL='https://sooz.us'
TIMEOUT=10
DRY_RUN=0
VERBOSE=0
QUIET=0
STRICT=0
MAX_MSG=140          # sooz truncates at 140; we warn before it silently cuts

URL=''
NOTIFY_TOKEN=''
BATCH_TOKEN=''
NOTIFY_SRC=''        # where each token came from, for doctor/dry-run
BATCH_SRC=''
CID=''
DEVICE=''
IN_RUN=0             # inside `run`: failures must not exit before the command does
PING_FAILED=0

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { [ "$QUIET" -eq 1 ] || printf '%s: %s\n' "$PROG" "$*" >&2; return 0; }
info() { [ "$VERBOSE" -eq 1 ] && printf '%s: %s\n' "$PROG" "$*" >&2; return 0; }

# A network/API failure. Warn, but stay out of the way of the build. Inside
# `run` it only records the failure: exiting here would skip the wrapped
# command, or replace its exit status with ours.
soft_fail() {
    warn "$*"
    PING_FAILED=1
    [ "$IN_RUN" -eq 1 ] && return 1
    [ "$STRICT" -eq 1 ] && exit 1
    exit 0
}

# Describe a token without revealing any of it.
describe_token() {
    printf 'set (%s chars, from %s)' "$(printf '%s' "$1" | wc -c | tr -d ' ')" "$2"
}

usage() {
    cat <<EOF
$PROG $VERSION — ping sooz.us from long-running jobs

usage:
  $PROG [opts] <message>                 count a hit + text <message>
  $PROG [opts] open  <message>           open a subtask (silent, no SMS)
  $PROG [opts] close <message>           close that subtask + text
  $PROG [opts] run <label> -- <cmd>...   open, run <cmd>, close (or report failure)
  $PROG [opts] batch start|complete|fail --cid=<id>
  $PROG enroll <CODE> [--device=name]    redeem a one-time code -> writes config
  $PROG doctor                           check config; no network
  $PROG version

options:
  --cid=ID       run id for batch mode (required for batch)
  --device=NAME  device name for enroll (default: hostname)
  --url=U        base url           (env SOOZ_URL, default $DEFAULT_URL)
  --timeout=N    seconds (default $TIMEOUT)
  -n, --dry-run  print what would be sent; send nothing
  -v, --verbose  report what sooz said (sent? logged?)
  -q, --quiet    suppress warnings
  --strict       exit nonzero if the ping fails (default: exit 0, never
                 break the build)
  -h, --help

tokens:
  env SOOZ_NOTIFY_TOKEN / SOOZ_BATCH_TOKEN, else notify_token / batch_token
  in ~/.config/soozmsg/config (or \$SOOZMSG_CONFIG). Never on the command line.

notes:
  A message is required to get an SMS — sooz counts and logs a message-less
  hit but does not text. Subtasks only appear if the notify token is bound to
  a task in the sooz UI.
EOF
}

# --- config -----------------------------------------------------------------
# Parsed, not sourced: a config file should not be able to run code.
load_config() {
    cfg=${SOOZMSG_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/soozmsg/config}
    [ -f "$cfg" ] || { cfg="$HOME/.soozmsg"; [ -f "$cfg" ] || return 0; }
    CONFIG_FILE=$cfg

    # Tokens are secrets. Nag once if the file is group/world readable.
    perms=$(ls -l "$cfg" 2>/dev/null | cut -c5-10)    # group + other bits
    case $perms in
        ------|'') : ;;
        *[rwx]*) warn "config $cfg is readable by others; chmod 600 it" ;;
    esac

    # `|| [ -n "$k" ]` keeps a last line that has no trailing newline.
    # [[:space:]], not [ \t]: BSD sed (macOS) reads \t in brackets as a
    # literal "\" and "t", which strips the t's off a token like "tt-abc".
    # The tr drops CRs from a file saved on Windows.
    while IFS='=' read -r k v || [ -n "$k" ]; do
        k=$(printf '%s' "$k" | tr -d ' \t\r')
        case $k in ''|'#'*) continue ;; esac
        v=$(printf '%s' "$v" | tr -d '\r' | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//
                                              s/^\"\\(.*\\)\"\$/\\1/; s/^'\\(.*\\)'\$/\\1/")
        case $k in
            url)          [ -z "$URL" ] && URL=$v ;;
            notify_token) [ -z "$NOTIFY_TOKEN" ] && { NOTIFY_TOKEN=$v; NOTIFY_SRC=$cfg; } ;;
            batch_token)  [ -z "$BATCH_TOKEN" ]  && { BATCH_TOKEN=$v;  BATCH_SRC=$cfg; } ;;
        esac
    done < "$cfg"
    return 0
}

# --- http -------------------------------------------------------------------
# The token goes in an `Authorization: Bearer` header, never in the URL. A
# secret in the URL *path* would land in shell history, in `ps` on a shared
# box, and in the server's access logs — and switching to POST wouldn't help,
# because the path is still the path. Hence /notify and /batch/* rather than
# the older /n/<token> and /b/<token>/* forms.
#
# Nor in curl's argv: `-H "Authorization: ..."` would show the token to anyone
# running `ps`. printf is a builtin, so piping the header into `-H @-` keeps
# it inside this process and curl's stdin (needs curl 7.55+).
post() {
    _path=$1; shift          # e.g. /notify/close
    _token=$1; shift         # the credential (header, not URL)
    _tsrc=$1; shift          # where it came from, for dry-run
    _field=$1; _value=$2     # e.g. msg "sweep done"

    _url="$URL$_path"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would POST %s\n  Authorization: Bearer <token %s>\n  %s=%s\n' \
            "$_url" "$(describe_token "$_token" "$_tsrc")" "$_field" "$_value"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || { soft_fail "curl not found"; return 1; }

    info "POST $_url ($_field=$_value)"
    _body=$(printf 'Authorization: Bearer %s\n' "$_token" |
            curl -sS -X POST \
                 --max-time "$TIMEOUT" \
                 -H @- \
                 --data-urlencode "$_field=$_value" \
                 -w '\n%{http_code}' \
                 "$_url" 2>&1) || {
        # Drop the trailing http_code line (000 on a network error).
        _err=$(printf '%s' "$_body" | sed '$d' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        soft_fail "could not reach $URL (${_err:-network error})"; return 1; }

    _code=$(printf '%s' "$_body" | tail -n1)
    _json=$(printf '%s' "$_body" | sed '$d')

    case $_code in
        200) ;;
        401) soft_fail "no token sent — run '$PROG enroll <CODE>' or set notify_token"; return 1 ;;
        404) soft_fail "sooz rejected the token (404) — check it in the sooz UI"; return 1 ;;
        *)   soft_fail "sooz returned HTTP $_code: $_json"; return 1 ;;
    esac

    RESPONSE=$_json
    report "$_json"
    return 0
}

# Say what actually happened. `sent:false` is the #1 confusion with this API,
# so name the likely cause instead of leaving the user to guess.
report() {
    _j=$1
    _sent=$(printf '%s' "$_j"   | sed -n 's/.*"sent":[[:space:]]*\([a-z]*\).*/\1/p')
    _logged=$(printf '%s' "$_j" | sed -n 's/.*"logged":[[:space:]]*\([a-z]*\).*/\1/p')
    _count=$(printf '%s' "$_j"  | sed -n 's/.*"count":[[:space:]]*\([0-9]*\).*/\1/p')
    _prog=$(printf '%s' "$_j"   | sed -n 's/.*"progress":[[:space:]]*\([0-9]*\).*/\1/p')

    if [ -n "$_prog" ]; then
        info "recorded (progress: $_prog)"
        return 0
    fi
    [ -n "$_count" ] && info "hit #$_count"
    [ "$_logged" = 'true' ] && info 'logged as a subtask'

    _action=$(printf '%s' "$_j" | sed -n 's/.*"action":[[:space:]]*"\([a-z]*\)".*/\1/p')
    if [ "$_action" = 'open' ]; then
        info 'no SMS (open is silent by design — the text comes on close)'
    elif [ "$_sent" = 'false' ]; then
        # Not an error — but if the user expected a text, name the usual causes.
        info 'no SMS sent — token mode may be "none"/"once" (spent), the daily cap may be reached, or the SMS pool may be empty'
    elif [ "$_sent" = 'true' ]; then
        info 'SMS sent'
    fi
    return 0
}

NO_NOTIFY_TOKEN="no notify token (run '$PROG enroll <CODE>', set notify_token in the config, or SOOZ_NOTIFY_TOKEN)"
need_notify_token() {
    [ -n "$NOTIFY_TOKEN" ] || die "$NO_NOTIFY_TOKEN"
}
need_batch_token() {
    [ -n "$BATCH_TOKEN" ] || die "no batch token (set batch_token in config, or SOOZ_BATCH_TOKEN)"
}
check_msg() {
    [ -n "$1" ] || die 'a message is required (a message-less hit is counted but never texted)'
    # wc -m counts characters; ${#1} counts bytes in some shells.
    _len=$(printf '%s' "$1" | wc -m | tr -d ' ')
    if [ "$_len" -gt $MAX_MSG ]; then
        warn "message is $_len chars; sooz truncates at $MAX_MSG"
    fi
}

# --- subcommands ------------------------------------------------------------
cmd_notify() { check_msg "$1"; need_notify_token; post /notify       "$NOTIFY_TOKEN" "$NOTIFY_SRC" msg "$1"; }
cmd_open()   { check_msg "$1"; need_notify_token; post /notify/open  "$NOTIFY_TOKEN" "$NOTIFY_SRC" msg "$1"; }
cmd_close()  { check_msg "$1"; need_notify_token; post /notify/close "$NOTIFY_TOKEN" "$NOTIFY_SRC" msg "$1"; }

cmd_batch() {
    _kind=$1; shift
    case $_kind in start|complete|fail) ;; *) die "batch: expected start|complete|fail, got '$_kind'" ;; esac
    need_batch_token
    [ -n "$CID" ] || die 'batch mode needs --cid=<run id>'
    post "/batch/$_kind" "$BATCH_TOKEN" "$BATCH_SRC" cid "$CID"
}

# Redeem a one-time enrollment code for THIS device's own notify token, and
# write it to the config. The code is short-lived and single-use; the token it
# returns is revocable on its own in the sooz UI ("device: <name>").
cmd_enroll() {
    _code=$1
    [ -n "$_code" ] || die 'enroll needs a code (e.g. soozmsg enroll ABCD-EFGH-JKMN)'
    [ -n "$DEVICE" ] || DEVICE=$(hostname 2>/dev/null || echo device)

    _url="$URL/enroll"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would POST %s\n  code=%s\n  device=%s\n' "$_url" "$_code" "$DEVICE"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || soft_fail 'curl not found'

    _body=$(curl -sS -X POST --max-time "$TIMEOUT" \
                 --data-urlencode "code=$_code" \
                 --data-urlencode "device=$DEVICE" \
                 -w '\n%{http_code}' \
                 "$_url" 2>&1) || soft_fail "could not reach $URL"
    _code_http=$(printf '%s' "$_body" | tail -n1)
    _json=$(printf '%s' "$_body" | sed '$d')

    if [ "$_code_http" != '200' ]; then
        _err=$(printf '%s' "$_json" | sed -n 's/.*"error":[[:space:]]*"\([^"]*\)".*/\1/p')
        die "enrollment failed: ${_err:-HTTP $_code_http}"
    fi

    _tok=$(printf '%s' "$_json" | sed -n 's/.*"token":[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$_tok" ] || die 'enrollment returned no token'

    # Write config with the token, 600 from the moment it exists.
    _cfg=${SOOZMSG_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/soozmsg/config}
    _dir=$(dirname "$_cfg")
    mkdir -p "$_dir" || die "cannot create $_dir"
    # Keep the old config: it may hold a hand-set url or a token still in use.
    if [ -f "$_cfg" ]; then
        cp -p "$_cfg" "$_cfg.bak" || die "cannot back up $_cfg"
        printf 'previous config saved as %s\n' "$_cfg.bak"
    fi
    _tmp="$_cfg.new.$$"
    ( umask 077; : > "$_tmp" ) || die "cannot write $_tmp"
    {
        printf '# written by soozmsg enroll on %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'url = %s\n' "$URL"
        printf 'notify_token = %s\n' "$_tok"
        [ -n "$BATCH_TOKEN" ] && printf 'batch_token = %s\n' "$BATCH_TOKEN"
    } >> "$_tmp"
    mv "$_tmp" "$_cfg" || die "cannot write $_cfg"
    chmod 600 "$_cfg" 2>/dev/null

    _bound=$(printf '%s' "$_json" | sed -n 's/.*"task_bound":[[:space:]]*\([a-z]*\).*/\1/p')
    printf 'enrolled as "%s"; token written to %s\n' "$DEVICE" "$_cfg"
    [ "$_bound" = 'true' ] && printf 'pings will also be logged as subtasks under the bound task\n'
    return 0
}

# Bracket a command: open a subtask, run it, then close it on success or
# report the failure. The command always runs -- no token or no network just
# means no notifications -- and its own exit status is what we return, so
# this is safe to drop into a Makefile. With --strict, a failed ping turns a
# successful command's 0 into 1; a failing command keeps its own status.
cmd_run() {
    _label=$1; shift
    check_msg "$_label"
    [ $# -gt 0 ] || die 'run: nothing to run (usage: soozmsg run <label> -- <cmd>...)'

    IN_RUN=1
    _notify=1
    if [ -z "$NOTIFY_TOKEN" ]; then
        warn "$NO_NOTIFY_TOKEN; running without notifications"
        PING_FAILED=1
        _notify=0
    fi

    [ "$_notify" -eq 1 ] && cmd_open "$_label"
    info "running: $*"
    "$@"
    _status=$?

    if [ "$_notify" -eq 1 ]; then
        if [ $_status -eq 0 ]; then
            cmd_close "$_label"
        else
            # Leave the subtask OPEN (it didn't finish) and text the failure.
            cmd_notify "FAILED ($_status): $_label"
        fi
    fi
    if [ $_status -eq 0 ] && [ "$STRICT" -eq 1 ] && [ "$PING_FAILED" -eq 1 ]; then
        return 1
    fi
    return $_status
}

cmd_doctor() {
    printf '%s %s\n' "$PROG" "$VERSION"
    if command -v curl >/dev/null 2>&1; then printf '  curl:         ok\n'
    else                                     printf '  curl:         MISSING\n'; fi
    printf '  config:       %s\n' "${CONFIG_FILE:-(none found)}"
    printf '  url:          %s\n' "$URL"
    if [ -n "$NOTIFY_TOKEN" ]; then
        printf '  notify token: %s\n' "$(describe_token "$NOTIFY_TOKEN" "$NOTIFY_SRC")"
    else
        printf '  notify token: NOT SET\n'
    fi
    if [ -n "$BATCH_TOKEN" ]; then
        printf '  batch token:  %s\n' "$(describe_token "$BATCH_TOKEN" "$BATCH_SRC")"
    else
        printf '  batch token:  not set (only needed for batch mode)\n'
    fi
    printf '\n%s\n' 'To set this machine up: in sooz.us open your project, find'
    printf '%s\n' 'notify tokens -> "enroll a device", then run:'
    printf '%s\n' "  $PROG enroll <CODE>"
    printf '%s\n' 'That fetches this device its own token (revocable on its own).'
}

# --- args -------------------------------------------------------------------
# POSIX sh has no arrays, so positional args are collected as a shell-quoted
# string and eval'd back. Single-quote escaping keeps spaces/quotes intact --
# a naive "$ARGS" string would split `open "corner sweep"` into three args.
shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

POSARGS=''   # soozmsg's own args (subcommand + message)
RUNCMD=''    # everything after `--`, i.e. the command for `run`

while [ $# -gt 0 ]; do
    case $1 in
        --token|--token=*|--batch|--batch=*)
            die "${1%%=*} was removed: a token on the command line lands in shell history and ps. Use SOOZ_NOTIFY_TOKEN / SOOZ_BATCH_TOKEN or the config file" ;;
        --cid=*)     CID=${1#*=} ;;
        --device=*)  DEVICE=${1#*=} ;;
        --url=*)     URL=${1#*=} ;;
        --timeout=*) TIMEOUT=${1#*=} ;;
        --cid|--url|--timeout|--device)
            die "$1 needs a value: use $1=VALUE" ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -q|--quiet)   QUIET=1 ;;
        --strict)     STRICT=1 ;;
        -h|--help)    usage; exit 0 ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                RUNCMD="$RUNCMD $(shquote "$1")"
                shift
            done
            break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)  POSARGS="$POSARGS $(shquote "$1")" ;;
    esac
    shift
done

[ -z "$URL" ] && URL=${SOOZ_URL:-}
NOTIFY_TOKEN=${SOOZ_NOTIFY_TOKEN:-}; [ -n "$NOTIFY_TOKEN" ] && NOTIFY_SRC='SOOZ_NOTIFY_TOKEN'
BATCH_TOKEN=${SOOZ_BATCH_TOKEN:-};   [ -n "$BATCH_TOKEN" ]  && BATCH_SRC='SOOZ_BATCH_TOKEN'
CONFIG_FILE=''
load_config
[ -z "$URL" ] && URL=$DEFAULT_URL
URL=${URL%/}

eval "set -- $POSARGS"
[ $# -gt 0 ] || { usage; exit 2; }

case $1 in
    open)    shift; [ $# -eq 1 ] || die 'open needs exactly one message'; cmd_open "$1" ;;
    close)   shift; [ $# -eq 1 ] || die 'close needs exactly one message'; cmd_close "$1" ;;
    batch)   shift; [ $# -ge 1 ] || die 'batch needs start|complete|fail'; cmd_batch "$@" ;;
    run)     shift; [ $# -ge 1 ] || die 'run needs a label'; _l=$1; shift
             eval "set -- $RUNCMD"
             cmd_run "$_l" "$@" ;;
    enroll)  shift; [ $# -ge 1 ] || die 'enroll needs a code'; cmd_enroll "$1" ;;
    doctor)  cmd_doctor ;;
    version) printf '%s %s\n' "$PROG" "$VERSION" ;;
    *)       cmd_notify "$*" ;;
esac
