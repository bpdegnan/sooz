<#
.SYNOPSIS
    Watch a region of the screen and text yourself (via sooz.us) when it changes.

.DESCRIPTION
    Polls a rectangle of the screen, compares it to the last accepted image, and
    when enough of it changes -- e.g. an unread badge appears in your mail
    client -- POSTs a notification to sooz, which texts you.

    This is the "no API needed" approach: it works with anything you can see,
    including webmail in a browser and apps that expose nothing. That's its
    virtue AND its weakness. If you're watching Outlook, there is a far more
    robust way (Outlook's COM NewMailEx event, or the Windows notification
    listener) -- see NOTES.

    Guards against the three things that would otherwise text you at 2am:
      * screen locked / display asleep -> region goes black -> ignored, not fired
      * mouse cursor drifting through  -> too small to cross the threshold
      * one-frame flicker              -> a change must persist for two
                                          consecutive samples before it fires

.PARAMETER Pick
    Interactive helper to find the coordinates. Point at the top-left of the
    region, press Enter; point at the bottom-right, press Enter. It prints the
    exact command line to use. Start here.

.PARAMETER Preview
    Write a BMP of your desktop with the watched region outlined and tinted
    RED, plus a magnified crop of exactly the pixels that get compared -- then
    open it. Use this to confirm you're watching what you think you're
    watching, before you leave it running overnight.

.PARAMETER TestNotify
    Send one test notification and exit -- proves your token and URL work
    before you leave it running.

.EXAMPLE
    # The usual sequence: aim it, look at it, prove it, run it.
    .\soozwatch.ps1 -Pick
    .\soozwatch.ps1 -Preview -X 1520 -Y 40 -Width 300 -Height 60
    .\soozwatch.ps1 -TestNotify
    .\soozwatch.ps1 -X 1520 -Y 40 -Width 300 -Height 60 -Message "you have mail"

.EXAMPLE
    .\soozwatch.ps1 -X 1520 -Y 40 -Width 300 -Height 60 -Message "you have mail"

.EXAMPLE
    .\soozwatch.ps1 -X 1520 -Y 40 -Width 300 -Height 60 -Interval 5 -Cooldown 300

.NOTES
    Needs soozmsg.ps1 in the same folder: the token and URL come from it, so
    both scripts read the config one way. Set this machine up once with
    "soozmsg enroll <CODE>". Token: $env:SOOZ_NOTIFY_TOKEN, else
    %USERPROFILE%\.config\soozmsg\config. Never on the command line.

    Better options for EMAIL specifically:
      * Outlook COM:  $ol = New-Object -ComObject Outlook.Application
                      Register-ObjectEvent $ol.Session "NewMailEx" ...
      * Windows toast listener: [Windows.UI.Notifications.Management.UserNotificationListener]
        -- catches any app's notification, not just mail.
#>

