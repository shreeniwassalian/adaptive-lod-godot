// Builds the None-vs-Adaptive deck (a NEW file; earlier decks are not touched) from measured data only. Baseline is not shown.
// Usage: node make_deck_final.js <final_run_dir_abs>   (needs analysis_bench/deck_data.json and presentation/img/* prepared first)
const pptxgen = require('S:/godot/adaptivelod/presentation/build/node_modules/pptxgenjs');
const fs = require('fs');
const FINAL = process.argv[2].replace(/\\/g, '/').replace(/\/$/, '') + '/';
const D = JSON.parse(fs.readFileSync(FINAL + 'analysis_bench/deck_data.json'));
const IMG = FINAL + 'presentation_na/img/';
const MEDIA = FINAL + 'media_na/';

const BG = '15181E', CARD = '1F242D', CARD2 = '262C37', TX = 'E6E9EF', MUT = '9AA3B2';
const CY = '35D0E8', VI = 'A78BFA', RD = 'FF6B6B', AM = 'F5B14C', GRY = '7B8494', LINE = '3A4150';
const HF = 'Cambria', BF = 'Calibri';

const c = (p, m) => D.cells[p + '|' + m];
const f1 = (v) => v.toFixed(1), f2 = (v) => v.toFixed(2);
const pct = (a, b) => (a - b) / b * 100;                 // FPS change: (adaptive - none) / none x 100
const red = (a, b) => (b - a) / b * 100;                 // reduction: (none - adaptive) / none x 100
const primRed = (c1, c0) => red(c1.prims_vis.mean, c0.prims_vis.mean);
const mult = (a, b) => (a / b).toFixed(1) + 'x';
const sgn = (v) => (v >= 0 ? '+' : '') + v.toFixed(1) + '%';
const N = c('normal', 'none'), S = c('stress', 'none');
const NA = c('normal', 'adaptive'), SA = c('stress', 'adaptive');
const nFps = pct(NA.avg_fps.mean, N.avg_fps.mean), sFps = pct(SA.avg_fps.mean, S.avg_fps.mean);
const nRed = red(NA.ft_mean.mean, N.ft_mean.mean), sRed = red(SA.ft_mean.mean, S.ft_mean.mean);
const reps = N.n;

const pres = new pptxgen();
pres.layout = 'LAYOUT_WIDE';
pres.author = 'Shreeniwas Salian';
pres.title = 'Adaptive Level of Detail for Real-Time Rendering in Godot';
pres.theme = { headFontFace: HF, bodyFontFace: BF };
pres.defineSlideMaster({
  title: 'CONTENT', background: { color: BG },
  objects: [{ text: { text: 'Adaptive LOD in Godot  |  Shreeniwas Salian', options: { x: 0.5, y: 7.1, w: 6, h: 0.25, fontFace: BF, fontSize: 10, color: GRY, margin: 0, isTextBox: true } } }],
  slideNumber: { x: 12.3, y: 7.1, w: 0.55, h: 0.25, fontFace: BF, fontSize: 10, color: GRY, align: 'right' },
});
pres.defineSlideMaster({ title: 'TITLE', background: { color: BG } });
const notes = {};
function base(title, kicker) {
  const s = pres.addSlide({ masterName: 'CONTENT' });
  s.addText(kicker, { x: 0.5, y: 0.28, w: 8, h: 0.28, fontFace: BF, fontSize: 12, bold: true, color: CY, margin: 0, isTextBox: true, charSpacing: 2 });
  s.addText(title, { x: 0.5, y: 0.55, w: 12.3, h: 0.6, fontFace: HF, fontSize: 30, bold: true, color: TX, margin: 0, isTextBox: true, fit: 'shrink' });
  return s;
}
function card(s, x, y, w, h, fill) { s.addShape(pres.shapes.RECTANGLE, { x, y, w, h, fill: { color: fill || CARD }, line: { color: LINE, width: 0.75 } }); }
const T = (s, text, o) => s.addText(text, Object.assign({ fontFace: BF, fontSize: 14, color: TX, margin: 0, isTextBox: true, valign: 'top' }, o));
const bul = (arr, o) => arr.map((t, i) => ({ text: t, options: Object.assign({ bullet: true, breakLine: i < arr.length - 1, paraSpaceAfter: 5 }, o || {}) }));
const chartBase = {
  catAxisLabelColor: MUT, valAxisLabelColor: MUT, catAxisLabelFontSize: 10, valAxisLabelFontSize: 10, catAxisLabelFontFace: BF, valAxisLabelFontFace: BF,
  valGridLine: { color: '2C3340', size: 0.5 }, catGridLine: { style: 'none' }, showLegend: true, legendPos: 'b', legendColor: TX, legendFontSize: 10, legendFontFace: BF,
  showTitle: true, titleColor: TX, titleFontSize: 12, titleFontFace: BF, showValAxisTitle: true, valAxisTitleColor: MUT, valAxisTitleFontSize: 10,
};

// ---------------- 1
{
  const s = pres.addSlide({ masterName: 'TITLE' });
  T(s, 'COMPUTER GRAPHICS  |  GAME ENGINE ENGINEERING', { x: 0.6, y: 0.7, w: 6, h: 0.3, fontSize: 12, bold: true, color: CY, charSpacing: 2 });
  T(s, 'Adaptive Level of Detail for Real-Time Rendering in Godot', { x: 0.6, y: 1.2, w: 5.9, h: 2.1, fontFace: HF, fontSize: 38, bold: true });
  T(s, 'A feedback-controlled, distance-based LOD for vegetation, compared against no LOD (full detail)', { x: 0.6, y: 3.45, w: 5.8, h: 0.9, fontSize: 16, color: MUT });
  T(s, 'Shreeniwas Salian', { x: 0.6, y: 4.5, w: 5.8, h: 0.4, fontSize: 20, bold: true });
  card(s, 0.6, 5.3, 5.8, 1.15);
  T(s, [{ text: 'Problem  ', options: { bold: true, color: CY } }, { text: 'Dense vegetation scenes cost frame time; fixed LOD distances cannot react when the GPU is over budget, so detail is either wasted or cut blindly.', options: {} }], { x: 0.8, y: 5.42, w: 5.4, h: 0.95, fontSize: 14 });
  s.addImage({ path: IMG + 'shot_adaptive.jpg', x: 6.9, y: 1.35, w: 5.9, h: 3.31, altText: 'Screenshot of the running Godot scene' });
  T(s, 'Real frame captured from the running project (Godot 4.7.2, Terrain3D 1.0.2, 1920x1080, Adaptive mode).', { x: 6.9, y: 4.75, w: 5.9, h: 0.5, fontSize: 11, color: MUT });
  [['41,698', 'vegetation instances'], ['528 m', 'deterministic camera path'], ['2 modes', 'none / adaptive']].forEach((k, i) => {
    T(s, k[0], { x: 6.9 + i * 2.0, y: 5.5, w: 1.9, h: 0.5, fontSize: 24, bold: true, color: i === 2 ? VI : CY }); T(s, k[1], { x: 6.9 + i * 2.0, y: 6.05, w: 1.9, h: 0.5, fontSize: 12, color: MUT });
  });
  notes[1] = 'The project asks one narrow question: when the renderer is over its frame budget, can a controller coarsen vegetation detail automatically, in a bounded and stable way, and does that buy frame time? The scene is a Terrain3D forest with about 42 thousand vegetation instances and a very dense grass field. I compare the scene with no LOD at all against the adaptive version on the same scene and camera path. The screenshot is a real captured frame. In short: adaptive LOD cuts frame time by roughly three quarters against full detail; most of that comes from distance LOD itself, and the controller adds only a little on top.';
  s.addNotes(notes[1]);
}

