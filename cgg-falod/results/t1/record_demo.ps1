param(
  [Parameter(Mandatory = $true)][string]$Out,   # media directory (absolute)
  [string]$Godot = 'S:\godot\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe',
  [string]$Proj = 'S:\godot\adaptivelod\cgg-falod',
  [string]$Ffmpeg = 'C:\ffmpeg\ffmpeg-2026-06-15-git-44d082edc8-essentials_build\ffmpeg-2026-06-15-git-44d082edc8-essentials_build\bin\ffmpeg.exe'
)
# Launches the scripted demo, records the desktop area of its borderless 1920x1080 window (top-left corner) with FFmpeg gdigrab,
# and writes <Out>\record_log.txt with the wall-clock offsets of the demo steps relative to the start of the raw recording.
New-Item -ItemType Directory -Force $Out | Out-Null
$stdout = Join-Path $Out 'demo_stdout.txt'
$raw = Join-Path $Out 'demo_raw.mkv'
$log = Join-Path $Out 'record_log.txt'
Remove-Item $stdout, $raw, $log -ErrorAction SilentlyContinue
$demo = Start-Process -FilePath $Godot -ArgumentList @('--path', $Proj, 'res://scenes/demo.tscn', '--', "--demo-out=$Out") -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError (Join-Path $Out 'demo_stderr.txt')
# wait until the demo window exists (its _ready prints the "window" line)
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline -and -not ((Test-Path $stdout) -and (Select-String -Path $stdout -Pattern '^\[demo\] window' -Quiet))) { Start-Sleep -Milliseconds 200 }
Start-Sleep -Milliseconds 500
$ffArgs = @('-hide_banner', '-loglevel', 'warning', '-y', '-f', 'gdigrab', '-framerate', '30', '-draw_mouse', '0', '-offset_x', '0', '-offset_y', '0', '-video_size', '1920x1080', '-i', 'desktop',
            '-t', '140', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', $raw)
$t0 = Get-Date
$ff = Start-Process -FilePath $Ffmpeg -ArgumentList $ffArgs -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Out 'ffmpeg_stderr.txt')
"ffmpeg started at demo window + $([math]::Round(((Get-Date) - $t0).TotalSeconds,2)) s (t0)" | Set-Content $log
$seen = @{}
while (-not $demo.HasExited) {
  if (Test-Path $stdout) {
    foreach ($l in (Get-Content $stdout -ErrorAction SilentlyContinue)) {
      if ($l -match '^\[demo\] (step \S+|finished)' -and -not $seen.ContainsKey($l)) {
        $seen[$l] = $true
        "$([math]::Round(((Get-Date) - $t0).TotalSeconds,2)) s  $l" | Add-Content $log
      }
    }
  }
  Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 2
# the recording is stopped by killing only the ffmpeg process started above (mkv survives this); the demo has already exited
if (-not $ff.HasExited) { Stop-Process -Id $ff.Id -Force }
"demo exit code $($demo.ExitCode)" | Add-Content $log
Get-Content $log
