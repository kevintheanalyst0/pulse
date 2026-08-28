# Pulse - a tray icon that shows how close you are to your Claude and ChatGPT
# usage limits. Reads OAuth tokens already saved locally by `claude` and `codex`
# CLIs and calls only the same free account-usage endpoints the Settings > Usage
# pages use - no paid API/model calls, so it never burns tokens or credits.
#
# Windows' native tray tooltip can't do multi-line text, per-value colors, or
# icons, so hovering shows a small custom popup window instead (built in C#
# below so it can be marked "no activate" - it won't steal keyboard focus).

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Prevent duplicate instances
$mutex = New-Object System.Threading.Mutex($false, "Global\Pulse_TrayApp_SingleInstance")
if (-not $mutex.WaitOne(0, $false)) { exit }

# powershell.exe is not per-monitor DPI aware by default, so Windows silently
# rescales the coordinates it hands to this process on any monitor that isn't
# at 100% scaling (typical on a laptop's own screen). That mismatch is what
# broke hover detection off an external monitor. Opting in to real per-monitor
# DPI awareness here - before any window/icon is created - fixes it at the
# source instead of trying to compensate for it in the hit-testing math.
Add-Type -Namespace Pulse -Name DpiHelper -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
"@
[void][Pulse.DpiHelper]::SetProcessDpiAwarenessContext([IntPtr](-4)) # PER_MONITOR_AWARE_V2

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$claudeCredPath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$codexAuthPath  = Join-Path $env:USERPROFILE ".codex\auth.json"

function Invoke-ClaudeUsageCall {
    $cred  = Get-Content $claudeCredPath -Raw | ConvertFrom-Json
    $token = $cred.claudeAiOauth.accessToken
    $resp  = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
                -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 15
    [PSCustomObject]@{
        Session = [math]::Round($resp.five_hour.utilization)
        Weekly  = [math]::Round($resp.seven_day.utilization)
        Ok      = $true
    }
}

# The saved accessToken is only ~8h-lived and Pulse never refreshes it itself -
# only a real `claude` CLI invocation does that (via its refresh_token). After
# the PC has been off overnight that token is routinely dead on the first poll,
# which used to show "?" until you manually ran `claude` once. So on a 401,
# fire the cheapest possible real invocation to force that refresh, then retry
# once. Gated to once per 20 min so a genuine outage (network down, etc.)
# doesn't spam real Claude calls on every 5-minute poll.
$script:lastClaudeRefreshAttempt = $null
function Invoke-ClaudeTokenRefresh {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "claude"
        $psi.Arguments = '-p "hi" --model haiku'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(30000)) { $proc.Kill() }
    } catch {}
}

function Get-ClaudeUsage {
    try {
        Invoke-ClaudeUsageCall
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}

        $now = Get-Date
        $dueForRetry = -not $script:lastClaudeRefreshAttempt -or
            ($now - $script:lastClaudeRefreshAttempt).TotalMinutes -ge 20

        if ($status -eq 401 -and $dueForRetry) {
            $script:lastClaudeRefreshAttempt = $now
            Invoke-ClaudeTokenRefresh
            try { return Invoke-ClaudeUsageCall } catch {}
        }
        [PSCustomObject]@{ Session = $null; Weekly = $null; Ok = $false }
    }
}

function Get-ChatGptUsage {
    try {
        $auth      = Get-Content $codexAuthPath -Raw | ConvertFrom-Json
        $token     = $auth.tokens.access_token
        $accountId = $auth.tokens.account_id
        $resp      = Invoke-RestMethod -Uri "https://chatgpt.com/backend-api/wham/usage" `
                        -Headers @{ Authorization = "Bearer $token"; "chatgpt-account-id" = $accountId } `
                        -TimeoutSec 15
        [PSCustomObject]@{
            Session = [math]::Round($resp.rate_limit.primary_window.used_percent)
            Weekly  = [math]::Round($resp.rate_limit.secondary_window.used_percent)
            Ok      = $true
        }
    } catch {
        [PSCustomObject]@{ Session = $null; Weekly = $null; Ok = $false }
    }
}

# Pulse tray mark: an ECG/heartbeat line. Color reflects the worse of the four
# numbers - green under 70%, amber 70-89%, red 90%+, gray if a reading failed.
function New-PulseIcon([Nullable[int]]$maxPercent) {
    $color =
        if     ($null -eq $maxPercent) { [System.Drawing.Color]::FromArgb(140,140,140) }
        elseif ($maxPercent -ge 90)    { [System.Drawing.Color]::FromArgb(220,53,69)   }
        elseif ($maxPercent -ge 70)    { [System.Drawing.Color]::FromArgb(255,193,7)   }
        else                            { [System.Drawing.Color]::FromArgb(40,167,69)   }

    $bmp = New-Object System.Drawing.Bitmap 32,32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $pen = New-Object System.Drawing.Pen $color, 3
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $points = @(
        (New-Object System.Drawing.Point 1,16),
        (New-Object System.Drawing.Point 9,16),
        (New-Object System.Drawing.Point 12,6),
        (New-Object System.Drawing.Point 16,26),
        (New-Object System.Drawing.Point 19,16),
        (New-Object System.Drawing.Point 31,16)
    )
    $g.DrawLines($pen, $points)

    $g.Dispose()
    $hicon = $bmp.GetHicon()
    [System.Drawing.Icon]::FromHandle($hicon)
}