[CmdletBinding(DefaultParameterSetName = 'Watch')]
param(
    [Parameter(ParameterSetName = 'Pick')]
    [switch]$Pick,

    [Parameter(ParameterSetName = 'Test')]
    [switch]$TestNotify,

    [Parameter(ParameterSetName = 'Watch', Mandatory = $true)]
    [int]$X,
    [Parameter(ParameterSetName = 'Watch', Mandatory = $true)]
    [int]$Y,
    [Parameter(ParameterSetName = 'Watch', Mandatory = $true)]
    [int]$Width,
    [Parameter(ParameterSetName = 'Watch', Mandatory = $true)]
    [int]$Height,

    [string]$Message  = "screen changed",
    [string]$Url      = "",

    # Seconds between samples.
    [int]$Interval    = 5,

    # After firing, ignore further changes for this many seconds. Stops one
    # arriving email from texting you five times as the UI animates.
    [int]$Cooldown    = 120,

    # Percent of the region that must change before it counts. 1.5 was tuned so
    # a mouse cursor crossing the region (~1.1%) stays quiet but a badge
    # appearing (~6%) fires. Raise it if you get false alarms.
    [double]$Threshold = 1.5,

    # Per-channel difference (0-255) below which a pixel is "the same". Absorbs
    # antialiasing and subpixel rendering jitter.
    [int]$Tolerance   = 12,

    # If the region's mean brightness drops below this, assume the screen is
    # locked or asleep and do nothing -- do NOT treat black as a change.
    [int]$DarkFloor   = 18,

    # A change must be seen this many samples in a row before firing.
    [int]$Persist     = 2,

    # Print what would be sent; send nothing.
    [switch]$DryRun,

    # Save a BMP of the desktop with the watched region outlined/tinted in red,
    # plus a zoomed crop of exactly the pixels being compared, then open it.
    # Use this to confirm you're watching what you think you're watching.
    [switch]$Preview,

    # Where -Preview writes its images (default: your Desktop).
    [string]$PreviewPath = "",

    # Magnification for the cropped preview.
    [int]$Zoom = 4,

    # BMP is uncompressed -- a 4K desktop lands around 25 MB. Use -Png for the
    # same images at a fraction of the size.
    [switch]$Png
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# Without this, Windows display scaling (125%, 150%...) lies about coordinates
# and you capture the wrong rectangle. This is the #1 gotcha.
try {
    Add-Type -Name Dpi -Namespace Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction SilentlyContinue
    [Win.Dpi]::SetProcessDPIAware() | Out-Null
} catch { }

# ---------------------------------------------------------------- notify ----

# Config, token handling and sending all come from soozmsg.ps1, so this
# script and soozmsg read the same file the same way. Dot-sourcing only
# defines its functions; it doesn't run a soozmsg command.
$soozmsgPath = Join-Path $PSScriptRoot 'soozmsg.ps1'
if (-not (Test-Path -LiteralPath $soozmsgPath)) {
    throw "soozwatch needs soozmsg.ps1 in the same folder ($PSScriptRoot)"
}
. $soozmsgPath
$script:SoozProg = 'soozwatch'

# Never dies because the network hiccuped: Send-SoozNotify warns and
# returns $false, and we keep watching.
function Send-WatchNotify {
    param($Config, [string]$Message, [switch]$DryRun)
    if ((Send-SoozNotify -Config $Config -Message $Message -DryRun:$DryRun) -and -not $DryRun) {
        Write-Host "$(Get-Date -Format 'HH:mm:ss')  notified: $Message"
    }
}

# ---------------------------------------------------------------- capture ---

function Get-RegionPixels {
    param([int]$X, [int]$Y, [int]$W, [int]$H)

    $bmp = New-Object System.Drawing.Bitmap($W, $H,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.CopyFromScreen($X, $Y, 0, 0,
                (New-Object System.Drawing.Size($W, $H)))
        } finally { $g.Dispose() }

        # LockBits, not GetPixel: GetPixel on a 300x60 region is ~18k marshalled
        # calls per sample and will peg a core.
        $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
        $data = $bmp.LockBits($rect,
            [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $len   = [Math]::Abs($data.Stride) * $H
            $bytes = New-Object byte[] $len
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $len)
            return $bytes
        } finally { $bmp.UnlockBits($data) }
    } finally { $bmp.Dispose() }
}

function Get-MeanBrightness {
    param([byte[]]$Pixels)
    [long]$sum = 0
    # Every 7th byte is plenty for a brightness estimate and ~7x faster.
    for ($i = 0; $i -lt $Pixels.Length; $i += 7) { $sum += $Pixels[$i] }
    return $sum / [Math]::Max(1, [Math]::Ceiling($Pixels.Length / 7))
}

function Get-ChangedPercent {
    param([byte[]]$A, [byte[]]$B, [int]$Tolerance)
    if ($A.Length -ne $B.Length) { return 100.0 }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) {
        if ([Math]::Abs([int]$A[$i] - [int]$B[$i]) -gt $Tolerance) { $diff++ }
    }
    return 100.0 * $diff / $A.Length
}