// ---------------- 2
{
  const s = base('Why LOD, and where fixed thresholds fall short', 'PROBLEM AND MOTIVATION');
  card(s, 0.5, 1.35, 6.3, 3.55);
  s.addImage({ path: 'S:/godot/adaptivelod/presentation/charts/diagram_lod_levels_schematic.png', x: 0.7, y: 1.45, w: 5.9, h: 1.97 });
  T(s, 'Schematic only: polygon count falls as distance grows (not the project meshes).', { x: 0.7, y: 3.42, w: 5.9, h: 0.25, fontSize: 10, color: MUT });
  [['LOD0', '0 to 60 m', CY], ['LOD1', '60 to 150 m', VI], ['LOD2', 'beyond 150 m', GRY]].forEach((b, i) => {
    s.addShape(pres.shapes.RECTANGLE, { x: 0.7 + i * 1.97, y: 3.8, w: 1.87, h: 0.65, fill: { color: CARD2 }, line: { color: b[2], width: 1 } });
    T(s, [{ text: b[0], options: { bold: true, color: b[2], breakLine: true } }, { text: b[1], options: { color: TX } }], { x: 0.7 + i * 1.97, y: 3.84, w: 1.87, h: 0.6, fontSize: 12, align: 'center' });
  });
  T(s, 'Starting tree thresholds from the code (60 m / 150 m, 10 m hysteresis); the bias scales them.', { x: 0.7, y: 4.5, w: 5.9, h: 0.25, fontSize: 10, color: MUT });
  T(s, 'General LOD concepts', { x: 0.5, y: 5.1, w: 6.3, h: 0.3, fontSize: 18, bold: true, color: CY });
  T(s, bul(['Cost scales with triangles, draw calls and overdraw', 'Distant objects need fewer triangles for the same look', 'Fixed distances ignore the actual frame budget']), { x: 0.5, y: 5.45, w: 6.3, h: 1.5, fontSize: 14 });
  card(s, 7.1, 1.35, 5.7, 5.55);
  T(s, 'Implemented in this project', { x: 7.35, y: 1.5, w: 5.2, h: 0.35, fontSize: 18, bold: true, color: VI });
  T(s, bul(['Distance LOD for 4 categories: trees (3 mesh levels), grass (3 tiers + cull), bushes and debris (density thinning)', 'Adaptive: one PI-controlled bias scales those thresholds from measured GPU render time', 'Hysteresis, rate limits and a per-update change budget limit popping', 'Same scene, seed and camera path for None and Adaptive'], { paraSpaceAfter: 8 }), { x: 7.35, y: 1.95, w: 5.25, h: 3.0, fontSize: 14 });
  T(s, 'Not implemented', { x: 7.35, y: 5.0, w: 5.2, h: 0.35, fontSize: 18, bold: true, color: AM });
  T(s, bul(['Per-instance or screen-size importance', 'Cross-fade or dither between mesh levels (trees still pop)', 'Mesh LOD for bushes (density only)'], { paraSpaceAfter: 3 }), { x: 7.35, y: 5.4, w: 5.25, h: 1.4, fontSize: 14 });
  notes[2] = 'Rendering cost grows with triangles, draw calls and overdraw, and LOD trades detail for cost by switching to simpler representations with distance. The weakness of fixed distances is that they ignore the frame budget. The left side is general concept; the schematic is illustrative, not my meshes. The right side is what I built: distance LOD for trees, grass, bushes and debris, with thresholds scaled by one feedback-controlled bias in adaptive mode; the comparison is against None, where everything is drawn at full detail. Not implemented: per-instance importance, cross-fading, and mesh LOD for bushes.';
  s.addNotes(notes[2]);
}

