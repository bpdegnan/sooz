# soozmsg.ps1 -- Windows port of soozmsg: text yourself via sooz.us.
#
#   soozmsg "build done"                       text me
#   soozmsg enroll ABCD-EFGH-JKMN              redeem a one-time code -> writes config
#   soozmsg run "nightly" -- msbuild /m        run a command, text when it exits
#   soozmsg doctor                             check config; no network
#
# Same config file, same lookup order and same rules as soozmsg.sh:
#   env SOOZ_NOTIFY_TOKEN / SOOZ_URL, else notify_token / url in
#   $SOOZMSG_CONFIG, else $XDG_CONFIG_HOME\soozmsg\config, else
#   %USERPROFILE%\.config\soozmsg\config, else %USERPROFILE%\.soozmsg
# Tokens are never taken on the command line, where they'd land in
# PowerShell's history file.
#
# DESIGN RULE: this must never break your build. Network/API failures warn on
# stderr and exit 0; --strict opts out. Usage errors exit 2. `run` always
# runs the command and returns the command's own exit status.
#
# Dot-source it (. .\soozmsg.ps1) to get the functions without running a
# command; soozwatch.ps1 does this so both scripts read the config one way.
#
# Keep this file ASCII: Windows PowerShell 5.1 reads a BOM-less file as ANSI,
# and a stray UTF-8 quote character would break the parse.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SoozVersion = '1.0.0'
$script:SoozProg    = 'soozmsg'
$script:SoozMaxMsg  = 140
$script:SoozQuiet   = $false
$script:SoozVerbose = $false

# Windows PowerShell 5.1 on older .NET still offers TLS 1.0 first, and the
# server refuses it with "Could not create SSL/TLS secure channel".
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Write-SoozWarn([string]$Text) {
    if (-not $script:SoozQuiet) { [Console]::Error.WriteLine("${script:SoozProg}: $Text") }
}
function Write-SoozInfo([string]$Text) {
    if ($script:SoozVerbose) { [Console]::Error.WriteLine("${script:SoozProg}: $Text") }
}

function Test-SoozWindows {
    # $IsWindows doesn't exist in 5.1, which only runs on Windows.
    return ($PSVersionTable.PSEdition -eq 'Desktop') -or
           ((Test-Path variable:IsWindows) -and $IsWindows)
}

# --- config -----------------------------------------------------------------

function Get-SoozConfigPath {
    if ($env:SOOZMSG_CONFIG) { return $env:SOOZMSG_CONFIG }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    return Join-Path (Join-Path $base 'soozmsg') 'config'
}

# Parsed, not dot-sourced: a config file should not be able to run code.
# key = value lines; # comments; first occurrence wins; CRs, surrounding
# whitespace and one pair of matching quotes are stripped -- as soozmsg.sh.
function Read-SoozConfigFile([string]$Path) {
    $values = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $line = $line -replace "`r", ''
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) { continue }
        $key = ($line.Substring(0, $eq) -replace '\s', '')
        if ($key -eq '' -or $key.StartsWith('#')) { continue }
        $val = $line.Substring($eq + 1).Trim()
        if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
        if (-not $values.ContainsKey($key)) { $values[$key] = $val }
    }
    return $values
}

