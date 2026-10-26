"""Aggregates a benchmark series (results/t1/<tag>/*.csv|json) into per-run and per-cell tables, and charts.
Usage: python analyze.py <tag> [<tag2> ...]   (tags are folder names under results/t1)
All numbers come from the per-frame CSV; nothing is estimated. Empty cells are skipped (unavailable)."""
import sys, json, glob, csv, os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

BASE = 'S:/godot/adaptivelod/cgg-falod/results/t1/'
COL = {'none': '#9aa3b2', 'baseline': '#7b8494', 'sched0': '#a78bfa', 'adaptive': '#35d0e8'}


def col(rows, name):
    out = []
    for r in rows:
        v = r.get(name, '')
        out.append(float(v) if v not in ('', None) else np.nan)
    return np.array(out)


def load_run(jpath):
    d = json.load(open(jpath))
    rows = list(csv.DictReader(open(jpath[:-5] + '.csv')))
    ft = col(rows, 'frame_time_ms'); t = col(rows, 't_s')
    gpu = col(rows, 'render_gpu_ms'); bias = col(rows, 'lod_bias')
    p99 = np.percentile(ft, 99)
    ctrl = d.get('adaptive', {}).get('run', {}) if d['config']['lod_mode'] == 'adaptive' else {}
    r = dict(
        file=os.path.basename(jpath)[:-5], mode=('sched0' if (d['config']['lod_mode']=='adaptive' and d['config'].get('controller',{}).get('bias_max',2)==0) else d['config']['lod_mode']), profile=d['config']['profile'],
        res='%sx%s' % (d['config']['requested_width'], d['config']['requested_height']), n=len(ft),
        avg_fps=len(ft) / t[-1], med_fps=1000 / np.median(ft), low1_p99=1000 / p99,
        low1_mean=1000 / ft[ft >= p99].mean(), min_fps=1000 / ft.max(),
        ft_mean=np.nanmean(ft), ft_p95=np.percentile(ft, 95), ft_p99=p99, ft_max=ft.max(),
        gpu_mean=np.nanmean(gpu) if np.isfinite(gpu).any() else np.nan,
        draws_vis=np.nanmean(col(rows, 'draw_calls_visible')), prims_vis=np.nanmean(col(rows, 'primitives_visible')),
        draws_all=np.nanmean(col(rows, 'draw_calls')), prims_all=np.nanmean(col(rows, 'primitives')),
        sub10=int((1000 / ft < 10).sum()), hitch33=int((ft > 33.4).sum()),
        switches=float(np.nansum(col(rows, 'lod_switches')) + np.nansum(col(rows, 'grass_switches')) + np.nansum(col(rows, 'bush_switches')) + np.nansum(col(rows, 'debris_switches'))),
        policy_cpu=np.nanmean(col(rows, 'lod_total_update_ms')) if np.isfinite(col(rows, 'lod_total_update_ms')).any() else np.nan,
        render_cpu=np.nanmean(col(rows, 'render_cpu_ms')),
        bias_mean=np.nanmean(bias) if np.isfinite(bias).any() else np.nan,
        sat_pct=100.0 * ctrl.get('frames_at_bias_max', 0) / len(ft) if ctrl else np.nan,
        reversals=ctrl.get('bias_reversals', np.nan), target=d['config'].get('controller', {}).get('target_ms') if ctrl else np.nan,
        completed=d.get('completed'), path_sha=d['camera_path']['sha256'][:12], adapter=d['display'].get('adapter'),
        driver=d['display'].get('rendering_driver'), build='debug' if d['engine'].get('debug_build') else 'release',
        editor=d['engine'].get('editor_build'), start=d['started_unix'],
    )
    return r, (t, ft, gpu, bias, col(rows, 'ctrl_signal_ms'))