// ---------------- 3
{
  const s = base('Architecture: one controller bias scales fixed metre thresholds', 'SYSTEM ARCHITECTURE');
  function box(x, y, w, h, title, sub, color) {
    s.addShape(pres.shapes.RECTANGLE, { x, y, w, h, fill: { color: CARD2 }, line: { color: color, width: 1.25 } });
    T(s, [{ text: title, options: { bold: true, color: TX, breakLine: true, fontSize: 12 } }, { text: sub, options: { color: MUT, fontSize: 10.5 } }], { x: x + 0.08, y: y + 0.06, w: w - 0.16, h: h - 0.1, align: 'center', valign: 'middle', fontSize: 12 });
  }
  function arrow(x1, y1, x2, y2, color) {
    s.addShape(pres.shapes.LINE, { x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.abs(x2 - x1), h: Math.abs(y2 - y1), flipH: x2 < x1, flipV: y2 < y1, line: { color: color || MUT, width: 1.5, endArrowType: 'triangle' } });
  }
  T(s, 'ADAPTIVE MODE ONLY  (adaptive_lod.gd, pi_controller.gd)', { x: 0.55, y: 1.3, w: 8, h: 0.25, fontSize: 11, bold: true, color: VI });
  const A = [['GPU render time', 'viewport measured time, VSync off'], ['Smoothing', 'EMA 0.5 s, spike clip 3x target'], ['PI controller', 'target 16.67 ms (8 ms stress), deadband 3%'], ['Rate limits', '+0.10 up / -0.03 down per 0.25 s'], ['Global bias 0..2', 'then per-category onset, gain, cap']];
  const aw = 2.2, ag = 0.3;
  A.forEach((a, i) => { box(0.55 + i * (aw + ag), 1.6, aw, 0.9, a[0], a[1], VI); if (i < 4) arrow(0.55 + i * (aw + ag) + aw, 2.05, 0.55 + (i + 1) * (aw + ag), 2.05, VI); });
  T(s, 'SHARED PIPELINE  (lod_manager.gd, lod_policy.gd; all off in None)', { x: 0.55, y: 2.9, w: 10, h: 0.25, fontSize: 11, bold: true, color: CY });
  const B = [['Scene + camera path', '528 m, 8 m/s, seed 1337'], ['Camera distance', 'metres, per chunk / cell / tree'], ['LOD policy', 'start thresholds at bias 0\nadaptive: distance x (1+bias)'], ['Detail update', 'MultiMesh tier / count, hysteresis, change budget'], ['Rendered frame', 'MetricsSampler: frame, GPU, draws'], ['CSV + JSON', 'benchmark_summary: avg, p50, p95, p99']];
  const bw = 1.85, bg = 0.226;
  B.forEach((b, i) => { box(0.55 + i * (bw + bg), 3.2, bw, 1.0, b[0], b[1], CY); if (i < 5) arrow(0.55 + i * (bw + bg) + bw, 3.7, 0.55 + (i + 1) * (bw + bg), 3.7, CY); });
  const px = 0.55 + 2 * (bw + bg) + bw / 2, ax = 0.55 + 4 * (aw + ag) + aw / 2;
  s.addShape(pres.shapes.LINE, { x: ax, y: 2.5, w: 0, h: 0.2, line: { color: VI, width: 1.5 } });
  s.addShape(pres.shapes.LINE, { x: px, y: 2.7, w: ax - px, h: 0, line: { color: VI, width: 1.5 } });
  arrow(px, 2.7, px, 3.2, VI);
  T(s, 'bias', { x: px + 0.1, y: 2.72, w: 0.6, h: 0.22, fontSize: 10, color: VI, bold: true });
  card(s, 0.55, 4.45, 3.95, 2.5);
  T(s, 'Thresholds in metres', { x: 0.7, y: 4.52, w: 3.7, h: 0.3, fontSize: 15, bold: true, color: CY });
  T(s, bul(['Trees: effective = max(floor, base / (1 + bias)), never above base', 'Hysteresis added in metres (10 m)', 'Bias 0 gives the starting thresholds, so one code path serves every bias'], { paraSpaceAfter: 3 }), { x: 0.7, y: 4.85, w: 3.7, h: 2.05, fontSize: 12 });
  card(s, 4.65, 4.45, 3.95, 2.5);
  T(s, 'Bounded coarsening', { x: 4.8, y: 4.52, w: 3.7, h: 0.3, fontSize: 15, bold: true, color: CY });
  T(s, bul(['Tree floors: LOD1 never before 60 m, LOD2 never before 100 m', 'Per-category caps: grass 1.0, trees 1.0, bushes 0.5, debris 0.5', 'bias_min 0: never finer than baseline. bias_max 2.0'], { paraSpaceAfter: 3 }), { x: 4.8, y: 4.85, w: 3.7, h: 2.05, fontSize: 12 });
  s.addShape(pres.shapes.RECTANGLE, { x: 8.75, y: 4.45, w: 4.05, h: 2.5, fill: { color: '0E1116' }, line: { color: LINE, width: 0.75 } });
  T(s, 'baseline_lod.gd: _rebuild_thresholds()', { x: 8.88, y: 4.5, w: 3.8, h: 0.22, fontSize: 10, color: MUT });
  T(s, 'for i in 2:\n  var effective: float = base[i] / _dist_scale\n  if _dist_scale > 1.0:  # coarser\n    effective = minf(base[i],\n      maxf(effective, floors[i]))\n  _thresholds[i] = effective', { x: 8.88, y: 4.8, w: 3.85, h: 2.05, fontFace: 'Courier New', fontSize: 11, color: CY });
  notes[3] = 'Two halves. Along the top is the adaptive part, which only runs in adaptive mode: the GPU render time of the main viewport is smoothed, compared with a target, and a PI controller with rate limits produces one global bias between 0 and 2, mapped to a per-category bias. Along the bottom is the shared pipeline, switched off entirely in None: for each tree, grass cell or chunk the policy compares camera distance in metres with thresholds, with hysteresis, and updates MultiMesh tiers under a change budget. With the bias at zero the thresholds are the starting distances, i.e. the adaptive system with the controller idle. The snippet is the real threshold code: baseline divided by one plus bias, clamped by a floor in metres. The constraint is expressed as distance floors and per-category caps, not literally as a two-level limit.';
  s.addNotes(notes[3]);
}

