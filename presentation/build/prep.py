import json, glob, csv
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from PIL import Image

R = 'S:/godot/adaptivelod/cgg-falod/results/'
O = 'S:/godot/adaptivelod/presentation/'
BG = '#1b1f27'; FG = '#e6e9ef'; MUT = '#9aa3b2'; CY = '#35d0e8'; GR = '#7b8494'; VI = '#a78bfa'; RD = '#ff6b6b'


def load(prefix):
    f = glob.glob(R + prefix + '_2026*.csv')[0]
    r = list(csv.DictReader(open(f)))
    return (np.array([float(x['t_s']) for x in r]), np.array([float(x['frame_time_ms']) for x in r]),
            np.array([float(x['lod_bias']) if x['lod_bias'] else 0 for x in r]))


def stats(prefix):
    t, ft, b = load(prefix)
    p99 = np.percentile(ft, 99)
    return dict(n=len(ft), avg=len(ft) / t[-1], med=1000 / np.median(ft), low1=1000 / ft[ft >= p99].mean(),
                minfps=1000 / ft.max(), ft_mean=ft.mean(), ft_p99=p99, ft_max=ft.max(),
                sub10=int((1000 / ft < 10).sum()), bias=b.mean())


runs = {'normal_base': ['m4_normal_base_1', 'm4_normal_base_2', 'm4_normal_base_3'],
        'normal_adapt': ['m4_normal_adapt_1', 'm4_normal_adapt_2', 'm4_normal_adapt_3'],
        'stress_base': ['m4_stress_base_1', 'm4_stress_base_2'],
        'stress_adapt': ['m4_stress_adapt_1', 'm4_stress_adapt_2']}
S = {k: [stats(p) for p in v] for k, v in runs.items()}
out = {'per_run': S}
for prof, sel in [('stress', slice(None)), ('normal_all', slice(None)), ('normal_b23', slice(1, None))]:
    b, a = ('stress_base', 'stress_adapt') if prof == 'stress' else ('normal_base', 'normal_adapt')
    d = {}
    for m in ['avg', 'med', 'low1', 'ft_mean', 'ft_p99', 'minfps']:
        bv = np.mean([s[m] for s in S[b][sel]]); av = np.mean([s[m] for s in S[a]])
        d[m] = dict(base=float(bv), adapt=float(av), pct=float((av - bv) / bv * 100))
    out[prof] = d
json.dump(out, open(O + 'build/stats.json', 'w'), indent=1)


def binned(prefix):
    t, ft, b = load(prefix)
    n = int(t[-1])
    return [float(((t >= i) & (t < i + 1)).sum()) for i in range(n)], [float(b[(t >= i) & (t < i + 1)].mean()) for i in range(n)]


ts = {k: binned(k) for k in ['m4_stress_base_1', 'm4_stress_adapt_1', 'm4_normal_base_1', 'm4_normal_base_2',
                              'm4_normal_adapt_1', 'm4_normal_adapt_2']}
json.dump(ts, open(O + 'build/timeseries.json', 'w'))
plt.rcParams.update({'font.family': 'DejaVu Sans', 'text.color': FG, 'axes.labelcolor': FG,
                     'xtick.color': MUT, 'ytick.color': MUT})


def ax_style(ax):
    ax.set_facecolor(BG)
    for s in ax.spines.values(): s.set_color('#3a4150')
    ax.spines['top'].set_visible(False); ax.spines['right'].set_visible(False)
    ax.grid(axis='y', color='#2c3340'); ax.set_axisbelow(True)


fig, axs = plt.subplots(1, 2, figsize=(11, 4.6), facecolor=BG, gridspec_kw={'width_ratios': [3, 1]})
d = out['stress']; ms = [('avg', 'Average FPS'), ('med', 'Median FPS'), ('low1', '1% low FPS'), ('minfps', 'Min FPS')]
ax = axs[0]; ax_style(ax); x = np.arange(len(ms)); w = .36
r1 = ax.bar(x - w / 2, [d[m]['base'] for m, _ in ms], w, color=GR, label='Baseline (n=2)')
r2 = ax.bar(x + w / 2, [d[m]['adapt'] for m, _ in ms], w, color=CY, label='Adaptive (n=2)')
for r in list(r1) + list(r2): ax.text(r.get_x() + r.get_width() / 2, r.get_height() + .4, f'{r.get_height():.1f}', ha='center', fontsize=9, color=FG)
ax.set_xticks(x); ax.set_xticklabels([n for _, n in ms]); ax.set_ylabel('FPS  (higher is better)'); ax.set_ylim(0, 40)
ax.legend(facecolor=BG, edgecolor='#3a4150', labelcolor=FG)
ax.set_title('Stress profile, 2560x1440, 60 s per run', color=FG, fontsize=11, loc='left')
ax = axs[1]; ax_style(ax)
fv = [d['ft_mean']['base'], d['ft_mean']['adapt']]
ax.bar([0, 1], fv, color=[GR, CY], width=.6)
for i, v in enumerate(fv): ax.text(i, v + .4, f'{v:.2f}', ha='center', fontsize=9)
ax.set_xticks([0, 1]); ax.set_xticklabels(['Baseline', 'Adaptive']); ax.set_ylabel('Mean frame time, ms (lower is better)'); ax.set_ylim(0, 40)
plt.tight_layout(); plt.savefig(O + 'charts/chart_stress_summary.png', dpi=160, facecolor=BG); plt.close()

