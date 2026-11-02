Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class D { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
$s = [System.Windows.Forms.Screen]::PrimaryScreen
"before DPI-aware: bounds=$($s.Bounds) working=$($s.WorkingArea)"
[void][D]::SetProcessDPIAware()
$s = [System.Windows.Forms.Screen]::PrimaryScreen
"after  DPI-aware: bounds=$($s.Bounds) working=$($s.WorkingArea)"
"screens: " + [System.Windows.Forms.Screen]::AllScreens.Count
Get-ChildItem C:\Users\cuzic\xtile-realtest\out\shots -Filter *.png | ForEach-Object { $i = [System.Drawing.Image]::FromFile($_.FullName); "$($_.Name) $($i.Width)x$($i.Height)"; $i.Dispose() }