// ---------------- 4
{
  const s = base('Technical contributions, and what the evidence supports', 'NOVELTY');
  const rows = [
    ['1  Adaptive thresholds', 'Draws everything at full detail', 'One PI-controlled bias scales all thresholds from GPU time', 'Reacts to load instead of ignoring it', 'Live recording: bias rises from 0 to its 2.0 maximum while the panel shows the tree threshold move. Bias saturated in ' + f1(SA.sat_pct.mean) + '% of 1440p frames', 'Implemented', CY],
    ['2  Real-world units', 'No distance logic', 'Floors, caps and hysteresis in metres; coarser = distance x (1+bias)', 'Effect is predictable and tunable in scene units', 'Panel shows thresholds in m. Self-tests: 124 + 90 + 51 + 17 checks pass (grass determinism stage not run)', 'Implemented', CY],
    ['3  Constrained coarsening', 'No notion of a limit', 'Tree floors 60 / 100 m, category caps, bias range 0..2', 'Keeps nearby detail intact', 'At high bias the panel shows 60 / 100 m: LOD2 stops at the floor. Not literally a 2-level limit', 'Partly as stated', AM],
    ['4  Unified benchmark', 'n/a', 'Same scene, seed, path (sha256 logged), interleaved runs, CSV + JSON', 'Fair, repeatable comparison', D.total_main_runs + ' runs, ' + reps + ' per mode and resolution. Earlier sessions showed 2 to 3x GPU-state drift', 'Implemented', CY],
    ['5  Quality / speed trade-off', 'Full detail', 'Measures primitives, draws, GPU ms and visual difference', 'Shows what a saving costs', 'vs None: ' + f1(red(NA.ft_mean.mean, N.ft_mean.mean)) + '% (1080p) and ' + f1(sRed) + '% (1440p) lower frame time, ' + Math.round(primRed(NA, N)) + '% fewer primitives. No perceptual metric', 'Partly demonstrated', AM],
  ];
  const hdr = ['Contribution', 'None (no LOD) does', 'Adaptive changes', 'Why it matters', 'Evidence'];
  const cw = [2.0, 1.9, 2.9, 1.9, 3.6];
  const tr = [hdr.map(h => ({ text: h, options: { bold: true, color: BG, fill: { color: CY }, fontSize: 11, fontFace: BF } }))];
  rows.forEach(r => tr.push(r.slice(0, 5).map((cc, j) => ({ text: cc, options: { color: j === 0 ? TX : 'DDE1E8', bold: j === 0, fontSize: 11, fontFace: BF, fill: { color: CARD } } }))));
  s.addTable(tr, { x: 0.5, y: 1.35, w: 12.3, colW: cw, border: { type: 'solid', pt: 0.75, color: LINE }, valign: 'middle', rowH: [0.35, 0.9, 0.85, 0.9, 0.85, 0.85], margin: [0.04, 0.08, 0.04, 0.08] });
  card(s, 0.5, 6.35, 12.3, 0.62, CARD2);
  T(s, [{ text: 'Scope of the claim:  ', options: { bold: true, color: VI } }, { text: 'these are this project\'s technical contributions. A limited literature check (slide 8) found no directly comparable controller-plus-vegetation result, but it was not a systematic review, so no global novelty is claimed.', options: {} }], { x: 0.65, y: 6.4, w: 12.0, h: 0.52, fontSize: 12, valign: 'middle' });
  notes[4] = 'Five contributions with statuses I can defend. One: thresholds driven by a controller instead of fixed; the recording shows the bias rising from zero to its maximum of 2.0 (the GPU was in a slow state that session) while the on-screen tree threshold moves. Two: everything in metres. Three: constrained coarsening, and here I am exact: it is distance floors for trees plus per-category caps, and the panel shows the LOD2 threshold stopping at 100 metres. That is not literally a two-level limit. Four: the benchmark harness, with the same path hash, interleaved runs and full CSV and JSON output. Five: the trade-off, where I have exact primitive counts and measured frame-time reductions against full detail but no perceptual metric. No claim of global novelty: the literature check on slide 8 was limited.';
  s.addNotes(notes[4]);
}

// ---------------- 5
{
  const s = base('Experimental setup and fairness of the comparison', 'METHODOLOGY');
  const H = (t) => ({ text: t, options: { bold: true, color: BG, fill: { color: CY }, fontSize: 11 } });
  const cc = (t, o) => ({ text: t, options: Object.assign({ color: TX, fill: { color: CARD }, fontSize: 11 }, o || {}) });
  const l = (t) => cc(t, { color: MUT });
  const rows = [
    [H('Condition'), H('None (no LOD)'), H('Adaptive')],
    [l('Build'), cc('Godot 4.7.2-stable DEBUG + EDITOR build (release export blocked: no export_presets.cfg and no export templates installed)'), cc('same binary')],
    [l('Hardware'), cc(D.env.adapter + ', driver 582.16; Intel i7-8850H, 64 GB; Windows, Balanced power plan'), cc('same machine')],
    [l('Renderer'), cc('Forward+ / D3D12, no MSAA / TAA, VSync off, FPS uncapped'), cc('same')],
    [l('Resolution'), cc('Normal 1920x1080  |  Stress 2560x1440'), cc('same')],
    [l('Scene'), cc('Terrain3D 1.0.2, 41,698 instances + 403k grass clumps, seed 1337'), cc('same')],
    [l('Camera'), cc('528 m path (sha256 ' + D.env.path_sha + '), 8 m/s, 10 s warm-up, 60 s measured'), cc('same; controller reset to bias 0 at start')],
    [l('LOD'), cc('All LOD policies off: baked full-detail vegetation'), cc('Distance thresholds x PI bias; target 16.67 ms (normal), 8 ms (stress)')],
    [l('Runs'), cc(reps + ' per mode and resolution, order rotated each repetition'), cc(reps + ' per resolution')],
    [l('Metrics'), cc('Per-frame frame time, GPU ms, draws, primitives, switches, policy CPU ms'), cc('+ bias and controller terms')],
  ];
  s.addTable(rows, { x: 0.5, y: 1.35, w: 7.9, colW: [1.2, 3.9, 2.8], border: { type: 'solid', pt: 0.75, color: LINE }, fontFace: BF, valign: 'middle', rowH: [0.32, 0.62, 0.5, 0.42, 0.4, 0.42, 0.5, 0.55, 0.5, 0.5], margin: [0.03, 0.08, 0.03, 0.08] });
  card(s, 8.65, 1.35, 4.15, 2.85);
  T(s, 'Fairness risks', { x: 8.8, y: 1.43, w: 3.9, h: 0.3, fontSize: 16, bold: true, color: AM });
  T(s, bul(['GPU state drifted 2 to 3x between earlier sessions; this series stayed stable (sd of avg FPS 0.1 to 0.3)', 'Debug + editor build inflates CPU timings', 'Targets differ by profile, by design'], { paraSpaceAfter: 3 }), { x: 8.8, y: 1.78, w: 3.95, h: 2.4, fontSize: 11.5 });
  card(s, 8.65, 4.35, 4.15, 2.6);
  T(s, 'Not available', { x: 8.8, y: 4.43, w: 3.9, h: 0.3, fontSize: 16, bold: true, color: RD });
  T(s, bul(['Release / exported build results', 'Control of GPU power state', 'Grass determinism self-test stage (skipped by default)', 'Recording ran with FFmpeg capture on: demo FPS is not benchmark data'], { paraSpaceAfter: 3 }), { x: 8.8, y: 4.78, w: 3.95, h: 2.1, fontSize: 11.5 });
  notes[5] = 'All numbers come from the project benchmark harness: Godot 4.7.2 in a debug and editor build, because no export templates are installed, so a release build was not possible. Quadro P3200 laptop GPU, Forward+ on D3D12, VSync off, uncapped. A fixed 528 metre camera path at 8 metres per second, 10 seconds of warm-up and 60 seconds measured. Five runs per mode and resolution with the order rotated each repetition. Both modes see the same scene, seed and path hash; None simply has every LOD policy disabled. Fairness risks: earlier sessions showed the GPU changing speed by two to three times between runs, this series was stable; the build is debug; and the targets differ by profile. The screen recording is a demonstration, not benchmark data.';
  s.addNotes(notes[5]);
}