function Get-SoozConfig {
    param([string]$Url = '')

    $cfg = @{
        Url = $Url; NotifyToken = ''; NotifySource = ''
        BatchToken = ''; BatchSource = ''; ConfigFile = ''
    }
    if (-not $cfg.Url -and $env:SOOZ_URL) { $cfg.Url = $env:SOOZ_URL }
    if ($env:SOOZ_NOTIFY_TOKEN) { $cfg.NotifyToken = $env:SOOZ_NOTIFY_TOKEN; $cfg.NotifySource = 'SOOZ_NOTIFY_TOKEN' }
    if ($env:SOOZ_BATCH_TOKEN)  { $cfg.BatchToken  = $env:SOOZ_BATCH_TOKEN;  $cfg.BatchSource  = 'SOOZ_BATCH_TOKEN' }

    $path = Get-SoozConfigPath
    if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path $HOME '.soozmsg' }
    if (Test-Path -LiteralPath $path) {
        $cfg.ConfigFile = $path
        $v = Read-SoozConfigFile $path
        if (-not $cfg.Url -and $v.ContainsKey('url')) { $cfg.Url = $v['url'] }
        if (-not $cfg.NotifyToken -and $v.ContainsKey('notify_token')) {
            $cfg.NotifyToken = $v['notify_token']; $cfg.NotifySource = $path
        }
        if (-not $cfg.BatchToken -and $v.ContainsKey('batch_token')) {
            $cfg.BatchToken = $v['batch_token']; $cfg.BatchSource = $path
        }
    }
    if (-not $cfg.Url) { $cfg.Url = 'https://sooz.us' }
    $cfg.Url = $cfg.Url.TrimEnd('/')
    return $cfg
}

# Describe a token without revealing any of it.
function Format-SoozToken([string]$Token, [string]$Source) {
    return "set ($($Token.Length) chars, from $Source)"
}

# --- http -------------------------------------------------------------------