fig, ax = plt.subplots(figsize=(11, 4.4), facecolor=BG); ax_style(ax)
labs = []; vals = []; cols = []
for k, c in [('normal_base', GR), ('normal_adapt', CY), ('stress_base', GR), ('stress_adapt', CY)]:
    for i, s in enumerate(S[k]):
        labs.append(k.replace('_', ' ') + f' #{i + 1}'); vals.append(s['avg']); cols.append(c)
ax.bar(range(len(vals)), vals, color=cols)
for i, v in enumerate(vals): ax.text(i, v + 1, f'{v:.1f}', ha='center', fontsize=9)
ax.set_xticks(range(len(vals))); ax.set_xticklabels(labs, rotation=30, ha='right', fontsize=8); ax.set_ylabel('Average FPS (higher is better)')
ax.annotate('normal base #1: 104 FPS; GPU state changed\nmid-series (9.3 ms vs ~19 ms GPU)', xy=(0, 104), xytext=(1.3, 92), color=RD, fontsize=9, arrowprops=dict(arrowstyle='->', color=RD))
ax.set_title('Every recorded run, none omitted (grey = baseline, cyan = adaptive)', color=FG, fontsize=11, loc='left')
plt.tight_layout(); plt.savefig(O + 'charts/chart_all_runs_avg_fps.png', dpi=160, facecolor=BG); plt.close()

fig, axs = plt.subplots(1, 2, figsize=(12, 4.2), facecolor=BG)
cfg = [('Stress 1440p', [('m4_stress_base_1', 'Baseline #1', GR, '-'), ('m4_stress_adapt_1', 'Adaptive #1', CY, '-')]),
       ('Normal 1080p', [('m4_normal_base_1', 'Baseline #1 (outlier)', GR, ':'), ('m4_normal_base_2', 'Baseline #2', GR, '-'),
                         ('m4_normal_adapt_1', 'Adaptive #1', CY, '-'), ('m4_normal_adapt_2', 'Adaptive #2', VI, '-')])]
for ax, (title, pairs) in zip(axs, cfg):
    ax_style(ax)
    for k, l, c, ls in pairs: ax.plot(ts[k][0], color=c, ls=ls, label=l, lw=1.6)
    ax.set_title(title + ': frames per second, 1 s bins', color=FG, fontsize=10, loc='left'); ax.set_xlabel('time in measured run (s)')
    ax.set_ylabel('FPS (higher is better)'); ax.set_ylim(0); ax.legend(facecolor=BG, edgecolor='#3a4150', labelcolor=FG, fontsize=8)
plt.tight_layout(); plt.savefig(O + 'charts/chart_fps_over_time.png', dpi=160, facecolor=BG); plt.close()

fig, ax = plt.subplots(figsize=(7, 3.6), facecolor=BG); ax_style(ax)
for k, l, c in [('m4_normal_adapt_1', 'Normal #1', CY), ('m4_stress_adapt_1', 'Stress #1', VI)]: ax.plot(ts[k][1], color=c, label=l)
ax.axhline(2, color=RD, ls='--', lw=1); ax.text(1, 2.03, 'bias_max = 2.0', color=RD, fontsize=8)
ax.set_ylim(0, 2.3); ax.set_ylabel('controller bias (0 = baseline)'); ax.set_xlabel('time (s)'); ax.legend(facecolor=BG, edgecolor='#3a4150', labelcolor=FG)
plt.tight_layout(); plt.savefig(O + 'charts/chart_controller_bias.png', dpi=160, facecolor=BG); plt.close()

fig, axs = plt.subplots(1, 3, figsize=(9, 3), facecolor=BG)
for ax, (n, l) in zip(axs, [(48, 'High detail'), (16, 'Medium detail'), (6, 'Low detail')]):
    ax.set_facecolor(BG); ax.axis('off'); ax.set_aspect('equal')
    th = np.linspace(0, 2 * np.pi, n + 1)
    ax.fill(np.cos(th), np.sin(th), color='#24303f'); ax.plot(np.cos(th), np.sin(th), color=CY, lw=1.5)
    for i in range(n): ax.plot([0, np.cos(th[i])], [0, np.sin(th[i])], color=CY, lw=.5, alpha=.6)
    ax.set_title(l, color=FG, fontsize=12)
plt.tight_layout(); plt.savefig(O + 'charts/diagram_lod_levels_schematic.png', dpi=160, facecolor=BG); plt.close()

P = R + 'probe/smooth/'
for n, src in [('baseline', 'smooth_v0_baseline.png'), ('adaptive', 'smooth_v0_new_b2.0.png')]:
    im = Image.open(P + src).convert('RGB')
    im.resize((960, 540), Image.LANCZOS).save(O + f'images/{n}_v0.jpg', quality=90)
    im.crop((0, 330, 640, 690)).resize((960, 540), Image.LANCZOS).save(O + f'images/{n}_v0_crop.jpg', quality=92)
Image.open(P + 'smooth_v0_baseline.png').convert('RGB').resize((1280, 720), Image.LANCZOS).save(O + 'images/title_scene.jpg', quality=90)
print(json.dumps({k: out[k] for k in ['stress', 'normal_all', 'normal_b23']}, indent=1))
for k in S: print(k, [(round(s['avg'], 1), round(s['med'], 1), round(s['low1'], 1), round(s['minfps'], 1)) for s in S[k]])