// ---------------- 6
const NB = c('normal', 'baseline'), SB = c('stress', 'baseline');
const ctrlN = pct(NA.avg_fps.mean, NB.avg_fps.mean), ctrlS = pct(SA.avg_fps.mean, SB.avg_fps.mean);  // controller's own contribution over fixed thresholds
const gpuRedN = red(NA.gpu_mean.mean, N.gpu_mean.mean), gpuRedS = red(SA.gpu_mean.mean, S.gpu_mean.mean);
const noSub10 = (D.per_run_sub10.filter(r => r.mode !== 'baseline').reduce((a, r) => a + r.sub10, 0));
{
  const s = base('Results: ' + mult(NA.avg_fps.mean, N.avg_fps.mean) + ' the FPS at 1080p and ' + mult(SA.avg_fps.mean, S.avg_fps.mean) + ' at 1440p versus no LOD', 'BENCHMARK ANALYSIS');
  s.addChart(pres.charts.BAR, [
    { name: 'None (n=' + reps + ')', labels: ['1920x1080', '2560x1440'], values: [+f1(N.avg_fps.mean), +f1(S.avg_fps.mean)] },
    { name: 'Adaptive (n=' + reps + ')', labels: ['1920x1080', '2560x1440'], values: [+f1(NA.avg_fps.mean), +f1(SA.avg_fps.mean)] },
  ], Object.assign({}, chartBase, { x: 0.5, y: 1.3, w: 4.0, h: 3.0, barDir: 'col', barGrouping: 'clustered', chartColors: [GRY, CY], showValue: true, dataLabelColor: TX, dataLabelFontSize: 10, dataLabelFontFace: BF, dataLabelPosition: 'outEnd', dataLabelFormatCode: '0.0',
    valAxisMinVal: 0, valAxisMaxVal: 120, valAxisTitle: 'Average FPS (higher is better)', title: 'Average FPS, mean of ' + reps + ' runs' }));
  const fb = D.series['stress|none|fps'], fa = D.series['stress|adaptive|fps'];
  const len = Math.min(fb.length, fa.length);
  const labs = Array.from({ length: len }, (_, i) => String(i));
  s.addChart(pres.charts.LINE, [
    { name: 'None', labels: labs, values: fb.slice(0, len).map(v => +v.toFixed(1)) },
    { name: 'Adaptive', labels: labs, values: fa.slice(0, len).map(v => +v.toFixed(1)) },
  ], Object.assign({}, chartBase, { x: 4.67, y: 1.3, w: 4.0, h: 3.0, chartColors: [GRY, CY], lineSize: 2, lineDataSymbol: 'none', catAxisLabelFrequency: 10, valAxisMinVal: 0, valAxisMaxVal: 100, valAxisTitle: 'FPS per 1 s bin', catAxisTitle: 'time (s)', showCatAxisTitle: true, catAxisTitleColor: MUT, catAxisTitleFontSize: 10, title: '1440p: FPS over time (mean of ' + reps + ')' }));
  const bn = D.series['normal|adaptive|bias'], bs = D.series['stress|adaptive|bias'];
  const bl = Math.min(bn.length, bs.length);
  s.addChart(pres.charts.LINE, [
    { name: '1080p (target 16.67 ms)', labels: Array.from({ length: bl }, (_, i) => String(i)), values: bn.slice(0, bl).map(v => +v.toFixed(2)) },
    { name: '1440p (target 8 ms)', labels: Array.from({ length: bl }, (_, i) => String(i)), values: bs.slice(0, bl).map(v => +v.toFixed(2)) },
  ], Object.assign({}, chartBase, { x: 8.84, y: 1.3, w: 4.0, h: 3.0, chartColors: [VI, CY], lineSize: 2, lineDataSymbol: 'none', catAxisLabelFrequency: 10, valAxisMinVal: 0, valAxisMaxVal: 2, valAxisTitle: 'Controller bias (0 = start thresholds)', catAxisTitle: 'time (s)', showCatAxisTitle: true, catAxisTitleColor: MUT, catAxisTitleFontSize: 10, title: 'Adaptive bias over time (mean of ' + reps + ')' }));
  const H = (t) => ({ text: t, options: { bold: true, color: BG, fill: { color: CY }, fontSize: 10.5, align: 'center' } });
  const cc = (t, o) => ({ text: t, options: Object.assign({ color: TX, fill: { color: CARD }, fontSize: 10.5, align: 'center' }, o || {}) });
  const row = (res, mode, cell, b) => [cc(res, { align: 'left', color: MUT }), cc(mode), cc(f1(cell.avg_fps.mean) + ' ± ' + f1(cell.avg_fps.sd)), cc(f1(cell.low1_p99.mean)), cc(f2(cell.ft_mean.mean)), cc(f1(cell.gpu_mean.mean)),
    cc(mode === 'None' ? '-' : sgn(pct(cell.avg_fps.mean, b.avg_fps.mean)), { bold: true, color: mode === 'None' ? MUT : CY }), cc(mode === 'None' ? '-' : sgn(-red(cell.ft_mean.mean, b.ft_mean.mean)), { bold: true, color: mode === 'None' ? MUT : CY })];
  s.addTable([
    [H('Resolution'), H('Mode'), H('Avg FPS ± sd'), H('1% low FPS'), H('Frame ms'), H('GPU ms'), H('FPS change'), H('Frame-time change')],
    row('1920x1080', 'None', N, N), row('1920x1080', 'Adaptive', NA, N), row('2560x1440', 'None', S, S), row('2560x1440', 'Adaptive', SA, S),
  ], { x: 0.5, y: 4.45, w: 8.2, colW: [1.1, 0.9, 1.35, 0.95, 0.9, 0.8, 1.0, 1.2], border: { type: 'solid', pt: 0.75, color: LINE }, fontFace: BF, valign: 'middle', rowH: [0.42, 0.3, 0.3, 0.3, 0.3], margin: [0.02, 0.05, 0.02, 0.05] });
  T(s, 'Change = (Adaptive - None) / None x 100; 1% low = 1000 / p99 frame time. Debug/editor build. How much is the controller? Measured separately against the fixed-threshold LOD (not shown here): ' + sgn(ctrlN) + ' avg FPS at 1080p, ' + sgn(ctrlS) + ' at 1440p, so nearly all of the gain above comes from distance LOD itself.', { x: 0.5, y: 6.15, w: 8.2, h: 0.85, fontSize: 10, color: MUT });
  card(s, 8.9, 4.45, 3.9, 2.55);
  T(s, 'Reading the result', { x: 9.05, y: 4.5, w: 3.6, h: 0.3, fontSize: 15, bold: true, color: AM });
  T(s, bul([
    'GPU time ' + f1(N.gpu_mean.mean) + ' to ' + f1(NA.gpu_mean.mean) + ' ms (1080p) and ' + f1(S.gpu_mean.mean) + ' to ' + f1(SA.gpu_mean.mean) + ' ms (1440p); primitives ' + (N.prims_vis.mean / 1e6).toFixed(1) + ' M to ' + (NA.prims_vis.mean / 1e6).toFixed(2) + ' M, draw calls ' + Math.round(N.draws_vis.mean) + ' to ' + Math.round(NA.draws_vis.mean),
    '1080p: GPU is under the 16.67 ms target, bias stays 0. 1440p: bias saturates in ' + Math.round(SA.sat_pct.mean) + '% of frames and the 8 ms target is not reached',
    noSub10 + ' frames under 10 FPS in the ' + (D.total_main_runs - 10) + ' None/Adaptive runs; lowest per-run FPS ' + Math.min.apply(null, D.per_run_sub10.filter(r => r.mode !== 'baseline').map(r => r.min_fps)).toFixed(1),
  ], { paraSpaceAfter: 3 }), { x: 9.05, y: 4.82, w: 3.65, h: 2.15, fontSize: 10.5 });
  notes[6] = 'Final series: ' + reps + ' runs per mode and resolution, debug build, stable GPU state. At 1080p the average goes from ' + f1(N.avg_fps.mean) + ' FPS with no LOD to ' + f1(NA.avg_fps.mean) + ' with adaptive LOD, ' + mult(NA.avg_fps.mean, N.avg_fps.mean) + ' as many; mean frame time falls from ' + f1(N.ft_mean.mean) + ' to ' + f1(NA.ft_mean.mean) + ' ms. At 1440p it goes from ' + f1(S.avg_fps.mean) + ' to ' + f1(SA.avg_fps.mean) + ' FPS, ' + mult(SA.avg_fps.mean, S.avg_fps.mean) + '. The cause is mainly the amount of geometry: rendered primitives fall by about ' + Math.round(primRed(NA, N)) + ' percent and draw calls from about ' + Math.round(N.draws_vis.mean) + ' to ' + Math.round(NA.draws_vis.mean) + '. An honest reading: almost all of this comes from having distance LOD at all. Compared with the fixed-threshold version, which is not shown on this slide, the PI controller adds ' + sgn(ctrlN) + ' at 1080p, where it stays idle because the GPU is under its target, and ' + sgn(ctrlS) + ' at 1440p, where it saturates. So the controller is a safety mechanism that engages when the frame is over budget, not the main source of speed. ' + noSub10 + ' frames fell below 10 FPS in any of these runs. All numbers are from a debug and editor build.';
  s.addNotes(notes[6]);
}