# Status code and body from a failed Invoke-RestMethod, on 5.1 and 7 alike.
function Get-SoozHttpError($ErrorRecord) {
    $code = 0; $body = ''
    try { $code = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    try { if ($ErrorRecord.ErrorDetails) { $body = $ErrorRecord.ErrorDetails.Message } } catch { }
    return @{ Code = $code; Body = $body }
}

# POST field=value to $Path with the token in an Authorization header (never
# the URL). Invoke-RestMethod runs in this process, so unlike curl there is
# no command line for the token to show up on. Returns the parsed response,
# or $null after warning.
function Send-SoozRequest {
    param($Config, [string]$Path, [string]$Token, [string]$Source,
          [string]$Field, [string]$Value, [int]$Timeout = 10, [switch]$DryRun)

    $uri = "$($Config.Url)$Path"
    if ($DryRun) {
        Write-Host "would POST $uri"
        if ($Token) { Write-Host "  Authorization: Bearer <token $(Format-SoozToken $Token $Source)>" }
        else        { Write-Host '  Authorization: (no token found -- a real send would fail)' }
        Write-Host "  $Field=$Value"
        return $null
    }
    Write-SoozInfo "POST $uri ($Field=$Value)"
    # Encode the body ourselves: 5.1 encodes a hashtable body as ISO-8859-1,
    # which mangles non-ASCII text. EscapeDataString yields pure ASCII.
    $body = "$Field=" + [Uri]::EscapeDataString($Value)
    try {
        $r = Invoke-RestMethod -Method Post -Uri $uri -TimeoutSec $Timeout `
                -Headers @{ Authorization = "Bearer $Token" } `
                -ContentType 'application/x-www-form-urlencoded' -Body $body
    } catch {
        $err = $_        # inside switch below, $_ is the switch value instead
        $e = Get-SoozHttpError $err
        switch ($e.Code) {
            0       { Write-SoozWarn "could not reach $($Config.Url) ($($err.Exception.Message))" }
            401     { Write-SoozWarn "no token sent -- run 'soozmsg enroll <CODE>' or set notify_token" }
            404     { Write-SoozWarn 'sooz rejected the token (404) -- check it in the sooz UI' }
            default { Write-SoozWarn "sooz returned HTTP $($e.Code): $($e.Body)" }
        }
        return $null
    }
    Write-SoozReport $r
    return $r
}

# Say what actually happened. sent:false is the #1 confusion with this API.
function Write-SoozReport($r) {
    $has = { param($n) $null -ne $r -and $r.PSObject.Properties[$n] }
    if (& $has 'count')  { Write-SoozInfo "hit #$($r.count)" }
    if ((& $has 'logged') -and $r.logged) { Write-SoozInfo 'logged as a subtask' }
    if ((& $has 'action') -and $r.action -eq 'open') {
        Write-SoozInfo 'no SMS (open is silent by design -- the text comes on close)'
    } elseif ((& $has 'sent') -and -not $r.sent) {
        Write-SoozInfo 'no SMS sent -- token mode may be "none"/"once" (spent), the daily cap may be reached, or the SMS pool may be empty'
    } elseif ((& $has 'sent') -and $r.sent) {
        Write-SoozInfo 'SMS sent'
    }
}

function Test-SoozMessage([string]$Message) {
    if (-not $Message) { throw [ArgumentException]'a message is required (a message-less hit is counted but never texted)' }
    if ($Message.Length -gt $script:SoozMaxMsg) {
        Write-SoozWarn "message is $($Message.Length) chars; sooz truncates at $script:SoozMaxMsg"
    }
}

# Text $Message. Returns $true if sooz accepted it. Never throws for network
# or API problems -- callers decide whether a failed ping matters.
function Send-SoozNotify {
    param($Config, [string]$Message, [string]$Path = '/notify', [int]$Timeout = 10, [switch]$DryRun)
    Test-SoozMessage $Message
    # A dry run works without a token, so soozwatch can be tuned before enrolling.
    if (-not $Config.NotifyToken -and -not $DryRun) {
        Write-SoozWarn "no notify token (run 'soozmsg enroll <CODE>', set notify_token in $(Get-SoozConfigPath), or SOOZ_NOTIFY_TOKEN)"
        return $false
    }
    $r = Send-SoozRequest -Config $Config -Path $Path -Token $Config.NotifyToken `
            -Source $Config.NotifySource -Field msg -Value $Message -Timeout $Timeout -DryRun:$DryRun
    return ($DryRun -or $null -ne $r)
}

# --- enroll -----------------------------------------------------------------

# Create $Path readable only by the current user, BEFORE the token goes in.
function New-SoozPrivateFile([string]$Path) {
    New-Item -ItemType File -Path $Path -Force | Out-Null
    if (Test-SoozWindows) {
        $acl  = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)     # drop inherited access
        $me   = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        chmod 600 $Path
    }
}

function Invoke-SoozEnroll {
    param($Config, [string]$Code, [string]$Device = '', [int]$Timeout = 10, [switch]$DryRun)

    if (-not $Device) { $Device = [Environment]::MachineName }
    $uri = "$($Config.Url)/enroll"
    if ($DryRun) {
        Write-Host "would POST $uri"
        Write-Host "  code=$Code"
        Write-Host "  device=$Device"
        return 0
    }
    $body = 'code=' + [Uri]::EscapeDataString($Code) + '&device=' + [Uri]::EscapeDataString($Device)
    try {
        $r = Invoke-RestMethod -Method Post -Uri $uri -TimeoutSec $Timeout `
                -ContentType 'application/x-www-form-urlencoded' -Body $body
    } catch {
        $err = $_
        $e = Get-SoozHttpError $err
        if ($e.Code -eq 0) { Write-SoozWarn "could not reach $($Config.Url) ($($err.Exception.Message))"; return 1 }
        $msg = "HTTP $($e.Code)"
        try { $j = $e.Body | ConvertFrom-Json; if ($j.error) { $msg = $j.error } } catch { }
        [Console]::Error.WriteLine("${script:SoozProg}: enrollment failed: $msg")
        return 2
    }
    if (-not ($r.PSObject.Properties['token'] -and $r.token)) {
        [Console]::Error.WriteLine("${script:SoozProg}: enrollment returned no token")
        return 2
    }

    $cfgPath = Get-SoozConfigPath
    $dir = Split-Path -Parent $cfgPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Keep the old config: it may hold a hand-set url or a token still in use.
    if (Test-Path -LiteralPath $cfgPath) {
        Copy-Item -LiteralPath $cfgPath -Destination "$cfgPath.bak" -Force
        Write-Host "previous config saved as $cfgPath.bak"
    }
    $tmp = "$cfgPath.new.$PID"
    New-SoozPrivateFile $tmp
    $lines = @(
        "# written by soozmsg enroll on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "url = $($Config.Url)"
        "notify_token = $($r.token)"
    )
    if ($Config.BatchToken) { $lines += "batch_token = $($Config.BatchToken)" }
    # LF endings and no BOM, so soozmsg.sh can read the same file under WSL.
    [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $cfgPath -Force

    Write-Host "enrolled as `"$Device`"; token written to $cfgPath"
    if ($r.PSObject.Properties['task_bound'] -and $r.task_bound) {
        Write-Host 'pings will also be logged as subtasks under the bound task'
    }
    return 0
}

# --- run --------------------------------------------------------------------

# Open a subtask, run the command, close it on success or text the failure.
# The command always runs -- no token or no network just means no
# notifications -- and its exit status is left in $script:SoozRunExit. Not
# returned: the command's own output flows through this function's output,
# so a return value would get mixed into it. With -Strict, a failed ping
# turns a successful command's 0 into 1.
function Invoke-SoozRun {
    param($Config, [string]$Label, [string[]]$Command, [int]$Timeout = 10,
          [switch]$DryRun, [switch]$Strict)

    Test-SoozMessage $Label
    $notify = [bool]$Config.NotifyToken
    $pingOk = $true
    if (-not $notify) {
        Write-SoozWarn "no notify token (run 'soozmsg enroll <CODE>'); running without notifications"
        $pingOk = $false
    }
    $send = {
        param($m, $p)
        Send-SoozNotify -Config $Config -Message $m -Path $p -Timeout $Timeout -DryRun:$DryRun
    }
    if ($notify) { $pingOk = (& $send $Label '/notify/open') -and $pingOk }

    Write-SoozInfo "running: $($Command -join ' ')"
    $rc = 0
    try {
        $global:LASTEXITCODE = 0
        $exe  = $Command[0]
        $rest = @($Command | Select-Object -Skip 1)
        & $exe @rest
        $ok = $?
        $rc = $global:LASTEXITCODE
        if ($null -eq $rc) { $rc = 0 }
        if (-not $ok -and $rc -eq 0) { $rc = 1 }
    } catch {
        [Console]::Error.WriteLine("${script:SoozProg}: $($_.Exception.Message)")
        $rc = 1
    }

    if ($notify) {
        if ($rc -eq 0) { $pingOk = (& $send $Label '/notify/close') -and $pingOk }
        else           { $pingOk = (& $send "FAILED ($rc): $Label" '/notify') -and $pingOk }
    }
    if ($rc -eq 0 -and $Strict -and -not $pingOk) { $rc = 1 }
    $script:SoozRunExit = $rc
}

# --- doctor -----------------------------------------------------------------

function Show-SoozDoctor($Config) {
    Write-Host "$script:SoozProg $script:SoozVersion (PowerShell $($PSVersionTable.PSVersion))"
    Write-Host "  config:       $(if ($Config.ConfigFile) { $Config.ConfigFile } else { '(none found)' })"
    Write-Host "  url:          $($Config.Url)"
    Write-Host "  notify token: $(if ($Config.NotifyToken) { Format-SoozToken $Config.NotifyToken $Config.NotifySource } else { 'NOT SET' })"
    Write-Host ''
    Write-Host 'To set this machine up: in sooz.us open your project, find'
    Write-Host 'notify tokens -> "enroll a device", then run:'
    Write-Host "  $script:SoozProg enroll <CODE>"
    Write-Host 'That fetches this device its own token (revocable on its own).'
}

function Show-SoozUsage {
    @"
$script:SoozProg $script:SoozVersion -- ping sooz.us from long-running jobs (Windows)

usage:
  $script:SoozProg [opts] <message>                text me <message>
  $script:SoozProg [opts] run <label> [--] <cmd>... run <cmd>, text when it exits
  $script:SoozProg enroll <CODE> [--device=name]   redeem a one-time code -> writes config
  $script:SoozProg doctor                          check config; no network
  $script:SoozProg version

options (before the subcommand; after 'run <label>' everything is the command):
  --device=NAME  device name for enroll (default: computer name)
  --url=U        base url           (env SOOZ_URL, default https://sooz.us)
  --timeout=N    seconds (default 10)
  -n, --dry-run  print what would be sent; send nothing
  -v, --verbose  report what sooz said (sent? logged?)
  -q, --quiet    suppress warnings
  --strict       exit nonzero if the ping fails
  -h, --help

tokens:
  env SOOZ_NOTIFY_TOKEN, else notify_token in $(Get-SoozConfigPath)
  (or `$env:SOOZMSG_CONFIG). Never on the command line.
"@
}

