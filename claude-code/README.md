# Calling sooz.us remotely for completion notifications

How to make something far away - a Claude Code session, a build box, a cron job -
reach sooz.us and put a text on your phone when it finishes.

Written for the "text me when Claude finishes a long task" case, but the API
section applies to anything that can run `curl`.

---

## 1. One-time setup per machine

Install `soozmsg` from [`../shell/`](../shell/README.md): copy
`soozmsg.sh` onto your `PATH` as `soozmsg` and `chmod +x` it. The hook in §3.3
sends through it.

In sooz: open your project -> **notify tokens** -> **enroll a device**. You get a
short code. On the machine:

```sh
soozmsg enroll ABCD-EFGH-JKMN
```

That redeems the code for *that device's own* notify token and writes it to
`~/.config/soozmsg/config` (mode 600). The machine shows up in sooz as
`device: <hostname>` and can be revoked on its own without disturbing the
others. The code is single-use and expires in 15 minutes.

Can't enroll (CI, a container)? Create a notify token in the web UI and export
it. `soozmsg` checks the environment before the config file:

```sh
export SOOZ_NOTIFY_TOKEN='...'
```

**Set the token's mode to `every hit`.** A token in `once` mode texts you the
first time and then disables itself - which looks exactly like a broken
integration.

Check it:

```sh
soozmsg doctor          # config + token summary, no network
soozmsg "test"          # should buzz your phone
```

---

## 2. The API

Everything is one HTTP POST. The token travels in an `Authorization: Bearer`
header, never in the URL - a token in a URL path lands in shell history, in
`ps` on a shared box, and in server access logs.

| Endpoint | What it does |
|---|---|
| `POST /notify` | count a hit and text `msg` |
| `POST /notify/open` | open a subtask (work started). **Silent - never texts** |
| `POST /notify/close` | close the matching open subtask and text |
| `POST /batch/start` \| `/batch/complete` \| `/batch/fail` | per-run events in a batch; needs `cid=<run id>` |
| `POST /enroll` | redeem an enrollment code (no auth - the code *is* the credential) |

```sh
curl -sS -X POST https://sooz.us/notify \
  -H "Authorization: Bearer $SOOZ_NOTIFY_TOKEN" \
  --data-urlencode "msg=P&R finished"
```

`msg` also works as a query parameter (`/notify?msg=done`), which matters for
the scriptless HTTP hook in §3.

Response:

```json
{"ok":true,"action":"hit","count":9,"sent":true,"logged":true}
```

- `sent` - an SMS actually went out
- `logged` - a subtask was created or closed (only if the token is task-bound)

`401` = no token supplied. `404` = bad token.

### Four rules that bite

1. **No `msg` -> no SMS.** The hit is still counted and logged, but nothing is
   texted. A text with nothing to say is noise, so this is deliberate.
2. **Messages are capped at 140 characters.** Longer ones are truncated.
3. **`open` never texts**, whatever the token's mode. The text comes on `close`.
4. **Sends draw on your prepaid SMS pool.** Empty pool -> `sent:false`, silently,
   while counts and subtasks keep accruing.

### Legacy form

`/n/<TOKEN>`, `/n/<TOKEN>/open`, `/n/<TOKEN>/close` and `/b/<TOKEN>/…` still
work, with the token in the URL. Fine for a quick test; prefer the header form
for anything you leave running.

---

## 3. Wiring it to Claude Code

Claude Code fires [hooks](https://code.claude.com/docs/en/hooks) at points in
its lifecycle. The one you want is **`Stop`** - "when Claude finishes
responding". Hooks live in:

| File | Scope |
|---|---|
| `~/.claude/settings.json` | all your projects |
| `.claude/settings.json` | one project, committable |
| `.claude/settings.local.json` | one project, gitignored |

### ⚠ The thing to get right first

**A `Stop` hook fires on *every* turn.** Not just the 40-minute refactor - also
"yes", "thanks", and every one-line answer. Wire a naive notifier to it and
you'll text yourself dozens of times an hour and drain your SMS pool.

So §3.3 gates on duration. Read that before leaving anything running.

**Also: never exit 2 from a `Stop` hook.** On `Stop`, exit code 2 means *don't
stop* - it forces Claude to keep going. A notifier that exits 2 when the network
is down would trap Claude in a loop. Exit 0 always. (`soozmsg` already does:
network and API failures warn and exit 0 by design.)

### 3.1 Scriptless: an HTTP hook

Claude Code can POST to a URL directly, no script required. The message goes in
the query string; the token stays in a header.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "http",
            "url": "https://sooz.us/notify?msg=Claude%20finished",
            "headers": { "Authorization": "Bearer $SOOZ_NOTIFY_TOKEN" },
            "allowedEnvVars": ["SOOZ_NOTIFY_TOKEN"],
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

`allowedEnvVars` is required - without it the `$SOOZ_NOTIFY_TOKEN` reference is
replaced with an empty string and you'll get a 401.

Simplest thing that works, but the message is **fixed** - it can't say which
project or how long the task took, and it fires on every turn. Good for a quick
trial, not for daily use.

### 3.2 One line, with `soozmsg`

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "soozmsg 'Claude finished'", "async": true }
        ]
      }
    ]
  }
}
```

`async: true` runs it in the background so Claude isn't held up by the network
round trip. Still fires every turn.

### 3.3 What you actually want: only long tasks

Ship the script below as `~/.claude/hooks/sooz-notify.sh` (`chmod +x`), and
register it on **two** events:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$HOME/.claude/hooks/sooz-notify.sh", "async": true } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$HOME/.claude/hooks/sooz-notify.sh", "async": true } ] }
    ]
  }
}
```