// ---------------- 7
{
  const s = base('Visual comparison and live demonstration', 'VISUAL QUALITY');
  const iw = 4.3, ih = 2.42;
  [['None (no LOD)', 'shot_none.jpg', 0.5, 1.25], ['Adaptive (live controller, bias 1.4)', 'shot_adaptive.jpg', 4.95, 1.25]].forEach(p => {
    s.addImage({ path: IMG + p[1], x: p[2], y: p[3], w: iw, h: ih, altText: p[0] });
    T(s, p[0], { x: p[2], y: p[3] + ih + 0.03, w: iw, h: 0.22, fontSize: 10.5, color: MUT });
  });
  s.addMedia({ type: 'video', path: MEDIA + 'none_vs_adaptive_demo_720p.mp4', cover: 'data:image/jpeg;base64,' + fs.readFileSync(IMG + 'video_cover.jpg').toString('base64'), x: 0.5, y: 3.95, w: iw, h: ih });
  T(s, 'Screen recording (70 s): None and Adaptive, F4 toggles', { x: 0.5, y: 3.95 + ih + 0.03, w: iw, h: 0.25, fontSize: 10.5, color: MUT });
  s.addImage({ path: IMG + 'panel_ui.jpg', x: 4.95, y: 3.95, w: ih * 970 / 590, h: ih, altText: 'In-game debug panel in Adaptive mode, None and Adaptive buttons only' });
  T(s, 'Real panel (F3): only None and Adaptive buttons', { x: 4.95, y: 3.95 + ih + 0.03, w: iw, h: 0.25, fontSize: 10.5, color: MUT });
  s.addImage({ path: IMG + 'closeup_pair_na.jpg', x: 9.45, y: 1.25, w: 3.35, h: 3.35 * 1090 / 960, altText: 'None versus adaptive vegetation close-up' });
  T(s, '2x crop, same region: None (top), Adaptive (bottom)', { x: 9.45, y: 1.25 + 3.35 * 1090 / 960 + 0.03, w: 3.35, h: 0.25, fontSize: 10.5, color: MUT });
  T(s, 'Stills: earlier session (GPU about 9.5 ms, bias 1.4). Video and panel: new recording after the Baseline button was removed; the GPU was slower (about 21 ms) so the bias hit its maximum of 2.0. Capture was running, so recording FPS is not benchmark data. Grass wind differs between frames; tree swaps still pop (no cross-fade).', { x: 0.5, y: 6.7, w: 12.3, h: 0.38, fontSize: 9.5, color: MUT });
  notes[7] = 'All images are real captures from the project. The video is a genuine screen recording of the running scene, made after I removed the Baseline button, so the panel offers only None and Adaptive and F4 toggles between them. At the same viewpoint, None draws all 403 thousand grass clumps and every tree at full detail; with adaptive on, the controller raises its bias to the maximum and the panel shows the grass drawn count falling to a few thousand and the tree LOD2 threshold moving from 150 to 100 metres, where its floor stops it. The still images come from the earlier session where the GPU was faster and the bias reached about 1.4. The visual change is mid-field grass thinning; nearby trees are identical. The recording runs with screen capture on, so its FPS is not benchmark data.';
  s.addNotes(notes[7]);
}

