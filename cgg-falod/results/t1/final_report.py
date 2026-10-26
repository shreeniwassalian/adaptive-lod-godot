"""Final-run analysis. Usage: python final_report.py <final_run_dir>
Reuses analyze.py (per-run table, cells table, avg-FPS / frame-time / FPS-over-time / bias charts) on <dir>/bench and adds
the GPU-time chart and the baseline-vs-adaptive results table (the two formulas from the task, per resolution)."""
import sys, os, glob, json, csv
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import analyze  # noqa: E402

FINAL = os.path.abspath(sys.argv[1]).replace('\\', '/') + '/'
analyze.BASE = FINAL
analyze.main(['bench'])  # writes FINAL/analysis_bench/*
OUT = FINAL + 'analysis_bench/'

runs = []
for j in sorted(glob.glob(FINAL + 'bench/*.json')):
    r, _ = analyze.load_run(j)
    runs.append(r)


def cell(prof, mode, key):
    v = np.array([r[key] for r in runs if r['profile'] == prof and r['mode'] == mode], float)
    return v


BG = '#1b1f27'; FG = '#e6e9ef'; MUT = '#9aa3b2'
plt.rcParams.update({'text.color': FG, 'axes.labelcolor': FG, 'xtick.color': MUT, 'ytick.color': MUT})
# GPU render-time chart
fig, axs = plt.subplots(1, 2, figsize=(11, 4.2), facecolor=BG)
for ax, prof in zip(axs, ['normal', 'stress']):
    ax.set_facecolor(BG)
    for s in ax.spines.values(): s.set_color('#3a4150')
    ax.spines['top'].set_visible(False); ax.spines['right'].set_visible(False); ax.grid(axis='y', color='#2c3340'); ax.set_axisbelow(True)
    top = 0
    for i, (mode, c) in enumerate([('none', '#9aa3b2'), ('baseline', '#7b8494'), ('adaptive', '#35d0e8')]):
        v = cell(prof, mode, 'gpu_mean')
        if len(v) == 0: continue
        ax.bar(i, v.mean(), color=c, width=.6)
        ax.errorbar(i, v.mean(), yerr=v.std(ddof=1) if len(v) > 1 else 0, color=FG, capsize=4, lw=1)
        ax.scatter([i] * len(v), v, color='white', s=14, zorder=3)
        hi = max(v.max(), v.mean() + (v.std(ddof=1) if len(v) > 1 else 0)); top = max(top, hi)
        ax.text(i, hi * 1.03, '%.1f' % v.mean(), ha='center', fontsize=9)
    ax.set_xticks([0, 1, 2]); ax.set_xticklabels(['None', 'Baseline', 'Adaptive']); ax.set_ylim(0, top * 1.18)
    ax.set_ylabel('Mean GPU render time, ms (lower is better)')
    ax.set_title('%s, n=%d per mode; bars = mean, whiskers = sd, dots = runs' % (prof, len(cell(prof, 'baseline', 'gpu_mean'))), fontsize=8.5, loc='left', color=FG)
plt.tight_layout(); plt.savefig(OUT + 'chart_gpu_time.png', dpi=160, facecolor=BG); plt.close()

# results table with the task's formulas
lines = ['| Resolution | Mode | n | Avg FPS (mean ± sd) | Median FPS | 1% low FPS (1000/p99) | Mean frame ms | p95 ms | p99 ms | GPU ms | FPS change vs baseline | Frame-time reduction vs baseline |', '|' + '---|' * 12]
summary = {}
for prof, res in [('normal', '1920x1080'), ('stress', '2560x1440')]:
    b_fps = cell(prof, 'baseline', 'avg_fps').mean(); b_ft = cell(prof, 'baseline', 'ft_mean').mean()
    for mode in ['none', 'baseline', 'adaptive']:
        n = len(cell(prof, mode, 'avg_fps'))
        if n == 0: continue
        f = lambda k: cell(prof, mode, k)
        fps_change = (f('avg_fps').mean() - b_fps) / b_fps * 100
        ft_red = (b_ft - f('ft_mean').mean()) / b_ft * 100
        sd = f('avg_fps').std(ddof=1) if n > 1 else 0
        lines.append('| %s | %s | %d | %.1f ± %.1f | %.1f | %.1f | %.2f | %.1f | %.1f | %.2f | %s | %s |' % (
            res, mode, n, f('avg_fps').mean(), sd, f('med_fps').mean(), f('low1_p99').mean(), f('ft_mean').mean(), f('ft_p95').mean(), f('ft_p99').mean(), f('gpu_mean').mean(),
            '-' if mode == 'baseline' else '%+.1f%%' % fps_change, '-' if mode == 'baseline' else '%+.1f%%' % ft_red))
        summary['%s|%s' % (prof, mode)] = dict(n=n, avg_fps=f('avg_fps').tolist(), ft_mean=f('ft_mean').tolist(), gpu=f('gpu_mean').tolist())
# paired by repetition
lines += ['', 'Paired by repetition (same slot of the rotating order), FPS change = (Adaptive - Baseline) / Baseline x 100; frame-time reduction = (Baseline - Adaptive) / Baseline x 100:', '']
lines += ['| Resolution | Rep | Baseline FPS | Adaptive FPS | FPS change | Baseline ms | Adaptive ms | Frame-time reduction | Baseline GPU ms | Adaptive GPU ms |', '|' + '---|' * 10]
for prof, res in [('normal', '1920x1080'), ('stress', '2560x1440')]:
    for rep in range(1, 6):
        b = [r for r in runs if r['profile'] == prof and r['mode'] == 'baseline' and r['file'].split('_')[3] == str(rep)]
        a = [r for r in runs if r['profile'] == prof and r['mode'] == 'adaptive' and r['file'].split('_')[3] == str(rep)]
        if not b or not a: continue
        b, a = b[0], a[0]
        lines.append('| %s | %d | %.1f | %.1f | %+.1f%% | %.2f | %.2f | %+.1f%% | %.2f | %.2f |' % (
            res, rep, b['avg_fps'], a['avg_fps'], (a['avg_fps'] - b['avg_fps']) / b['avg_fps'] * 100, b['ft_mean'], a['ft_mean'], (b['ft_mean'] - a['ft_mean']) / b['ft_mean'] * 100, b['gpu_mean'], a['gpu_mean']))
open(OUT + 'results_table.md', 'w').write('\n'.join(lines) + '\n')
json.dump(summary, open(OUT + 'results_summary.json', 'w'), indent=1)
print('\n'.join(lines))