def main(tags):
    runs = []; series = {}
    for tag in tags:
        for j in sorted(glob.glob(BASE + tag + '/*.json')):
            r, s = load_run(j); r['tag'] = tag; runs.append(r); series[r['file']] = s
    runs.sort(key=lambda r: r['start'])
    out = BASE + 'analysis_' + '_'.join(tags)
    os.makedirs(out, exist_ok=True)
    keys = ['tag', 'file', 'mode', 'profile', 'res', 'n', 'avg_fps', 'med_fps', 'low1_p99', 'low1_mean', 'min_fps', 'ft_mean', 'ft_p95', 'ft_p99', 'ft_max',
            'gpu_mean', 'render_cpu', 'draws_vis', 'prims_vis', 'draws_all', 'prims_all', 'sub10', 'hitch33', 'switches', 'policy_cpu', 'bias_mean', 'sat_pct', 'reversals', 'target', 'completed', 'path_sha', 'build', 'editor', 'adapter', 'driver']
    with open(out + '/per_run.csv', 'w', newline='') as f:
        w = csv.writer(f); w.writerow(keys)
        for r in runs: w.writerow([('%.4g' % r[k]) if isinstance(r[k], (float, np.floating)) else r[k] for k in keys])
    # cells
    cells = {}
    for r in runs:
        cells.setdefault((r['tag'], r['profile'], r['mode']), []).append(r)
    metrics = ['avg_fps', 'med_fps', 'low1_p99', 'low1_mean', 'min_fps', 'ft_mean', 'ft_p95', 'ft_p99', 'gpu_mean', 'render_cpu', 'draws_vis', 'prims_vis', 'switches', 'policy_cpu', 'bias_mean', 'sat_pct', 'sub10']
    summary = {}
    lines = []
    for (tag, prof, mode), rs in sorted(cells.items()):
        d = {'n': len(rs)}
        for m in metrics:
            v = np.array([r[m] for r in rs], float)
            d[m] = [float(np.nanmean(v)) if np.isfinite(v).any() else None, float(np.nanstd(v, ddof=1)) if np.isfinite(v).sum() > 1 else None, float(np.nanmin(v)) if np.isfinite(v).any() else None, float(np.nanmax(v)) if np.isfinite(v).any() else None]
        summary['%s|%s|%s' % (tag, prof, mode)] = d
    json.dump(summary, open(out + '/cells.json', 'w'), indent=1)
    # comparison table
    md = ['| Tag | Profile | Mode | n | Avg FPS (mean ± sd) | 1% low (p99) | 1% low (mean of worst 1%) | Mean ms | p99 ms | GPU ms | Prims vis (M) | Draws vis | Bias mean | Sat % | vs baseline FPS % | vs baseline ms % |', '|' + '---|' * 16]
    for (tag, prof, mode), rs in sorted(cells.items()):
        s = summary['%s|%s|%s' % (tag, prof, mode)]
        b = summary.get('%s|%s|baseline' % (tag, prof))
        def f(m, k=0, nd=1):
            v = s[m][k]
            return '-' if v is None else ('%.*f' % (nd, v))
        dfps = '' if (b is None or mode == 'baseline') else '%+.1f' % ((s['avg_fps'][0] - b['avg_fps'][0]) / b['avg_fps'][0] * 100)
        dms = '' if (b is None or mode == 'baseline') else '%+.1f' % ((s['ft_mean'][0] - b['ft_mean'][0]) / b['ft_mean'][0] * 100)
        md.append('| %s | %s | %s | %d | %s ± %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
            tag, prof, mode, s['n'], f('avg_fps'), f('avg_fps', 1), f('low1_p99'), f('low1_mean'), f('ft_mean', 0, 2), f('ft_p99'), f('gpu_mean', 0, 2),
            '-' if s['prims_vis'][0] is None else '%.2f' % (s['prims_vis'][0] / 1e6), f('draws_vis', 0, 0), f('bias_mean', 0, 2), f('sat_pct', 0, 0), dfps, dms))
    open(out + '/cells.md', 'w').write('\n'.join(md) + '\n')
    print('\n'.join(md))
    print()
    print('per-run: file mode avg med low1p99 low1mean minfps ft_mean p99 gpu prims_vis draws_vis sub10 sat% bias')
    for r in runs:
        print('%-30s %-8s %6.1f %6.1f %6.1f %6.1f %6.1f %6.2f %6.1f %6.2f %5.2fM %5.0f %3d %5s %5s' % (
            r['file'], r['mode'], r['avg_fps'], r['med_fps'], r['low1_p99'], r['low1_mean'], r['min_fps'], r['ft_mean'], r['ft_p99'], r['gpu_mean'],
            r['prims_vis'] / 1e6, r['draws_vis'], r['sub10'], '%.0f' % r['sat_pct'] if np.isfinite(r['sat_pct']) else '-', '%.2f' % r['bias_mean'] if np.isfinite(r['bias_mean']) else '-'))
    charts(runs, series, summary, out, tags)