// ---------------- 8
{
  const s = base('How our results compare with recent research (2020 and later)', 'RELATED WORK');
  const H = (t) => ({ text: t, options: { bold: true, color: BG, fill: { color: CY }, fontSize: 10.5 } });
  const cc = (t, o) => ({ text: t, options: Object.assign({ color: TX, fill: { color: CARD }, fontSize: 10 }, o || {}) });
  const l = (t) => cc(t, { bold: true });
  const rows = [
    [H('Work (year, venue)'), H('Technique'), H('Hardware and scene'), H('Reported result'), H('Relation to this project')],
    [l('Adaptive LOD / progressive-mesh control for stable real-time VR rendering (2026, The Visual Computer, DOI 10.1007/s00371-026-04784-5)'), cc('Frame-budget-driven adaptive LOD via progressive meshes'), cc('VR interior-design scenes, 11.11 ms budget (90 Hz)'), cc('High load: p95 GPU frame time 18.11 to 10.86 ms (-40%); frames over budget 84.51% to 7.01%, vs full-resolution rendering'), cc('Closest in idea (budget-driven LOD vs full detail). Ours: p99 frame time ' + f1(N.ft_p99.mean) + ' to ' + f1(NA.ft_p99.mean) + ' ms (' + sgn(-red(NA.ft_p99.mean, N.ft_p99.mean)) + ') at 1080p, ' + f1(S.ft_p99.mean) + ' to ' + f1(SA.ft_p99.mean) + ' ms (' + sgn(-red(SA.ft_p99.mean, S.ft_p99.mean)) + ') at 1440p')],
    [l('Real-Time GPU Tree Generation (2025, High-Performance Graphics, DOI 10.2312/hpg.20251168; AMD)'), cc('Procedural trees via DX12 work graphs and mesh nodes, continuous per-frame LOD'), cc('Radeon RX 7900 XTX, 1,200 trees of 20 types plus grass and effects'), cc('Median frame 7.74 ms for the whole scene (trees 3.13 ms to G-buffer); 51 KiB of data instead of 34.8 GiB of meshes'), cc('Different goal (memory and generation); shows trees at LOD fit in single-digit ms on far newer hardware. Ours: ' + f1(NA.ft_mean.mean) + ' ms (1080p) on a Quadro P3200 laptop GPU')],
    [l('Real-time Path Tracing of Massive Dynamic Foliage (ACM, DOI 10.1145/3820021)'), cc('Clustered LOD generation plus opacity micromaps for ray tracing'), cc('RTX 4090, animated foliage, 1440p upscaled to 2160p'), cc('About 60 FPS (no baseline comparison extracted)'), cc('Different pipeline (path tracing). Confirms LOD clustering for foliage remains an active research area; ours is raster, distance-based')],
    [l('Automatic LOD for Improved Rendering by CPU Usage (2024, RSU Int. Research Conf.)'), cc('Adaptive LOD updates, spatial hashing, CPU/GPU analysis for consistent FPS'), cc('Two test areas (Area 1, Area 2); hardware not stated'), cc('CPU time 15.1 to 14.2 ms (-5.96%) and 10.8 to 10.3 ms (-4.63%); triangles -15.79% and -25%; FPS 66.1 to 90 (+36.2%) and 121 to 146 (+20.7%)'), cc('Closest in aim. Like-for-like with our Baseline to Adaptive step (' + sgn(ctrlN) + ' / ' + sgn(ctrlS) + ' FPS, primitives ' + sgn(-primRed(NA, NB)) + ' / ' + sgn(-primRed(SA, SB)) + '): theirs is larger, CPU-driven; ours GPU-driven, GPU-bound scene')],
    [{ text: 'This project (2026)', options: { bold: true, color: CY, fill: { color: CARD2 }, fontSize: 10 } }, cc('PI-controlled bias on distance thresholds, 4 vegetation categories', { fill: { color: CARD2 } }), cc('Quadro P3200, Godot 4.7.2 debug build, 41,698 instances + 403k grass clumps', { fill: { color: CARD2 } }), cc(f1(N.avg_fps.mean) + ' to ' + f1(NA.avg_fps.mean) + ' FPS (1080p), ' + f1(S.avg_fps.mean) + ' to ' + f1(SA.avg_fps.mean) + ' FPS (1440p); GPU ' + f1(N.gpu_mean.mean) + ' to ' + f1(NA.gpu_mean.mean) + ' ms and ' + f1(S.gpu_mean.mean) + ' to ' + f1(SA.gpu_mean.mean) + ' ms; n=' + reps + ' per cell', { fill: { color: CARD2 } }), cc('Gain vs None is large but mostly from distance LOD; controller adds ' + sgn(ctrlN) + ' / ' + sgn(ctrlS), { fill: { color: CARD2 } })],
  ];
  s.addTable(rows, { x: 0.5, y: 1.3, w: 12.3, colW: [2.5, 2.2, 2.2, 2.8, 2.6], border: { type: 'solid', pt: 0.75, color: LINE }, fontFace: BF, valign: 'middle', rowH: [0.34, 1.05, 1.05, 0.85, 0.85, 0.85], margin: [0.03, 0.07, 0.03, 0.07] });
  card(s, 0.5, 6.4, 12.3, 0.62, CARD2);
  T(s, [{ text: 'Caveat  ', options: { bold: true, color: AM } }, { text: 'Different hardware, scenes and baselines, so the numbers are context, not a like-for-like ranking. This was a limited web search, not a systematic review; papers that report comparable FPS or ms for LOD controllers on vegetation were scarce. Figures are as reported in the search results; verify against the papers before citing.', options: {} }], { x: 0.65, y: 6.43, w: 12.0, h: 0.56, fontSize: 10.5, valign: 'middle' });
  notes[8] = 'This slide places the result next to recent work from 2020 onwards. I want to be clear about its limits: I did a limited web search, not a systematic review, and very few papers report comparable numbers for LOD controllers on vegetation, so this is context rather than a ranking. The closest in spirit is a 2026 Visual Computer paper on frame-budget-driven adaptive LOD for VR, which reports the 95th percentile GPU frame time falling from 18.1 to 10.9 ms and over-budget frames falling from 84.5 to 7.0 percent against full-resolution rendering. Our equivalent, against no LOD, is a 99th percentile frame time falling from ' + f1(N.ft_p99.mean) + ' to ' + f1(NA.ft_p99.mean) + ' ms at 1080p. The reductions are larger here, but the baselines, scenes and hardware differ, and ours is mostly distance LOD rather than the controller. The 2025 HPG work on GPU tree generation reports a median 7.74 ms full-scene frame on a Radeon RX 7900 XTX, which is a different goal, memory and generation, on much newer hardware. The 2024 CPU-usage LOD paper reports CPU time falling 15.1 to 14.2 ms and 10.8 to 10.3 ms, triangles down 15.8 and 25 percent, and FPS up from 66.1 to 90 and from 121 to 146. That is the closest comparison for our controller step: its gains are larger than our plus 0.2 and plus 2.4 percent, but its signal is CPU usage while ours is GPU time on a GPU-bound scene, and the scenes and hardware differ. It supports our future work item of a CPU-bound signal. The foliage path tracing paper shares the theme but I could not extract comparable numbers. Verify the figures against the papers before citing them.';
  s.addNotes(notes[8]);
}

