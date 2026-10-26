param([Parameter(Mandatory = $true)][string]$Out, [int]$Reps = 3, [string]$Tag = 'supp')
# Supplementary series: 1080p (profile normal), baseline vs adaptive with the controller target lowered to 8 ms (the stress-profile target),
# so that the controller engages when the GPU is in its fast state. Same harness and options as run_series.ps1, order rotated per repetition.
$exe = 'S:\godot\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe'
$proj = 'S:\godot\adaptivelod\cgg-falod'
New-Item -ItemType Directory -Force $Out | Out-Null
$log = Join-Path $Out "series_$Tag.log"
for ($r = 1; $r -le $Reps; $r++) {
  $order = if ($r % 2 -eq 1) { @('baseline', 'adaptive') } else { @('adaptive', 'baseline') }
  foreach ($m in $order) {
    $label = "${Tag}_1080p_t8_${m}_$r"
    $a = @('--path', $proj, 'res://scenes/benchmark.tscn', '--', "--bench-label=$label", "--bench-lod-mode=$m", '--bench-profile=normal', "--bench-out=$Out")
    if ($m -eq 'adaptive') { $a += '--bench-target-ms=8' }
    $p = Start-Process -FilePath $exe -ArgumentList $a -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Out "$label.stdout.txt") -RedirectStandardError (Join-Path $Out "$label.stderr.txt")
    "$(Get-Date -Format o) $label exit=$($p.ExitCode)" | Add-Content $log
  }
}
"$(Get-Date -Format o) finished" | Add-Content $log