# ---- Custom hover popup (real Claude / ChatGPT marks, per-value colors) ----

$csharp = @"
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Reflection;
using System.Runtime.InteropServices;

public static class IconRectHelper {
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NOTIFYICONIDENTIFIER {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [DllImport("shell32.dll", SetLastError = true)]
    static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT iconLocation);

    public static Rectangle GetRect(NotifyIcon ni) {
        var fiId = typeof(NotifyIcon).GetField("id", BindingFlags.NonPublic | BindingFlags.Instance);
        var fiWindow = typeof(NotifyIcon).GetField("window", BindingFlags.NonPublic | BindingFlags.Instance);
        if (fiId == null || fiWindow == null) return Rectangle.Empty;
        NativeWindow nw = fiWindow.GetValue(ni) as NativeWindow;
        if (nw == null || nw.Handle == IntPtr.Zero) return Rectangle.Empty;

        var identifier = new NOTIFYICONIDENTIFIER();
        identifier.cbSize = (uint)Marshal.SizeOf(typeof(NOTIFYICONIDENTIFIER));
        identifier.hWnd = nw.Handle;
        identifier.uID = (uint)(int)fiId.GetValue(ni);

        RECT rect;
        int hr = Shell_NotifyIconGetRect(ref identifier, out rect);
        if (hr != 0) return Rectangle.Empty;
        return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
    }
}

public class PulsePopup : Form {
    public Label lblClaudeSession;
    public Label lblClaudeWeekly;
    public Label lblGptSession;
    public Label lblGptWeekly;
    public Label lblFooter;

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            const int WS_EX_NOACTIVATE = 0x08000000;
            const int WS_EX_TOOLWINDOW = 0x00000080;
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    private float dpiScale = 1.0F;
    private int S(int px) { return (int)Math.Round(px * dpiScale); }
    private Size S(int w, int h) { return new Size(S(w), S(h)); }
    private Point P(int x, int y) { return new Point(S(x), S(y)); }

    public PulsePopup(Image claudeImg, Image gptImg) {
        // Controls below are laid out with fixed pixel coordinates designed at
        // 100% scaling (96 DPI). WinForms' own AutoScale modes (Font/Dpi) proved
        // unreliable hosted inside powershell.exe, so instead every coordinate
        // is multiplied by the monitor's real scale factor by hand via S()/P().
        // Font sizes are in points, which GDI+ already resolves against DPI on
        // its own, so fonts are left unscaled.
        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) {
            dpiScale = g.DpiX / 96F;
        }

        this.FormBorderStyle = FormBorderStyle.None;
        this.StartPosition = FormStartPosition.Manual;
        this.ShowInTaskbar = false;
        this.TopMost = true;
        this.BackColor = Color.FromArgb(28,28,30);
        this.Size = S(258, 128);

        Font baseFont = new Font("Segoe UI", 9F);
        Font boldFont = new Font("Segoe UI", 9.5F, FontStyle.Bold);
        Color gray = Color.FromArgb(160,160,160);

        AddRow(claudeImg, "Claude", 10, out lblClaudeSession, out lblClaudeWeekly, baseFont, boldFont, gray);

        var divider = new Panel();
        divider.BackColor = Color.FromArgb(55,55,58);
        divider.Size = S(234, 1);
        divider.Location = P(12, 63);
        this.Controls.Add(divider);

        AddRow(gptImg, "ChatGPT", 70, out lblGptSession, out lblGptWeekly, baseFont, boldFont, gray);