// ---------------- 9
{
  const s = base('Conclusion, limitations and next steps', 'SUMMARY');
  const cols = [
    ['Implemented', CY, ['Distance LOD for 4 vegetation categories, scaled by one PI-controlled bias', 'PI controller with rate limits, deadband, anti-windup', 'Metre-based floors keep near-field detail', 'Benchmark harness, debug panel (None / Adaptive), 4 self-test suites with a log-validating runner']],
    ['What the data shows', VI, ['1080p: ' + f1(N.avg_fps.mean) + ' to ' + f1(NA.avg_fps.mean) + ' FPS (' + mult(NA.avg_fps.mean, N.avg_fps.mean) + '), frame time ' + f1(red(NA.ft_mean.mean, N.ft_mean.mean)) + '% lower', '1440p: ' + f1(S.avg_fps.mean) + ' to ' + f1(SA.avg_fps.mean) + ' FPS (' + mult(SA.avg_fps.mean, S.avg_fps.mean) + '), frame time ' + f1(red(SA.ft_mean.mean, S.ft_mean.mean)) + '% lower', 'Primitives about ' + Math.round(primRed(NA, N)) + '% lower; GPU time ' + f1(gpuRedN) + '% / ' + f1(gpuRedS) + '% lower', 'The controller itself adds only ' + sgn(ctrlN) + ' / ' + sgn(ctrlS) + ' over fixed distances']],
    ['Limitations', AM, ['Debug/editor build only; no release build possible', 'GPU drifted 2 to 3x between sessions (the new demo recording ran in the slow state)', 'No perceptual quality metric; tree pops remain', 'No per-instance importance; grass determinism stage not run']],
  ];
  cols.forEach((cl, i) => {
    const x = 0.5 + i * 4.15;
    card(s, x, 1.35, 4.0, 3.35);
    T(s, cl[0], { x: x + 0.2, y: 1.45, w: 3.6, h: 0.35, fontSize: 18, bold: true, color: cl[1] });
    T(s, bul(cl[2], { paraSpaceAfter: 6 }), { x: x + 0.2, y: 1.9, w: 3.65, h: 2.75, fontSize: 13 });
  });
  T(s, 'Future work', { x: 0.5, y: 4.9, w: 3, h: 0.3, fontSize: 16, bold: true, color: CY });
  T(s, 'Tune floors and caps, add cross-fade to remove pops, benchmark a release build with a GPU profiler, add a CPU-bound signal, extend runs across GPU power states, add SSIM or FLIP, and a systematic literature comparison.', { x: 0.5, y: 5.25, w: 12.3, h: 0.75, fontSize: 13 });
  s.addShape(pres.shapes.RECTANGLE, { x: 0.5, y: 6.1, w: 12.3, h: 0.85, fill: { color: CARD2 }, line: { color: CY, width: 1.25 } });
  T(s, [{ text: 'Takeaway  ', options: { bold: true, color: CY } }, { text: 'Compared with drawing everything, adaptive LOD runs ' + mult(NA.avg_fps.mean, N.avg_fps.mean) + ' (1080p) and ' + mult(SA.avg_fps.mean, S.avg_fps.mean) + ' (1440p) faster in this scene. Most of that is distance LOD; the feedback controller adds a bounded safety margin when the GPU is over its target.', options: {} }], { x: 0.7, y: 6.15, w: 11.9, h: 0.75, fontSize: 14, valign: 'middle' });
  notes[9] = 'To conclude. What works: distance LOD for four vegetation categories with a PI-controlled bias, bounded by floors and caps, validated by four self-test suites run through a log-checking runner, and measured with a reproducible harness. What the data supports: against no LOD, the adaptive mode takes the scene from ' + f1(N.avg_fps.mean) + ' to ' + f1(NA.avg_fps.mean) + ' FPS at 1080p and from ' + f1(S.avg_fps.mean) + ' to ' + f1(SA.avg_fps.mean) + ' at 1440p, with about ' + Math.round(primRed(NA, N)) + ' percent fewer primitives. What it does not support: crediting the controller for that gain, since against fixed distances it adds only ' + sgn(ctrlN) + ' and ' + sgn(ctrlS) + ', or claiming the 8 ms target is met at 1440p. Limits: debug build only, GPU state drift, no perceptual metric, and a limited literature search. The takeaway is a bounded, quality-preserving mechanism whose controller is a safety margin on top of ordinary distance LOD.';
  s.addNotes(notes[9]);
}

const out = FINAL + 'presentation_na/Adaptive_LOD_Godot_none_vs_adaptive.pptx';
pres.writeFile({ fileName: out }).then(() => {
  fs.writeFileSync(FINAL + 'presentation_na/speaker_script_none_vs_adaptive.md', '# Speaker script (final deck)\n\n' + Object.keys(notes).map(k => '## Slide ' + k + '\n\n' + notes[k] + '\n').join('\n'));
  console.log('wrote', out);
});
