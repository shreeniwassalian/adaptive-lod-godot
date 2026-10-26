"""Builds <final_dir>/analysis_bench/deck_data.json for the final deck from the per-frame CSVs (no estimates).
Usage: python prep_final_deck.py <final_run_dir>"""
import sys, os, glob, json, csv
import numpy as np

FINAL = os.path.abspath(sys.argv[1]).replace('\\', '/') + '/'
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze  # noqa: E402


def runs_in(sub, pattern='*.json'):
    out = []
    for j in sorted(glob.glob(FINAL + sub + '/' + pattern)):
        r, s = analyze.load_run(j)
        out.append((r, s))
    return out


def second_bins(t, v, agg):
    n = int(t[-1])
    return [float(agg(v[(t >= i) & (t < i + 1)])) if ((t >= i) & (t < i + 1)).any() else None for i in range(n)]


data = {'cells': {}, 'series': {}, 'sub10': {}, 'per_run_sub10': []}
main = runs_in('bench')
for prof in ['normal', 'stress']:
    for mode in ['none', 'baseline', 'adaptive']:
        rs = [r for r, _ in main if r['profile'] == prof and r['mode'] == mode]
        c = {'n': len(rs)}
        for k in ['avg_fps', 'med_fps', 'low1_p99', 'low1_mean', 'ft_mean', 'ft_p95', 'ft_p99', 'gpu_mean', 'prims_vis', 'draws_vis', 'sat_pct', 'bias_mean', 'switches', 'policy_cpu', 'sub10', 'min_fps']:
            v = np.array([r[k] for r in rs], float)
            c[k] = {'mean': float(np.nanmean(v)) if np.isfinite(v).any() else None, 'sd': float(np.nanstd(v, ddof=1)) if np.isfinite(v).sum() > 1 else None,
                    'min': float(np.nanmin(v)) if np.isfinite(v).any() else None, 'max': float(np.nanmax(v)) if np.isfinite(v).any() else None}
        data['cells']['%s|%s' % (prof, mode)] = c
    for mode in ['none', 'baseline', 'adaptive']:
        fps_curves, bias_curves = [], []
        for r, (t, ft, gpu, bias, sig) in main:
            if r['profile'] == prof and r['mode'] == mode:
                fps_curves.append(second_bins(t, ft, lambda x: len(x)))
                if mode == 'adaptive':
                    bias_curves.append(second_bins(t, np.nan_to_num(bias), np.mean))
        m = min(len(c) for c in fps_curves)
        data['series']['%s|%s|fps' % (prof, mode)] = [float(np.mean([c[i] for c in fps_curves])) for i in range(m)]
        if bias_curves:
            m = min(len(c) for c in bias_curves)
            data['series']['%s|%s|bias' % (prof, mode)] = [float(np.mean([c[i] for c in bias_curves])) for i in range(m)]
for r, _ in main:
    data['per_run_sub10'].append({'file': r['file'], 'mode': r['mode'], 'sub10': r['sub10'], 'min_fps': r['min_fps'], 'hitch33': r['hitch33']})
data['total_main_runs'] = len(main)
data['sub10_frames_non_none'] = int(sum(r['sub10'] for r, _ in main if r['mode'] != 'none'))
data['sub10_frames_adaptive'] = int(sum(r['sub10'] for r, _ in main if r['mode'] == 'adaptive'))
data['max_ft_ms_adaptive'] = float(max(r['ft_max'] for r, _ in main if r['mode'] == 'adaptive'))
data['max_ft_ms_baseline'] = float(max(r['ft_max'] for r, _ in main if r['mode'] == 'baseline'))
data['env'] = {'adapter': main[0][0]['adapter'], 'driver': main[0][0]['driver'], 'build': main[0][0]['build'], 'editor': bool(main[0][0]['editor']), 'path_sha': main[0][0]['path_sha']}
supp = runs_in('bench_supplement') if os.path.isdir(FINAL + 'bench_supplement') else []
if supp:
    sc = {}
    for mode in ['baseline', 'adaptive']:
        rs = [r for r, _ in supp if r['mode'] == mode]
        if not rs: continue
        c = {'n': len(rs)}
        for k in ['avg_fps', 'med_fps', 'low1_p99', 'ft_mean', 'gpu_mean', 'prims_vis', 'sat_pct', 'bias_mean', 'sub10', 'min_fps']:
            v = np.array([r[k] for r in rs], float)
            c[k] = {'mean': float(np.nanmean(v)) if np.isfinite(v).any() else None, 'sd': float(np.nanstd(v, ddof=1)) if np.isfinite(v).sum() > 1 else None}
        c['runs_avg_fps'] = [float(r['avg_fps']) for r in rs]
        sc[mode] = c
    data['supplement_1080p_target8'] = sc
os.makedirs(FINAL + 'analysis_bench', exist_ok=True)
json.dump(data, open(FINAL + 'analysis_bench/deck_data.json', 'w'), indent=1)
print(json.dumps({k: data[k] for k in ['sub10_frames_non_none', 'sub10_frames_adaptive', 'max_ft_ms_adaptive', 'max_ft_ms_baseline', 'env']}, indent=1))
if supp:
    print(json.dumps(data['supplement_1080p_target8'], indent=1))