# ---------------------------------------------------------------- modes -----

if ($Pick) {
    Write-Host ""
    Write-Host "Point the mouse at the TOP-LEFT of the region to watch, then press Enter."
    [void](Read-Host)
    $p1 = [System.Windows.Forms.Cursor]::Position
    Write-Host "  got ($($p1.X), $($p1.Y))"
    Write-Host "Now point at the BOTTOM-RIGHT corner, then press Enter."
    [void](Read-Host)
    $p2 = [System.Windows.Forms.Cursor]::Position
    Write-Host "  got ($($p2.X), $($p2.Y))"

    $rx = [Math]::Min($p1.X, $p2.X); $ry = [Math]::Min($p1.Y, $p2.Y)
    $rw = [Math]::Abs($p2.X - $p1.X); $rh = [Math]::Abs($p2.Y - $p1.Y)

    if ($rw -lt 4 -or $rh -lt 4) {
        Write-Warning "that region is tiny ($rw x $rh) -- did you move the mouse between presses?"
    }
    Write-Host ""
    Write-Host "Run this:" -ForegroundColor Green
    Write-Host "  .\soozwatch.ps1 -X $rx -Y $ry -Width $rw -Height $rh -Message `"you have mail`""
    Write-Host ""
    Write-Host "Tip: keep the region SMALL and tight around the thing that changes"
    Write-Host "(the unread badge, the sender line). A big region catches a clock"
    Write-Host "ticking or a scrollbar moving and texts you about nothing."
    return
}

if ($Preview) {
    # The whole desktop, including monitors left of / above the primary -- those
    # have NEGATIVE screen coordinates, while the bitmap always starts at (0,0).
    # Everything below is in bitmap space, so translate by the virtual origin.
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

    if (-not $PreviewPath) {
        $PreviewPath = [Environment]::GetFolderPath('Desktop')
    }
    $ext = if ($Png) { 'png' } else { 'bmp' }
    $fmt = if ($Png) { [System.Drawing.Imaging.ImageFormat]::Png }
           else      { [System.Drawing.Imaging.ImageFormat]::Bmp }
    $shotFile = Join-Path $PreviewPath "soozwatch-region.$ext"
    $cropFile = Join-Path $PreviewPath "soozwatch-crop.$ext"

    $full = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($full)
        try {
            $g.CopyFromScreen($vs.X, $vs.Y, 0, 0,
                (New-Object System.Drawing.Size($vs.Width, $vs.Height)))

            $bx = $X - $vs.X          # <- the translation that makes multi-monitor work
            $by = $Y - $vs.Y

            if ($bx -lt 0 -or $by -lt 0 -or
                ($bx + $Width) -gt $vs.Width -or ($by + $Height) -gt $vs.Height) {
                Write-Warning "region ($X,$Y ${Width}x${Height}) falls outside the desktop ($($vs.Width)x$($vs.Height) at $($vs.X),$($vs.Y)) -- the box will be clipped."
            }

            # Tint so it's unmissable, but translucent so you can still read what's under it.
            $tint = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb(64, 255, 0, 0))
            $g.FillRectangle($tint, $bx, $by, $Width, $Height)
            $tint.Dispose()

            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 3)
            $g.DrawRectangle($pen, $bx, $by, $Width, $Height)
            $pen.Dispose()

            # Label it, placed above the box unless that would run off the top.
            $font  = New-Object System.Drawing.Font('Consolas', 12,
                        [System.Drawing.FontStyle]::Bold)
            $label = "watching $X,$Y  ${Width}x${Height}"
            $ly    = if ($by -ge 22) { $by - 20 } else { $by + $Height + 4 }
            $back  = New-Object System.Drawing.SolidBrush(
                        [System.Drawing.Color]::FromArgb(200, 0, 0, 0))
            $sz    = $g.MeasureString($label, $font)
            $g.FillRectangle($back, $bx, $ly, $sz.Width, $sz.Height)
            $g.DrawString($label, $font,
                [System.Drawing.Brushes]::White, $bx, $ly)
            $back.Dispose(); $font.Dispose()
        } finally { $g.Dispose() }

        $full.Save($shotFile, $fmt)
    } finally { $full.Dispose() }

    # And the crop itself, magnified -- these are the exact pixels being diffed.
    $crop = New-Object System.Drawing.Bitmap($Width, $Height,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $gc = [System.Drawing.Graphics]::FromImage($crop)
        try {
            $gc.CopyFromScreen($X, $Y, 0, 0,
                (New-Object System.Drawing.Size($Width, $Height)))
        } finally { $gc.Dispose() }

        $zoom = New-Object System.Drawing.Bitmap(($Width * $Zoom), ($Height * $Zoom),
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $gz = [System.Drawing.Graphics]::FromImage($zoom)
            try {
                # Nearest-neighbour: show the real pixels, not a smoothed lie.
                $gz.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $gz.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
                $gz.DrawImage($crop, 0, 0, ($Width * $Zoom), ($Height * $Zoom))
            } finally { $gz.Dispose() }
            $zoom.Save($cropFile, $fmt)
        } finally { $zoom.Dispose() }
    } finally { $crop.Dispose() }

    Write-Host ""
    Write-Host "wrote:" -ForegroundColor Green
    Write-Host "  $shotFile   (desktop, region boxed in red)"
    Write-Host "  $cropFile   (just the region, ${Zoom}x -- these are the pixels compared)"
    Write-Host ""
    Write-Host "If the red box isn't tight around the thing that changes, re-run -Pick."
    Write-Host "A region that includes a clock, a scrollbar, or an animation will"
    Write-Host "text you about nothing."
    try { Invoke-Item $shotFile } catch { }
    return
}

$cfg = Get-SoozConfig -Url $Url

if ($TestNotify) {
    Send-WatchNotify -Config $cfg `
        -Message "soozwatch test from $([Environment]::MachineName)" -DryRun:$DryRun
    return
}