`UserPromptSubmit` stamps the start time; `Stop` compares it and only sends if
the turn ran longer than `SOOZ_MIN_SECONDS` (default 180). Tune it:

```sh
export SOOZ_MIN_SECONDS=600     # only text me for 10-minute-plus work
```

The text you get looks like:

```
[sooz.us] Claude done after 12m
```

Project folder name and elapsed minutes. To also get Claude's closing words:

```sh
export SOOZ_INCLUDE_TEXT=1
```

```
[sooz.us] Claude done after 12m: Suite green: 1266 tests.
```

That is off by default for a reason: the excerpt leaves your machine through
sooz and the SMS carrier, and Claude's last sentence often names files,
results, or clients. Turn it on only where that's acceptable. It reads
`last_assistant_message` from the hook input rather than parsing the
transcript, which is what the docs recommend.

The script never touches the token: it hands the message to `soozmsg`, which
finds the token and keeps it out of `ps`. If `soozmsg` isn't on the `PATH`
Claude Code runs hooks with, set `SOOZMSG=/full/path/to/soozmsg`. The script
exits 0 on every path - bad JSON, no `soozmsg`, no token, dead network, stale
state. Its start-time files live in `~/.cache/sooz-hook/`, readable only by
you.

To test it without waiting, feed it the two events by hand. `SOOZ_DEBUG=1`
makes it say why it did or didn't send:

```sh
h=~/.claude/hooks/sooz-notify.sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"/x/myproj"}' | $h
echo '{"hook_event_name":"Stop","session_id":"t1","cwd":"/x/myproj"}' \
  | SOOZ_MIN_SECONDS=0 SOOZ_DEBUG=1 $h
```

That sends a real text: `[myproj] Claude done after 1m`.

### 3.4 Other events worth knowing

- **`SubagentStop`** - a subagent finished. Useful if you dispatch long
  background work, but **don't point `sooz-notify.sh` at it**: a subagent
  shares its parent's session, and the script ignores this event so the
  subagent can't swallow the parent turn's start time.
- **`Notification`** with matcher `agent_needs_input` - Claude is *blocked on
  you*, which is arguably more worth a text than completion is.
- **`SessionEnd`** - the session closed. Note these hooks share a ~1.5s budget,
  so keep anything here fast or `async`.

---

## 4. Bracketing a job instead

If what you want is a *record* rather than a ping, bind the token to a task and
bracket the work. Each run becomes a subtask you can review:

```sh
soozmsg run "nightly regression" -- ./run-all.sh
```

That opens a subtask, runs the command, closes it on success - or texts
`FAILED (3): nightly regression` if it dies - and returns the command's own exit
status, so it's safe in a Makefile.

Anything still *open* in the morning is what died.

For a sweep of many runs with progress thresholds, use a batch:

```sh
soozmsg batch start    --cid="$RUN_ID"
./sim.sh && soozmsg batch complete --cid="$RUN_ID" \
         || soozmsg batch fail     --cid="$RUN_ID"
```

Rule of thumb: a **notify token** says "tell me when this one thing is done"; a
**batch** says "track N runs and tell me at milestones".

---

## 5. Why isn't it texting?

In order of likelihood:

1. **No message.** A hit with no `msg` counts and logs but never texts.
2. **Token mode.** `none` never texts; `once` texts once then disables itself.
   You want **every hit**. Change it on the project page - no need to reissue
   the token.
3. **Empty SMS pool.** `sent:false` with no error.
4. **Daily cap** reached for that token.
5. **Hook not firing.** Run `/hooks` in Claude Code to see what's registered,
   and check the command path is absolute - a relative path fails when the cwd
   isn't the repo root.
6. **401 from an HTTP hook.** You forgot `allowedEnvVars`.
7. **`soozmsg` not found.** Hooks may run with a shorter `PATH` than your
   shell. Run the hand test in §3.3 with `SOOZ_DEBUG=1`; if it says
   `soozmsg not found`, set `SOOZMSG` to the full path.

On the server, `php bin/console notify:status <token>` prints mode, counts, cap
and last send in one go.

---

## 6. Quick reference

```sh
# one-time, per machine
soozmsg enroll ABCD-EFGH-JKMN

# ping
soozmsg "P&R done"
curl -sS -X POST https://sooz.us/notify \
  -H "Authorization: Bearer $SOOZ_NOTIFY_TOKEN" \
  --data-urlencode "msg=P&R done"

# bracket a job (opens a subtask, closes it, reports failure)
soozmsg run "gds" -- librelane config.json

# batch of N runs
soozmsg batch start|complete|fail --cid=<run id>

# diagnose
soozmsg doctor
```

Hook docs: <https://code.claude.com/docs/en/hooks>
