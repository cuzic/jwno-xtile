# SPIKE for ADR 0011 stage 0: does ITaskbarList::DeleteTab (via Janet FFI in Jwno) remove another process's
# taskbar button, and does it stay removed? Measurements only (INFO unless the call itself fails).
param([string]$Jwno, [string]$RepoRoot, [string]$Config, [string]$Out = "spike-out", [int]$ReplPort = 9997)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$log = Join-Path $Out "taskbar.log"
Remove-Item $log -ErrorAction SilentlyContinue
$env:TB_OUT = $log
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class T {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr h, bool inv);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  public static IntPtr ByTitle(string needle) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, _) => { var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256);
      if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; } return true; }, IntPtr.Zero);
    return found; }
}
"@
[void][T]::SetProcessDPIAware()
$ShotDir = Join-Path $Out "shots"
# a picture of the taskbar strip (bottom of the primary screen, the taskbar plus a margin): the effect of DeleteTab is judged by looking
function Shot($name) {
  New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen
  $b = $scr.Bounds; $wa = $scr.WorkingArea
  $h = [Math]::Max($b.Bottom - $wa.Bottom, 0) + 24; if ($h -lt 100) { $h = 100 }
  $w = [Math]::Min($b.Width, 1000); $x = $b.Left + [int](($b.Width - $w) / 2)
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $b.Bottom - $h, 0, 0, (New-Object System.Drawing.Size($w, $h)))
  $bmp.Save((Join-Path $ShotDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
$results = New-Object System.Collections.ArrayList
function Check($id, $status, $what, $detail) {
  [void]$results.Add([pscustomobject]@{ id = $id; status = $status; what = $what; detail = "$detail" })
  Write-Host ("[{0}] {1}  {2}  -- {3}" -f $status, $id, $what, $detail)
}
function LogLines { if (Test-Path $log) { Get-Content $log } else { @() } }
function WaitFor([scriptblock]$pred, [int]$sec = 10) {
  $until = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $until) { if (& $pred) { return $true }; Start-Sleep -Milliseconds 250 }
  return [bool](& $pred)
}
function AltShift([byte]$vk) {
  [T]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [T]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
  [T]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); [T]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
  [T]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero); [T]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
}
# taskbar buttons whose name contains $needle (UI Automation over Shell_TrayWnd, all descendants)
function TaskbarButtons($needle) {
  # the taskbar lives under the desktop root in UI Automation (Windows 11: XAML islands under Shell_TrayWnd);
  # only elements whose window is the taskbar are counted: parent chain contains "Shell_TrayWnd" or "Taskbar"
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $tray = $root.FindFirst([System.Windows.Automation.TreeScope]::Children,
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "Shell_TrayWnd")))
  if ($null -eq $tray) { return $null }
  $all = $tray.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $names = @($all | ForEach-Object { $_.Current.Name } | Where-Object { $_ -like "*$needle*" })
  Write-Host ("  (taskbar elements seen: {0}; matching '{1}': {2})" -f $all.Count, $needle, $names.Count)
  ,$names
}

# our OWN test window (a WinForms form with a unique title, in its own process): never a window of the user's
$pwsh = (Get-Process -Id $PID).Path
$np = Start-Process -FilePath $pwsh -WindowStyle Minimized -PassThru -ArgumentList @("-NoProfile", "-STA", "-Command",
  "Add-Type -AssemblyName System.Windows.Forms; `$f = New-Object System.Windows.Forms.Form; `$f.Text = 'XTILE-TB-SPIKE'; `$f.Width = 300; `$f.Height = 120; `$f.ShowInTaskbar = `$true; [System.Windows.Forms.Application]::Run(`$f)")