def charts(runs, series, summary, out, tags):
    BG = '#1b1f27'; FG = '#e6e9ef'; MUT = '#9aa3b2'
    plt.rcParams.update({'text.color': FG, 'axes.labelcolor': FG, 'xtick.color': MUT, 'ytick.color': MUT})
    def style(ax):
        ax.set_facecolor(BG)
        for s in ax.spines.values(): s.set_color('#3a4150')
        ax.spines['top'].set_visible(False); ax.spines['right'].set_visible(False); ax.grid(axis='y', color='#2c3340'); ax.set_axisbelow(True)
    tag = tags[-1]
    profs = sorted({r['profile'] for r in runs if r['tag'] == tag})
    # 1+2: avg fps and frame time per profile, per-run dots
    for metric, ylabel, fname, better in [('avg_fps', 'Average FPS (higher is better)', 'chart_avg_fps.png', 'higher'), ('ft_mean', 'Mean frame time, ms (lower is better)', 'chart_frame_time.png', 'lower')]:
        fig, axs = plt.subplots(1, len(profs), figsize=(5.5 * len(profs), 4.2), facecolor=BG)
        axs = np.atleast_1d(axs)
        for ax, prof in zip(axs, profs):
            style(ax)
            present = [m for m in ['none', 'baseline', 'sched0', 'adaptive'] if any(r['tag'] == tag and r['profile'] == prof and r['mode'] == m for r in runs)]
            top = 0
            for i, mode in enumerate(present):
                rs = [r for r in runs if r['tag'] == tag and r['profile'] == prof and r['mode'] == mode]
                v = [r[metric] for r in rs]
                ax.bar(i, np.mean(v), color=COL[mode], width=.6, alpha=.9)
                ax.errorbar(i, np.mean(v), yerr=np.std(v, ddof=1) if len(v) > 1 else 0, color=FG, capsize=4, lw=1)
                ax.scatter([i] * len(v), v, color='#ffffff', s=14, zorder=3)
                hi = max(max(v), np.mean(v) + (np.std(v, ddof=1) if len(v) > 1 else 0)); top = max(top, hi)
                ax.text(i, hi * 1.03, '%.1f' % np.mean(v) if metric == 'avg_fps' else '%.2f' % np.mean(v), ha='center', fontsize=9, va='bottom')
            names = {'none': 'None', 'baseline': 'Baseline', 'sched0': 'Sched-only (bias 0)', 'adaptive': 'Adaptive'}
            ax.set_xticks(range(len(present))); ax.set_xticklabels([names[m] for m in present]); ax.set_ylim(0, top * 1.18)
            ax.set_title('%s (%s), n=%d per mode; bars = mean, whiskers = sd, dots = runs' % (prof, [r['res'] for r in runs if r['profile'] == prof][0], len([r for r in runs if r['tag'] == tag and r['profile'] == prof and r['mode'] == 'baseline'])), fontsize=8.5, loc='left', color=FG)
            ax.set_ylabel(ylabel)
        plt.tight_layout(); plt.savefig(out + '/' + fname, dpi=160, facecolor=BG); plt.close()
    # 3: FPS over time (1 s bins) per profile; baseline vs adaptive, all runs thin + mean thick
    fig, axs = plt.subplots(1, len(profs), figsize=(6.2 * len(profs), 4.2), facecolor=BG)
    axs = np.atleast_1d(axs)
    for ax, prof in zip(axs, profs):
        style(ax)
        for mode in ['baseline', 'adaptive']:
            curves = []
            for r in runs:
                if r['tag'] == tag and r['profile'] == prof and r['mode'] == mode:
                    t = series[r['file']][0]; n = int(t[-1])
                    c = np.array([((t >= i) & (t < i + 1)).sum() for i in range(n)], float)
                    ax.plot(c, color=COL[mode], alpha=.25, lw=.8); curves.append(c)
            if curves:
                m = min(len(c) for c in curves); ax.plot(np.mean([c[:m] for c in curves], axis=0), color=COL[mode] if mode == 'adaptive' else '#c5cad3', lw=2, label='%s mean of %d runs' % (mode, len(curves)))
        ax.set_title('%s: FPS over time (1 s bins)' % prof, color=FG, fontsize=10, loc='left'); ax.set_xlabel('time in measured run (s)'); ax.set_ylabel('FPS (higher is better)'); ax.set_ylim(bottom=0); ax.legend(facecolor=BG, edgecolor='#3a4150', labelcolor=FG, fontsize=8)
    plt.tight_layout(); plt.savefig(out + '/chart_fps_over_time.png', dpi=160, facecolor=BG); plt.close()
    # 4: bias vs GPU time for adaptive runs (first run of each profile), with target
    fig, axs = plt.subplots(1, len(profs), figsize=(6.2 * len(profs), 5.0), facecolor=BG)
    axs = np.atleast_1d(axs)
    for ax, prof in zip(axs, profs):
        style(ax)
        rs = [r for r in runs if r['tag'] == tag and r['profile'] == prof and r['mode'] == 'adaptive']
        if not rs: continue
        r = rs[0]; t, ft, gpu, bias, sig = series[r['file']]
        k = max(1, int(len(t) / 600))
        n = int(t[-1])
        gb = [np.nanmean(gpu[(t >= i) & (t < i + 1)]) for i in range(n)]
        sb = [np.nanmean(sig[(t >= i) & (t < i + 1)]) if np.isfinite(sig[(t >= i) & (t < i + 1)]).any() else np.nan for i in range(n)]
        bb = [np.nanmean(bias[(t >= i) & (t < i + 1)]) for i in range(n)]
        ax.plot(gb, color='#a78bfa', lw=1.2, label='GPU render time (1 s mean)')
        ax.plot(sb, color='#f5b14c', lw=1.2, label='smoothed controller signal')
        ax.axhline(r['target'], color='#ff6b6b', ls='--', lw=1, label='target %.2f ms' % r['target'])
        ax.set_ylabel('ms'); ax.set_xlabel('time (s)'); ax.set_ylim(bottom=0)
        ax2 = ax.twinx(); ax2.plot(bb, color='#35d0e8', lw=2, label='bias (right axis)'); ax2.set_ylim(0, 2.2); ax2.set_ylabel('global bias (0 = baseline)', color='#35d0e8'); ax2.tick_params(colors=MUT)
        for s in ax2.spines.values(): s.set_color('#3a4150')
        h1, l1 = ax.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels()
        ax.legend(h1 + h2, l1 + l2, facecolor=BG, edgecolor='#3a4150', labelcolor=FG, fontsize=7.5, loc='upper center', bbox_to_anchor=(0.5, -0.18), ncol=2)
        ax.set_title('%s adaptive run %s: bias vs GPU time' % (prof, r['file'].split('_')[-1]), color=FG, fontsize=10, loc='left')
    plt.tight_layout(); plt.savefig(out + '/chart_bias_vs_gpu.png', dpi=160, facecolor=BG); plt.close()


if __name__ == '__main__':
    main(sys.argv[1:])