# --- main -------------------------------------------------------------------
# Stop here when dot-sourced: the caller only wants the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

function Exit-SoozUsage([string]$Text) {
    [Console]::Error.WriteLine("${script:SoozProg}: $Text")
    exit 2
}

$url = ''; $device = ''; $timeout = 10
$dryRun = $false; $strict = $false
$positional = New-Object System.Collections.Generic.List[string]
$command    = New-Object System.Collections.Generic.List[string]

# Parsed by hand rather than with param(): PowerShell would otherwise bind
# the wrapped command's own flags (`-s`, `-v`) to ours by prefix match.
$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    # After `run <label>`, the rest is the command. An in-session call drops
    # `--` before we see it, so it can't be the only signal.
    if ($positional.Count -ge 2 -and $positional[0] -eq 'run') {
        if ($command.Count -eq 0 -and $a -eq '--') { $i++; continue }
        $command.Add($a); $i++; continue
    }
    switch -Regex ($a) {
        '^--(token|batch)(=.*)?$' { Exit-SoozUsage "--$($Matches[1]) was removed: a token on the command line lands in your PowerShell history. Use SOOZ_NOTIFY_TOKEN or the config file" }
        '^--device=(.*)$'  { $device  = $Matches[1]; break }
        '^--url=(.*)$'     { $url     = $Matches[1]; break }
        '^--timeout=(\d+)$' { $timeout = [int]$Matches[1]; break }
        '^(-n|--dry-run)$' { $dryRun = $true; break }
        '^(-v|--verbose)$' { $script:SoozVerbose = $true; break }
        '^(-q|--quiet)$'   { $script:SoozQuiet = $true; break }
        '^--strict$'       { $strict = $true; break }
        '^(-h|--help)$'    { Show-SoozUsage; exit 0 }
        '^--$'             { break }
        '^-'               { Exit-SoozUsage "unknown option: $a (try --help)" }
        default            { $positional.Add($a) }
    }
    $i++
}