[void](WaitFor { [T]::ByTitle("XTILE-TB-SPIKE") -ne [IntPtr]::Zero } 20)
Start-Sleep 1
$nph = [T]::ByTitle("XTILE-TB-SPIKE")
$tray = [T]::FindWindow("Shell_TrayWnd", $null)
Check "TB-0" "INFO" "a taskbar exists in this session; the test window (XTILE-TB-SPIKE) exists" ("Shell_TrayWnd=$($tray -ne [IntPtr]::Zero) testwindow=$($nph -ne [IntPtr]::Zero)")
Start-Sleep 2; Shot "1-before"
$before = TaskbarButtons "spike"
Check "TB-1" "INFO" "taskbar buttons that mention Notepad before anything" ($(if ($null -eq $before) { "no taskbar" } else { "$($before.Count): " + ($before -join " | ") }))

$jargs = @("--mod-path", $RepoRoot, "--config", $Config, "--log-file", (Join-Path $Out "taskbar-jwno.log"),
           "--log-level", "debug", "--no-console", "--repl", "127.0.0.1:$ReplPort")
$j = Start-Process -FilePath $Jwno -ArgumentList $jargs -PassThru
$up = WaitFor { (LogLines | Where-Object { $_ -match 'config-end' }).Count -gt 0 } 25
Check "TB-2" ($(if ($up) { "PASS" } else { "FAIL" })) "the spike config loads" ((LogLines | Select-Object -First 6) -join " | ")
if ($up) {
  AltShift 0x76                                         # Alt+Shift+F7: DeleteTab
  $called = WaitFor { (LogLines | Where-Object { $_ -match 'delete-tab|error|cocreate' }).Count -gt 1 } 6
  Check "TB-3" "INFO" "DeleteTab was called (HRESULTs: 0 = S_OK)" ((LogLines | Where-Object { $_ -match 'cocreate|hrinit|delete-tab|error|no-window' }) -join " | ")
  Start-Sleep 2; Shot "2-after-DeleteTab"
  $after = TaskbarButtons "spike"
  Check "TB-4" "INFO" "taskbar buttons that mention Notepad after DeleteTab" ($(if ($null -eq $after) { "no taskbar" } else { "$($after.Count): " + ($after -join " | ") }))
  # does it stay removed? activate, retitle, flash
  [void][T]::SetForegroundWindow($nph); Start-Sleep 2; Shot "3-activated"
  $a1 = TaskbarButtons "spike"
  Check "TB-5a" "INFO" "after the window was activated" ($(if ($null -eq $a1) { "no taskbar" } else { "$($a1.Count)" }))
  [void][T]::SendMessage($nph, 0x000C, [IntPtr]::Zero, "Renamed by the spike"); Start-Sleep 2; Shot "4-retitled"
  $a2 = TaskbarButtons "spike"
  Check "TB-5b" "INFO" "after its title changed" ($(if ($null -eq $a2) { "no taskbar" } else { "$($a2.Count): " + ($a2 -join " | ") }))
  [void][T]::FlashWindow($nph, $true); Start-Sleep 2; Shot "5-flashed"
  $a3 = TaskbarButtons "spike"
  Check "TB-5c" "INFO" "after FlashWindow" ($(if ($null -eq $a3) { "no taskbar" } else { "$($a3.Count)" }))
  AltShift 0x75                                         # Alt+Shift+F6: AddTab
  Start-Sleep 2; Shot "6-AddTab"
  $back = TaskbarButtons "spike"
  Check "TB-6" "INFO" "after AddTab" ($(if ($null -eq $back) { "no taskbar" } else { "$($back.Count)" }))
}
Stop-Process -Id $np.Id -Force -ErrorAction SilentlyContinue
Start-Sleep 2; Shot "7-closed"
if ($j -and -not $j.HasExited) { Stop-Process -Id $j.Id -Force -ErrorAction SilentlyContinue }
$results | ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $Out "taskbar-results.json")
$fail = @($results | Where-Object { $_.status -eq "FAIL" }).Count
Write-Host ("TASKBAR PASS={0} FAIL={1} INFO={2}" -f @($results | Where-Object { $_.status -eq "PASS" }).Count, $fail, @($results | Where-Object { $_.status -eq "INFO" }).Count)
exit ([int]($fail -gt 0))
