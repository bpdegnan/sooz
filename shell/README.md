# soozmsg

Text yourself when a long job finishes. A tiny POSIX-`sh` client for
[sooz.us](https://sooz.us) - the only dependency is `curl`.

Built for EDA flows where a run takes 40 minutes and you've walked away: an
OpenROAD P&R, an ngspice corner sweep, a LibreLane flow, a regression on a
cluster.

```sh
soozmsg run "P&R" -- openroad -exit flow.tcl
```

Your phone gets `P&R` when it finishes, or `FAILED (1): P&R` if it died.

---

## Requirements

- Any POSIX shell (`/bin/sh` on macOS, Linux, BSD; also works under WSL).
- `curl` 7.55 or newer. Nothing else: no Python, no jq.
- A sooz.us account with SMS credit.

## Install

Copy the script onto your `PATH` as `soozmsg` and make it executable:

```sh
cp soozmsg.sh ~/bin/soozmsg
chmod +x ~/bin/soozmsg
```

## Set up a machine (once)

In sooz: open your project -> **notify tokens** -> **enroll a device**. You get
a short code. On the machine:

```sh
soozmsg enroll ABCD-EFGH-JKMN
```

That redeems the code for **this device's own** notify token and writes it to
`~/.config/soozmsg/config` (mode 600). The machine then shows up in sooz as
`device: <hostname>`, and you can revoke that one box without disturbing the
others. If a config already exists, it is kept as `config.bak`.

The code is single-use and expires in 15 minutes. Typing it lowercase or
without the dashes is fine.

**Set the token's mode to `every hit`.** A token in `once` mode texts you the
first time and then disables itself, which looks exactly like a broken script.

Can't enroll (CI, containers, one-off runs)? Create a notify token in the web
UI and put it in the environment instead. Pull it from your secret store at run
time rather than writing it into a script:

```sh
export SOOZ_NOTIFY_TOKEN='...'
```

Then prove it works before wiring it into anything:

```sh
soozmsg doctor           # config + token summary, no network
soozmsg -v "test"        # should buzz your phone, and says what sooz did
```

---

## Use

```sh
# text me
soozmsg "corner sweep finished: 3/4 passed"

# bracket a job: open a subtask, close it when done
soozmsg open  "sky130 corner sweep"      # silent - no text
soozmsg close "sky130 corner sweep"      # closes it, texts you

# do both around a command, and get told if it dies
soozmsg run "P&R" -- openroad -exit flow.tcl

# a sweep of many runs (needs a batch token - see below)
soozmsg batch start    --cid=corner_tt_27
soozmsg batch complete --cid=corner_tt_27
```

`run` is the one worth wiring into a Makefile: it opens a subtask, runs the
command, and closes it on success - or texts you `FAILED (3): P&R` if it dies.

- **It always runs the command and returns the command's own exit status**,
  even with no token or no network, so it's safe in `&&` chains, Makefiles and
  `set -e` scripts.
- The command's stdin, stdout and stderr pass straight through, so pipes and
  interactive programs behave normally.

Messages are capped at 140 characters by sooz. Longer ones are cut, not
rejected; `soozmsg` warns when that will happen.

## It will not break your build

Any network or API failure prints one warning on stderr and **exits 0**. A
notifier that kills a 40-minute run because the wifi blipped is worse than no
notifier.

Pass `--strict` if you want failures to exit nonzero. With `run`, a failed ping
turns a successful command's 0 into 1; a failing command keeps its own status.
(Usage errors - a typo in a flag, a missing message - always exit 2; that's
your bug, not the network's.)

There are no retries: one attempt, ten-second timeout (`--timeout=N`). A text
that didn't go out is gone; the next one tries again.

## Configuration

Precedence: environment -> config file. Tokens are never accepted on the
command line, where they'd land in shell history and `ps`.

`~/.config/soozmsg/config` (or `$SOOZMSG_CONFIG`, or
`$XDG_CONFIG_HOME/soozmsg/config`):

```
url = https://sooz.us
notify_token = ...
batch_token  = ...
```

Environment: `SOOZ_URL`, `SOOZ_NOTIFY_TOKEN`, `SOOZ_BATCH_TOKEN`.

The config file is parsed, not sourced - a config file should not be able to
run code. Quotes around values and Windows line endings are fine. Keep it mode
600; `soozmsg` will nag you if it isn't.

## Options

```
--cid=ID       run id (required for batch)
--device=NAME  device name for enroll (default: hostname)
--url=U        base url
--timeout=N    seconds (default 10)
-n, --dry-run  print what would be sent; send nothing
-v, --verbose  report what sooz said (texted? logged?)
-q, --quiet    suppress warnings
--strict       exit nonzero if the ping fails
```

---

## Examples

```sh
# Makefile
gds: netlist
	soozmsg run "gds: $(TOP)" -- librelane config.json

# Claude Code, non-interactive: Claude's exit code decides success or failure
soozmsg run "claude: migrate tests" -- \
  claude -p "Migrate the test suite from nose to pytest. Run it and fix failures." \
         --allowedTools "Edit,Bash(pytest *)"

# mid-script checkpoints
./synth.sh   && soozmsg "synth done, starting P&R"
./pnr.sh     && soozmsg "P&R done, starting signoff"
./signoff.sh && soozmsg "signoff clean"

# a corner sweep, one subtask per corner
for c in tt ss ff; do
    soozmsg open "spice: $c"
    eda-ngspice -b "corner_$c.sp" > "out_$c.log" && soozmsg close "spice: $c"
done

# a cluster sweep, tracked as one batch with progress
soozmsg batch start    --cid="$SLURM_JOB_ID"
run_sim.sh             && soozmsg batch complete --cid="$SLURM_JOB_ID" \
                       || soozmsg batch fail     --cid="$SLURM_JOB_ID"
```

For an interactive Claude Code session, use the hook in
[`../claude-code/`](../claude-code/README.md) instead: it texts when a long
turn finishes, which `run` can't see.

**Cron.** Cron has a minimal environment. Use the absolute path to `soozmsg`
and the config-file token, which only needs `HOME`.

**Several machines.** Enroll each one, so each has its own token you can revoke
on its own.

## Subtasks

If the notify token is bound to a task (bind it when you mint the enrollment
code, or on the project page), then:

- a plain ping appends an **open** subtask titled with your message
- `open` creates an open subtask; `close` closes the matching one (matched by
  the message, so use the same text for both)
- `close` with no matching open subtask records a **closed** one anyway, so a
  lone `close` still logs a completion

That turns a night of sweeps into a reviewable checklist. Anything still
*open* in the morning is what died.

## Batch tokens

Batches are for a *workload* of many runs (progress, thresholds like "text me
at 50%"). Create one in sooz (project page -> batches, with an expected run
count); it issues a batch ingest token. Put it in the config as `batch_token`.

Rule of thumb: **notify token** = "tell me when this one thing is done."
**batch** = "track N runs and tell me at milestones."

---

## Why isn't it texting?

Run with `-v` and it will tell you. The usual causes, in order:

1. **Token mode.** A token set to `none` never texts; `once` texts on the first
   hit and then disables itself. You want **every hit**. Change it on the
   project page - no need to reissue the token.
2. **No token found.** `soozmsg doctor` shows where it looked. Check
   `SOOZ_NOTIFY_TOKEN`, or that the config has a `notify_token =` line.
3. **Wrong or revoked token.** sooz answers 404 and `soozmsg` says so.
4. **Empty SMS pool.** Sends draw on your prepaid pool; when it's empty, hits
   still count and subtasks still appear, but no text goes out.
5. **Daily cap** reached for that token.
6. **No message.** A hit with no `msg` is counted and logged but never texted.
7. **Running under cron or a service** without your `HOME` or environment.

`open` is *always* silent by design - the text comes when you `close`.

On the server, `php bin/console notify:status <token>` prints all of the above
at once.

## Security notes

- The token travels in an `Authorization: Bearer` header, never in the URL,
  and is handed to `curl` on stdin rather than as an argument. So it stays out
  of your shell history, out of `ps` on a shared box, and out of server access
  logs.
- `--dry-run` and `doctor` show a token's length and where it came from, never
  any of the token itself.
- Notify tokens are write-only, scoped to one project, SMS-capped, and
  individually revocable. They cannot read anything from your account. That is
  why `soozmsg` uses a notify token and not an API key.