if ($positional.Count -eq 0) { Show-SoozUsage; exit 2 }
$cfg = Get-SoozConfig -Url $url

try {
    switch ($positional[0]) {
        'enroll' {
            if ($positional.Count -ne 2) { Exit-SoozUsage 'enroll needs a code (e.g. soozmsg enroll ABCD-EFGH-JKMN)' }
            exit (Invoke-SoozEnroll -Config $cfg -Code $positional[1] -Device $device -Timeout $timeout -DryRun:$dryRun)
        }
        'doctor'  { Show-SoozDoctor $cfg; exit 0 }
        'version' { Write-Host "$script:SoozProg $script:SoozVersion"; exit 0 }
        'run' {
            if ($positional.Count -lt 2) { Exit-SoozUsage 'run needs a label' }
            if ($command.Count -eq 0) { Exit-SoozUsage 'run: nothing to run (usage: soozmsg run <label> -- <cmd>...)' }
            Invoke-SoozRun -Config $cfg -Label $positional[1] -Command $command.ToArray() `
                -Timeout $timeout -DryRun:$dryRun -Strict:$strict
            exit $script:SoozRunExit
        }
        default {
            $ok = Send-SoozNotify -Config $cfg -Message ($positional -join ' ') -Timeout $timeout -DryRun:$dryRun
            if (-not $ok -and $strict) { exit 1 }
            exit 0
        }
    }
} catch [ArgumentException] {
    Exit-SoozUsage $_.Exception.Message
}