        lblFooter = new Label();
        lblFooter.Text = "";
        lblFooter.ForeColor = Color.FromArgb(120,120,120);
        lblFooter.Font = new Font("Segoe UI", 7.5F);
        lblFooter.AutoSize = false;
        lblFooter.TextAlign = ContentAlignment.MiddleRight;
        lblFooter.Size = S(120, 16);
        lblFooter.Location = P(258 - 120 - 10, 8);
        this.Controls.Add(lblFooter);
    }

    private void AddRow(Image img, string name, int y, out Label sessionVal, out Label weeklyVal,
                         Font baseFont, Font boldFont, Color gray) {
        var pic = new PictureBox();
        pic.Image = img;
        pic.SizeMode = PictureBoxSizeMode.Zoom;
        pic.Size = S(20, 20);
        pic.Location = P(12, y);
        pic.BackColor = Color.Transparent;
        this.Controls.Add(pic);

        var nameLbl = new Label();
        nameLbl.Text = name;
        nameLbl.ForeColor = Color.White;
        nameLbl.Font = boldFont;
        nameLbl.AutoSize = true;
        nameLbl.Location = P(38, y + 1);
        this.Controls.Add(nameLbl);

        var sLbl = new Label();
        sLbl.Text = "Sesion";
        sLbl.ForeColor = gray;
        sLbl.Font = baseFont;
        sLbl.AutoSize = true;
        sLbl.Location = P(38, y + 22);
        this.Controls.Add(sLbl);

        sessionVal = new Label();
        sessionVal.Text = "--";
        sessionVal.Font = boldFont;
        sessionVal.ForeColor = Color.White;
        sessionVal.AutoSize = true;
        sessionVal.Location = P(95, y + 22);
        this.Controls.Add(sessionVal);

        var wLbl = new Label();
        wLbl.Text = "Semana";
        wLbl.ForeColor = gray;
        wLbl.Font = baseFont;
        wLbl.AutoSize = true;
        wLbl.Location = P(150, y + 22);
        this.Controls.Add(wLbl);

        weeklyVal = new Label();
        weeklyVal.Text = "--";
        weeklyVal.Font = boldFont;
        weeklyVal.ForeColor = Color.White;
        weeklyVal.AutoSize = true;
        weeklyVal.Location = P(207, y + 22);
        this.Controls.Add(weeklyVal);
    }
}
"@
Add-Type -TypeDefinition $csharp -ReferencedAssemblies System.Windows.Forms, System.Drawing

$claudeImg = [System.Drawing.Image]::FromFile((Join-Path $scriptDir "claude.png"))
$gptImg    = [System.Drawing.Image]::FromFile((Join-Path $scriptDir "chatgpt.png"))

$popup = New-Object PulsePopup($claudeImg, $gptImg)

function Set-PercentLabel($lbl, $val, $ok) {
    if (-not $ok -or $null -eq $val) {
        $lbl.Text = "?"
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(140,140,140)
        return
    }
    $lbl.Text = "$val%"
    $lbl.ForeColor =
        if     ($val -ge 90) { [System.Drawing.Color]::FromArgb(255,99,99)  }
        elseif ($val -ge 70) { [System.Drawing.Color]::FromArgb(255,193,7) }
        else                  { [System.Drawing.Color]::FromArgb(98,214,124) }
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Text = ""

function Update-Tray {
    $claude = Get-ClaudeUsage
    $gpt    = Get-ChatGptUsage

    Set-PercentLabel $popup.lblClaudeSession $claude.Session $claude.Ok
    Set-PercentLabel $popup.lblClaudeWeekly  $claude.Weekly  $claude.Ok
    Set-PercentLabel $popup.lblGptSession    $gpt.Session    $gpt.Ok
    Set-PercentLabel $popup.lblGptWeekly     $gpt.Weekly     $gpt.Ok
    $popup.lblFooter.Text = "actualizado $(Get-Date -Format 'HH:mm')"

    $vals = @($claude.Session, $claude.Weekly, $gpt.Session, $gpt.Weekly) | Where-Object { $null -ne $_ }
    $maxVal = if ($vals.Count -gt 0) { ($vals | Measure-Object -Maximum).Maximum } else { $null }

    $oldIcon = $notifyIcon.Icon
    $notifyIcon.Icon = New-PulseIcon $maxVal
    if ($oldIcon) { $oldIcon.Dispose() }
}

# Poll the real tray-icon screen rectangle (via Shell_NotifyIconGetRect) instead of
# relying on MouseMove events - Windows stops sending those once the cursor goes
# still, which caused the popup to close on its own while genuinely hovering.
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 150
$pollTimer.Add_Tick({
    $cursor = [System.Windows.Forms.Cursor]::Position
    $iconRect = [IconRectHelper]::GetRect($notifyIcon)
    $overIcon = (-not $iconRect.IsEmpty) -and $iconRect.Contains($cursor)
    $overPopup = $popup.Visible -and $popup.Bounds.Contains($cursor)

    if ($overIcon -and -not $popup.Visible) {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = [Math]::Min($iconRect.Left, $wa.Right - $popup.Width - 4)
        $x = [Math]::Max($x, $wa.Left + 4)
        $y = $wa.Bottom - $popup.Height - 4
        $popup.Location = New-Object System.Drawing.Point($x, $y)
        $popup.Show()
    } elseif (-not $overIcon -and -not $overPopup -and $popup.Visible) {
        $popup.Hide()
    }
})
$pollTimer.Start()

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$refreshItem = $menu.Items.Add("Actualizar ahora")
$refreshItem.Add_Click({ Update-Tray })
$menu.Items.Add("-") | Out-Null
$exitItem = $menu.Items.Add("Salir de Pulse")
$exitItem.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$notifyIcon.ContextMenuStrip = $menu

Update-Tray
$notifyIcon.Visible = $true

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 300000  # 5 minutes
$refreshTimer.Add_Tick({ Update-Tray })
$refreshTimer.Start()

[System.Windows.Forms.Application]::Run()
