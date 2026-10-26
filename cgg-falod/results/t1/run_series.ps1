param(
  [string]$Out = 'S:\godot\adaptivelod\cgg-falod\results\t1\pre',
  [string]$Tag = 'pre',
  [int]$Reps = 3,
  [string]$Modes = 'none,baseline,adaptive'
)
# Runs the benchmark scene sequentially, one process at a time, interleaving modes and resolutions.
$exe = 'S:\godot\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe'
$proj = 'S:\godot\adaptivelod\cgg-falod'
$log = Join-Path $Out "series_$Tag.log"
$modeList = $Modes.Split(',')
$profiles = @('normal', 'stress')
function Run-One($label, $mode, $profile, $extra) {
  $args = @('--path', $proj, 'res://scenes/benchmark.tscn', '--', "--bench-label=$label", "--bench-lod-mode=$mode", "--bench-profile=$profile", "--bench-out=$Out") + $extra
  $t0 = Get-Date
  $p = Start-Process -FilePath $exe -ArgumentList $args -PassThru -Wait -WindowStyle Minimized -RedirectStandardOutput (Join-Path $Out "$label.stdout.txt") -RedirectStandardError (Join-Path $Out "$label.stderr.txt")
  $gpu = (& nvidia-smi --query-gpu=clocks.gr,temperature.gpu --format=csv,noheader) -join ';'
  "$(Get-Date -Format o) $label exit=$($p.ExitCode) secs=$([int]((Get-Date)-$t0).TotalSeconds) gpu_after=$gpu" | Add-Content $log
}
for ($r = 1; $r -le $Reps; $r++) {
  foreach ($prof in $profiles) {
    # rotate the mode order each repetition so no mode is always first or last
    $order = @(); for ($i = 0; $i -lt $modeList.Count; $i++) { $order += $modeList[($i + $r - 1) % $modeList.Count] }
    foreach ($m in $order) {
      if ($m -eq 'sched0') { Run-One "${Tag}_${prof}_${m}_$r" 'adaptive' $prof @('--bench-bias-max=0') }
      else { Run-One "${Tag}_${prof}_${m}_$r" $m $prof @() }
    }
  }
}
"$(Get-Date -Format o) series $Tag finished" | Add-Content $log
