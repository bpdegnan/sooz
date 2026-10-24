# soozwatch - HOWTO

**What it does:** watches a small rectangle of your screen and, when it
changes, sends a notification that turns into a text message.

The intended use is "tell me when an email arrives" - you point it at the
unread badge in your mail client, and when the badge appears, your phone buzzes.
It works with anything you can *see*, including webmail in a browser, because
it just looks at pixels.

It has only been run lightly on real Windows. The tricky parts (the
change-detection math, the multi-monitor coordinate handling) were tested
separately, but expect rough edges, and see
[What to report back](#what-to-report-back) at the end.

**Good news:** you can test almost all of it with `-DryRun` without needing a
token or an account. See [Step 5](#step-5---do-a-dry-run-no-token-needed).

---

## Requirements

- Windows 10 or 11.
- PowerShell - the one built into Windows is fine (5.1). PowerShell 7 also
  works. You do **not** need to install anything.
- These three files, kept together in one folder: `soozwatch.ps1`,
  `soozmsg.ps1` (soozwatch gets its token and sends through it) and
  `soozmsg.cmd`.
- To actually receive texts, a sooz notify token (see [Step 6](#step-6---connect-it-to-sooz-optional-for-testing)).
  Not needed for dry-run testing.

---

## Step 1 - Unblock the files

Windows marks files downloaded from the internet or received over chat/email as
blocked, and PowerShell will refuse to run them. **This trips up almost
everyone**, and the error message doesn't say "unblock me."

Right-click each file -> **Properties** -> tick **Unblock** at the bottom ->
OK.

Or, in PowerShell in that folder, all at once:

```powershell
Get-ChildItem soozwatch.ps1, soozmsg.ps1, soozmsg.cmd | Unblock-File
```

## Step 2 - Open PowerShell in the right folder

Put the three files somewhere simple, like `C:\Users\<you>\soozwatch\`.

Open that folder in File Explorer, click the address bar, type `powershell`,
press Enter. You'll get a prompt already in that folder.

## Step 3 - Allow the script to run

Windows blocks unsigned scripts by default. The safest way is to allow it for
**just this one session** - nothing permanent changes on your machine:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

That lasts until you close the window. You'll need it each time you open a new
PowerShell window. (If you'd rather not, you can instead launch with
`powershell -ExecutionPolicy Bypass -File .\soozwatch.ps1 -Pick`.)

Quick check that everything is happy:

```powershell
Get-Help .\soozwatch.ps1 -Full
```

If you see the help text, you're good.

## Step 4 - Aim it at the thing you want to watch

Open your mail client. Position it so the unread indicator is visible and the
window won't move.

```powershell
.\soozwatch.ps1 -Pick
```

It asks you to point the mouse at the **top-left** corner of the area to watch
and press Enter, then the **bottom-right** corner and press Enter. It prints a
ready-to-paste command with the coordinates filled in.

**Keep the region small and tight** around the thing that actually changes -
the unread badge, the top sender line. If you draw a big box around the whole
window, you'll catch a clock ticking or a scrollbar moving and get texted about
nothing.

### Look at what you picked

This is the important step, and it's the one people skip:

```powershell
.\soozwatch.ps1 -Preview -X 1520 -Y 40 -Width 300 -Height 60
```

(Use the numbers `-Pick` gave you.) It writes two images to your **Desktop** and
opens the first:

- `soozwatch-region.bmp` - your whole screen with the watched area outlined in
  red and tinted, labelled with the coordinates.
- `soozwatch-crop.bmp` - just that area, magnified 4x. These are the exact
  pixels being compared.

Is the red box tight around the badge? Does it accidentally include a clock, a
progress bar, or an animation? Fix it now - re-run `-Pick` - rather than
discovering it at 3am.

> The images are BMP because they were requested that way; they're
> uncompressed, so on a 4K screen expect ~25 MB each. Add `-Png` for the same
> pictures at a fraction of the size.

> `-Preview` needs the `-X -Y -Width -Height` values. If you run it bare it
> will prompt you for them.

## Step 5 - Do a dry run (no token needed)

```powershell
.\soozwatch.ps1 -X 1520 -Y 40 -Width 300 -Height 60 -DryRun -Verbose
```

It watches for real but doesn't send anything - it just prints what it *would*
send. `-Verbose` also shows the percentage changed on every sample, which is
the single most useful thing for tuning.

Leave it running and send yourself a test email. You should see the change
percentage jump and a `would POST ...` line appear.

Press **Ctrl-C** to stop it.

## Step 6 - Connect it to sooz (optional for testing)

To get actual text messages, this computer needs its own **notify token**.
Enroll it once:

In sooz.us, open your project -> **notify tokens** -> **enroll a device**. You
get a short code. Then, in the soozwatch folder:

```powershell
.\soozmsg.cmd enroll ABCD-EFGH-JKMN
```

That fetches this computer its own token and saves it in
`%USERPROFILE%\.config\soozmsg\config`, readable only by you, where soozwatch
finds it. The code is single-use and expires in 15 minutes. `soozmsg.cmd`
handles the execution policy itself, so Step 3 isn't needed for it.

**Set the token's mode to `every hit`** on the project page. A token in `once`
mode texts you the first time and then disables itself, which looks exactly
like a broken script.

Can't enroll? Create a token in the web UI and set it for this PowerShell
window, pasting it at the prompt:

```powershell
$env:SOOZ_NOTIFY_TOKEN = Read-Host "token"
```

Paste at the prompt rather than typing the token into the command itself:
PowerShell saves every command line in its history file, but not what you
type at a `Read-Host` prompt. For the same reason there is no `-Token` option.

Check what it found, then prove it works before relying on it:

```powershell
.\soozmsg.cmd doctor
.\soozwatch.ps1 -TestNotify
```

That sends one message and exits. If a text arrives, everything downstream is
fine.

> **The token is a password.** Anyone with it can send messages on that
> account. Don't paste it into a shared document or a screenshot. It is sent
> in a header rather than in a URL so it stays out of logs, and neither
> script ever prints it: `doctor` and `-DryRun` show only its length and
> where it came from. If a token leaks, revoke that device in sooz and
> enroll again.

## Step 7 - Run it for real

```powershell
.\soozwatch.ps1 -X 1520 -Y 40 -Width 300 -Height 60 -Message "you have mail"
```

Leave the window open. Ctrl-C stops it.

`-Message` is the text you'll receive, so make it something you'll recognise on
a lock screen.

---

## soozmsg on Windows

`soozmsg.cmd` is the Windows version of the `soozmsg` command, so you can text
yourself from any script, not just the screen watcher:

```powershell
.\soozmsg.cmd "backup finished"
.\soozmsg.cmd run "nightly build" -- msbuild /m
```

`run` texts the label when the command succeeds, or `FAILED (<code>): <label>`
when it fails, and returns the command's own exit code. A missing token or a
dead network only prints a warning; it never stops the command. Add the folder
to your `PATH` to type plain `soozmsg` from anywhere. `.\soozmsg.cmd --help`
lists the options.

---

## Tuning

| Option | Default | What it does |
|---|---|---|
| `-Interval` | 5 | Seconds between checks. Raise to 15-30 to be gentler on the CPU. |
| `-Cooldown` | 120 | After firing, stay quiet this many seconds. Stops one email texting you repeatedly while the UI animates. |
| `-Threshold` | 1.5 | Percent of the region that must change to count. **Raise this if you get false alarms.** |
| `-Tolerance` | 12 | How different a pixel must be to count as changed. Absorbs font-smoothing jitter. |
| `-DarkFloor` | 18 | If the region goes darker than this, assume the screen is locked and do nothing. |
| `-Persist` | 2 | How many checks in a row must show the change before it fires. Filters out flickers and the mouse passing through. |
| `-Verbose` | off | Print the change percentage every check. Use this while tuning. |

The defaults were tuned so that a mouse cursor crossing the region (~1.1%
change) stays quiet, while an unread badge appearing (~6%) fires.

### If it texts you when nothing happened

Run with `-Verbose`, watch the percentages while you do nothing, and note the
highest idle number. Set `-Threshold` comfortably above it. Also check the
`-Preview` crop for anything animated inside your box - a clock is the usual
culprit.

### If it never fires

Run with `-Verbose` and trigger the change. If the percentage barely moves, the
region is probably too large (a small badge in a big box is a tiny fraction of
the pixels) - shrink it around just the indicator. If the percentage clearly
jumps but nothing sends, the token or network is the problem: try `-TestNotify`.

---

## Known limitations

Be aware of these before trusting it overnight:

- **The window must not move.** It watches fixed screen coordinates, not a
  window. Move or resize the mail client and it's watching the wrong pixels.
- **Display scaling.** The script tells Windows it is DPI-aware, which should
  handle 125%/150% scaling - but this is one of the things nobody has verified
  yet. If the `-Preview` red box appears offset from where you pointed, this is
  why: say so.
- **Locked screen / RDP.** When the screen is locked or the session is
  disconnected, there are no pixels to read. The script detects darkness and
  stays quiet rather than firing, but it also can't detect anything during that
  time.
- **It only knows "something changed."** It can't tell you who the email is
  from.

---

## Is there a better way?

Yes, and it's worth saying plainly: if you use **Outlook**, watching pixels is
the fragile way to do this. Outlook can tell PowerShell directly when mail
arrives (a `NewMailEx` event), which is exact, instant, and doesn't care where
the window is. Windows also has a notification listener that can see *any*
app's pop-up toasts.

Screen-watching is the right tool when there's no API.

---

## What to report back

Open a GitHub issue with a screenshot of `soozwatch-region.bmp` and the
console output - that is usually enough to sort out anything. Say which
Windows and PowerShell version you used (`.\soozmsg.cmd doctor` prints the
PowerShell one), and whether you use display scaling or more than one
monitor.