# ---------------------------------------------------------------- watch -----

Write-Host "soozwatch: region ${Width}x${Height} at ($X,$Y), every ${Interval}s"
Write-Host "  fires when >${Threshold}% changes, confirmed over $Persist samples"
Write-Host "  then quiet for ${Cooldown}s. Ctrl-C to stop."
Write-Host ""

$baseline = $null
$streak   = 0

while ($true) {
    try {
        $pixels = Get-RegionPixels -X $X -Y $Y -W $Width -H $Height

        # Screen locked / display asleep: the region reads black. Do nothing --
        # and crucially do NOT re-baseline, or waking up would look like a change.
        if ((Get-MeanBrightness -Pixels $pixels) -lt $DarkFloor) {
            Write-Verbose "screen dark -- skipping"
            Start-Sleep -Seconds $Interval
            continue
        }

        if ($null -eq $baseline) {
            $baseline = $pixels
            Write-Host "$(Get-Date -Format 'HH:mm:ss')  baseline captured; watching..."
            Start-Sleep -Seconds $Interval
            continue
        }

        $pct = Get-ChangedPercent -A $baseline -B $pixels -Tolerance $Tolerance

        if ($pct -gt $Threshold) {
            $streak++
            Write-Verbose ("changed {0:N1}% ({1}/{2})" -f $pct, $streak, $Persist)

            if ($streak -ge $Persist) {
                Send-WatchNotify -Config $cfg -Message $Message -DryRun:$DryRun

                $baseline = $pixels     # the new state is now normal
                $streak   = 0
                Start-Sleep -Seconds $Cooldown
                $baseline = Get-RegionPixels -X $X -Y $Y -W $Width -H $Height
                continue
            }
        } else {
            $streak = 0
        }
    } catch {
        # A transient capture failure (RDP disconnect, session switch) must not
        # kill an overnight watch.
        Write-Warning "sample failed: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $Interval
}
