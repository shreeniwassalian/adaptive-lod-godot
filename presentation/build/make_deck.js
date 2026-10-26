const pptxgen = require('pptxgenjs');
const fs = require('fs');
const path = require('path');
const ROOT = 'S:/godot/adaptivelod/presentation/';
const IMG = ROOT + 'images/';
const stats = JSON.parse(fs.readFileSync(ROOT + 'build/stats.json'));
const ts = JSON.parse(fs.readFileSync(ROOT + 'build/timeseries.json'));

const BG = '15181E', CARD = '1F242D', CARD2 = '262C37', TX = 'E6E9EF', MUT = '9AA3B2';
const CY = '35D0E8', VI = 'A78BFA', RD = 'FF6B6B', AM = 'F5B14C', GRY = '7B8494', LINE = '3A4150';
const HF = 'Cambria', BF = 'Calibri';

const pres = new pptxgen();
pres.layout = 'LAYOUT_WIDE'; // 13.33 x 7.5
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
function base(n, title, kicker) {
  const s = pres.addSlide({ masterName: 'CONTENT' });
  s.addText(kicker, { x: 0.5, y: 0.28, w: 8, h: 0.28, fontFace: BF, fontSize: 12, bold: true, color: CY, margin: 0, isTextBox: true, charSpacing: 2 });
  s.addText(title, { x: 0.5, y: 0.55, w: 12.3, h: 0.6, fontFace: HF, fontSize: 30, bold: true, color: TX, margin: 0, isTextBox: true, fit: 'shrink' });
  return s;
}
function card(s, x, y, w, h, fill) { s.addShape(pres.shapes.RECTANGLE, { x, y, w, h, fill: { color: fill || CARD }, line: { color: LINE, width: 0.75 } }); }
function chip(s, text, x, y, w, color) {
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h: 0.26, rectRadius: 0.08, fill: { color: color, transparency: 80 }, line: { color: color, width: 0.75 } });
  s.addText(text, { x, y, w, h: 0.26, fontFace: BF, fontSize: 10, bold: true, color: color, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
}
const T = (s, text, o) => s.addText(text, Object.assign({ fontFace: BF, fontSize: 14, color: TX, margin: 0, isTextBox: true, valign: 'top' }, o));
const bul = (arr, o) => arr.map((t, i) => ({ text: t, options: Object.assign({ bullet: true, breakLine: i < arr.length - 1, paraSpaceAfter: 5 }, o || {}) }));

// ---------------- Slide 1
{
  const s = pres.addSlide({ masterName: 'TITLE' });
  T(s, 'COMPUTER GRAPHICS  |  GAME ENGINE ENGINEERING', { x: 0.6, y: 0.7, w: 6, h: 0.3, fontSize: 12, bold: true, color: CY, charSpacing: 2 });
  T(s, 'Adaptive Level of Detail for Real-Time Rendering in Godot', { x: 0.6, y: 1.2, w: 5.9, h: 2.1, fontFace: HF, fontSize: 38, bold: true });
  T(s, 'A feedback-controlled, distance-based LOD for vegetation, compared against a fixed-threshold baseline', { x: 0.6, y: 3.45, w: 5.8, h: 0.9, fontSize: 16, color: MUT });
  T(s, 'Shreeniwas Salian', { x: 0.6, y: 4.5, w: 5.8, h: 0.4, fontSize: 20, bold: true, color: TX });
  card(s, 0.6, 5.3, 5.8, 1.15);
  T(s, [{ text: 'Problem  ', options: { bold: true, color: CY } }, { text: 'Dense vegetation scenes cost frame time; fixed LOD distances cannot react when the GPU is overloaded, so detail is either wasted or cut blindly.', options: {} }], { x: 0.8, y: 5.42, w: 5.4, h: 1.15, fontSize: 14 });
  s.addImage({ path: IMG + 'title_scene.jpg', x: 6.9, y: 1.35, w: 5.9, h: 3.31, altText: 'Screenshot of the Godot benchmark scene' });
  T(s, 'Real capture from the project (Godot 4.7.2, Terrain3D 1.0.2, 1920x1080, baseline LOD, fixed probe view at path start).', { x: 6.9, y: 4.75, w: 5.9, h: 0.5, fontSize: 11, color: MUT });
  const kp = [['41,698', 'vegetation instances'], ['528 m', 'fixed camera path'], ['3 modes', 'none / baseline / adaptive']];
  kp.forEach((k, i) => { T(s, k[0], { x: 6.9 + i * 2.0, y: 5.5, w: 1.9, h: 0.5, fontSize: 24, bold: true, color: i === 2 ? VI : CY }); T(s, k[1], { x: 6.9 + i * 2.0, y: 6.05, w: 1.9, h: 0.5, fontSize: 12, color: MUT }); });
  notes[1] = 'This project asks a narrow question: if the renderer is over budget, can a controller coarsen vegetation detail automatically, in a stable and bounded way, and does that buy frame time? The scene is a Terrain3D forest with about 42 thousand vegetation instances plus a very dense grass field. I compared a fixed-threshold baseline against an adaptive version on the same scene and camera path. The honest summary, which I will build up to, is: the mechanism works and is bounded, the visual change is small, and the measured performance gain is small and only demonstrated in one configuration.';
  s.addNotes(notes[1]);
}

// ---------------- Slide 2
{
  const s = base(2, 'Why LOD, and where fixed thresholds fall short', 'PROBLEM AND MOTIVATION');
  card(s, 0.5, 1.35, 6.3, 3.55);
  s.addImage({ path: ROOT + 'charts/diagram_lod_levels_schematic.png', x: 0.7, y: 1.45, w: 5.9, h: 1.97 });
  T(s, 'Schematic only: polygon count falls as distance grows (not the project meshes).', { x: 0.7, y: 3.42, w: 5.9, h: 0.25, fontSize: 10, color: MUT });
  [['LOD0', '0 to 60 m', CY], ['LOD1', '60 to 150 m', VI], ['LOD2', 'beyond 150 m', GRY]].forEach((b, i) => {
    s.addShape(pres.shapes.RECTANGLE, { x: 0.7 + i * 1.97, y: 3.8, w: 1.87, h: 0.65, fill: { color: CARD2 }, line: { color: b[2], width: 1 } });
    T(s, [{ text: b[0], options: { bold: true, color: b[2], breakLine: true } }, { text: b[1], options: { color: TX } }], { x: 0.7 + i * 1.97, y: 3.84, w: 1.87, h: 0.6, fontSize: 12, align: 'center' });
  });
  T(s, 'Baseline tree thresholds from the code (60 m / 150 m, 10 m hysteresis).', { x: 0.7, y: 4.5, w: 5.9, h: 0.25, fontSize: 10, color: MUT });
  T(s, 'General LOD concepts', { x: 0.5, y: 5.1, w: 6.3, h: 0.3, fontSize: 18, bold: true, color: CY });
  T(s, bul(['Cost scales with triangles, draw calls and overdraw', 'Distant objects need fewer triangles for the same look', 'Fixed distances ignore the actual frame budget']), { x: 0.5, y: 5.45, w: 6.3, h: 1.5, fontSize: 14 });
  card(s, 7.1, 1.35, 5.7, 5.55, CARD);
  T(s, 'Implemented in this project', { x: 7.35, y: 1.5, w: 5.2, h: 0.35, fontSize: 18, bold: true, color: VI });
  T(s, bul([
    'Fixed-threshold baseline for 4 categories: trees (3 mesh levels), grass (3 tiers + cull), bushes and debris (density thinning)',
    'Adaptive mode: one PI-controlled bias scales the same thresholds from a measured GPU render time',
    'Hysteresis, rate limits and a per-update change budget to limit popping',
    'Same scene, seed and camera path for every mode'], { paraSpaceAfter: 8 }), { x: 7.35, y: 1.95, w: 5.25, h: 3.0, fontSize: 14 });
  T(s, 'Not implemented', { x: 7.35, y: 5.0, w: 5.2, h: 0.35, fontSize: 18, bold: true, color: AM });
  T(s, bul(['Per-instance or screen-size importance', 'Cross-fade or dither between mesh levels (trees still pop)', 'Mesh LOD for bushes (density only)'], { paraSpaceAfter: 3 }), { x: 7.35, y: 5.4, w: 5.25, h: 1.4, fontSize: 14 });
  notes[2] = 'Rendering cost grows with triangles, draw calls and overdraw. LOD trades detail for cost by swapping to simpler representations with distance. The weakness of a fixed-distance scheme is that it does not know the frame budget: it draws the same detail whether the GPU is at 8 ms or 30 ms. The left side is general concept; the schematic is illustrative, not my meshes. The right side is what I actually built: a baseline with fixed thresholds for trees, grass, bushes and debris, and an adaptive mode that scales those same thresholds with one feedback-controlled bias. I also want to be clear about what is not there: no per-instance importance, no cross-fading, and bushes have no mesh LOD, only density thinning.';
  s.addNotes(notes[2]);
}

// ---------------- Slide 3
{
  const s = base(3, 'Architecture: one controller bias scales fixed metre thresholds', 'SYSTEM ARCHITECTURE');
  function box(x, y, w, h, title, sub, color) {
    s.addShape(pres.shapes.RECTANGLE, { x, y, w, h, fill: { color: CARD2 }, line: { color: color, width: 1.25 } });
    T(s, [{ text: title, options: { bold: true, color: TX, breakLine: true, fontSize: 12 } }, { text: sub, options: { color: MUT, fontSize: 10.5 } }], { x: x + 0.08, y: y + 0.06, w: w - 0.16, h: h - 0.1, align: 'center', valign: 'middle', fontSize: 12 });
  }
  function arrow(x1, y1, x2, y2, color) {
    s.addShape(pres.shapes.LINE, { x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.abs(x2 - x1), h: Math.abs(y2 - y1), flipH: x2 < x1, flipV: y2 < y1, line: { color: color || MUT, width: 1.5, endArrowType: 'triangle' } });
  }
  T(s, 'ADAPTIVE MODE ONLY  (adaptive_lod.gd, pi_controller.gd)', { x: 0.55, y: 1.3, w: 8, h: 0.25, fontSize: 11, bold: true, color: VI });
  const A = [['GPU render time', 'viewport measured time, VSync off'], ['Smoothing', 'EMA 0.5 s, spike clip 3x'], ['PI controller', 'target 16.67 ms, deadband 3%'], ['Rate limits', '+0.10 up / -0.03 down per 0.25 s'], ['Global bias 0..2', 'then per-category onset, gain, cap']];
  const aw = 2.2, ag = 0.3;
  A.forEach((a, i) => { box(0.55 + i * (aw + ag), 1.6, aw, 0.9, a[0], a[1], VI); if (i < 4) arrow(0.55 + i * (aw + ag) + aw, 2.05, 0.55 + (i + 1) * (aw + ag), 2.05, VI); });
  T(s, 'BOTH MODES  (lod_manager.gd, lod_policy.gd)', { x: 0.55, y: 2.9, w: 10, h: 0.25, fontSize: 11, bold: true, color: CY });
  const B = [['Scene + camera path', '528 m, 8 m/s, seed 1337'], ['Camera distance', 'metres, per chunk / cell / tree'], ['LOD policy', 'baseline: fixed thresholds\nadaptive: distance x (1+bias)'], ['Detail update', 'MultiMesh tier / count, hysteresis, change budget'], ['Rendered frame', 'MetricsSampler: frame, GPU, draws'], ['CSV + JSON', 'benchmark_summary: avg, p50, p95, p99']];
  const bw = 1.85, bg = 0.226;
  B.forEach((b, i) => { box(0.55 + i * (bw + bg), 3.2, bw, 1.0, b[0], b[1], CY); if (i < 5) arrow(0.55 + i * (bw + bg) + bw, 3.7, 0.55 + (i + 1) * (bw + bg), 3.7, CY); });
  // bias drops into the policy box (index 2)
  const px = 0.55 + 2 * (bw + bg) + bw / 2, ax = 0.55 + 4 * (aw + ag) + aw / 2;
  s.addShape(pres.shapes.LINE, { x: ax, y: 2.5, w: 0, h: 0.2, line: { color: VI, width: 1.5 } });
  s.addShape(pres.shapes.LINE, { x: px, y: 2.7, w: ax - px, h: 0, line: { color: VI, width: 1.5 } });
  arrow(px, 2.7, px, 3.2, VI);
  T(s, 'bias', { x: px + 0.1, y: 2.72, w: 0.6, h: 0.22, fontSize: 10, color: VI, bold: true });
  // text cards
  card(s, 0.55, 4.45, 3.95, 2.5);
  T(s, 'Thresholds in metres', { x: 0.7, y: 4.52, w: 3.7, h: 0.3, fontSize: 15, bold: true, color: CY });
  T(s, bul(['Trees: effective = max(floor, base / (1 + bias)), never above base', 'Hysteresis added in metres (10 m)', 'Bias 0 gives exactly the baseline, so the same code serves both modes'], { paraSpaceAfter: 3 }), { x: 0.7, y: 4.85, w: 3.7, h: 2.05, fontSize: 12 });
  card(s, 4.65, 4.45, 3.95, 2.5);
  T(s, 'Bounded coarsening', { x: 4.8, y: 4.52, w: 3.7, h: 0.3, fontSize: 15, bold: true, color: CY });
  T(s, bul(['Tree floors: LOD1 never before 60 m, LOD2 never before 100 m', 'Per-category caps: grass 1.0, trees 1.0, bushes 0.5, debris 0.5', 'bias_min 0: never finer than baseline. bias_max 2.0'], { paraSpaceAfter: 3 }), { x: 4.8, y: 4.85, w: 3.7, h: 2.05, fontSize: 12 });
  s.addShape(pres.shapes.RECTANGLE, { x: 8.75, y: 4.45, w: 4.05, h: 2.5, fill: { color: '0E1116' }, line: { color: LINE, width: 0.75 } });
  T(s, 'baseline_lod.gd: _rebuild_thresholds()', { x: 8.88, y: 4.5, w: 3.8, h: 0.22, fontSize: 10, color: MUT });
  T(s, 'for i in 2:\n  var effective: float = base[i] / _dist_scale\n  if _dist_scale > 1.0:  # coarser\n    effective = minf(base[i],\n      maxf(effective, floors[i]))\n  _thresholds[i] = effective', { x: 8.88, y: 4.8, w: 3.85, h: 2.05, fontFace: 'Courier New', fontSize: 11, color: CY });
  notes[3] = 'The pipeline has two halves. Along the top is the adaptive part, which only runs in adaptive mode: the GPU render time of the main viewport is smoothed, compared against a target, and a PI controller with rate limits produces one global bias between 0 and 2, which is mapped to a per-category bias. Along the bottom is what runs in both modes: for each tree, grass cell or chunk the policy compares camera distance in metres against thresholds, with hysteresis, and updates MultiMesh tiers under a change budget. With the bias at zero the thresholds are exactly the baseline, so the baseline is the adaptive system with the controller switched off. The snippet is the real threshold code: the effective threshold is baseline divided by one plus bias, but clamped by a floor in metres, so trees closer than 100 m can never be coarser than baseline LOD1. One precise point for the viva: the constraint is expressed as distance floors and per-category caps, not literally as a two-level limit; trees only have three mesh levels, so the coarsest possible step is LOD0 to LOD2, and the floors restrict where that is allowed.';
  s.addNotes(notes[3]);
}

// ---------------- Slide 4
{
  const s = base(4, 'Technical contributions, and what the evidence supports', 'NOVELTY');
  const rows = [
    ['1  Adaptive thresholds', 'Fixed distances, 60 / 150 m for trees', 'One PI-controlled bias scales all thresholds from GPU time', 'Reacts to load instead of ignoring it', 'Controller self-tests (documented passing); bias saturates at 2.0 in stress', 'Implemented', CY],
    ['2  Real-world units', 'Metres, fixed', 'Floors, caps and hysteresis in metres; coarser = distance x (1+bias)', 'Visible effect is predictable and tunable in scene units', 'Code + tests: tree LOD never differs from baseline within 100 m', 'Implemented', CY],
    ['3  Constrained coarsening', 'No notion of a limit', 'Tree floors 60 / 100 m, category caps, bias range 0..2', 'Keeps nearby detail intact', '0 tree violations within 100 m at bias 2.0 (self-test). Not literally a 2-level limit', 'Partly as stated', AM],
    ['4  Unified benchmark', 'n/a', 'Same scene, seed, path (sha256 logged), interleaved runs, CSV + JSON', 'Fair, repeatable comparison', '11 runs in the m4 series; hardware state drifted between some runs', 'Implemented, noisy', AM],
    ['5  Quality / speed trade-off', 'Full detail baseline', 'Measures primitives, draws, GPU ms and image difference', 'Shows what a saving costs', 'Primitives -5 to -10% (fixed view). GPU gain only in stress: -5.5%. No perceptual metric', 'Partly demonstrated', AM],
  ];
  const hdr = ['Contribution', 'Baseline does', 'Adaptive changes', 'Why it matters', 'Evidence', 'Status'];
  const cw = [1.85, 1.7, 2.65, 1.75, 3.2, 1.15];
  const tr = [hdr.map(h => ({ text: h, options: { bold: true, color: BG, fill: { color: CY }, fontSize: 11, fontFace: BF } }))];
  rows.forEach(r => tr.push(r.slice(0, 5).map((c, j) => ({ text: c, options: { color: j === 0 ? TX : '#DDE1E8'.slice(1), bold: j === 0, fontSize: 10.5, fontFace: BF, fill: { color: CARD } } })).concat([{ text: r[5], options: { color: r[6], bold: true, fontSize: 10.5, fill: { color: CARD }, fontFace: BF } }])));
  s.addTable(tr, { x: 0.5, y: 1.35, w: 12.3, colW: cw, border: { type: 'solid', pt: 0.75, color: LINE }, valign: 'middle', rowH: [0.35, 0.85, 0.85, 0.95, 0.85, 0.95], margin: [0.04, 0.08, 0.04, 0.08] });
  card(s, 0.5, 6.35, 12.3, 0.62, CARD2);
  T(s, [{ text: 'Scope of the claim:  ', options: { bold: true, color: VI } }, { text: 'these are this project\'s technical contributions. No literature review was done, so none is claimed as globally novel; feedback-controlled quality scaling is an established idea in general.', options: {} }], { x: 0.65, y: 6.4, w: 12.0, h: 0.52, fontSize: 12, valign: 'middle' });
  notes[4] = 'Five contributions, each with a status I can defend. One: thresholds that move with a controller instead of being fixed. Two: everything expressed in metres, so the behaviour is interpretable. Three: constrained coarsening. Here I need to be exact: what is implemented is distance floors for trees at 60 and 100 metres plus per-category caps, and a self-test shows zero trees within 100 m deviating from baseline at the maximum bias. That is not literally a two-level limit, so I mark it as partly matching. Four: the benchmark harness, with the same path hash and seed, interleaved runs, and full CSV and JSON output; the caveat is that machine state drifted. Five: the trade-off, where I have exact primitive counts and one stress-profile frame-time gain, but no perceptual quality metric yet. And I make no claim of global novelty because I did not do a literature review.';
  s.addNotes(notes[4]);
}

// ---------------- Slide 5
{
  const s = base(5, 'Experimental setup and fairness of the comparison', 'METHODOLOGY');
  const H = (t) => ({ text: t, options: { bold: true, color: BG, fill: { color: CY }, fontSize: 11 } });
  const c = (t, o) => ({ text: t, options: Object.assign({ color: TX, fill: { color: CARD }, fontSize: 11 }, o || {}) });
  const l = (t) => c(t, { color: MUT });
  const rows = [
    [H('Condition'), H('Baseline'), H('Adaptive')],
    [l('Software'), c('Godot 4.7.2-stable, DEBUG + EDITOR build, Windows'), c('same')],
    [l('Hardware'), c('Intel i7-8850H (12 threads), NVIDIA Quadro P3200 laptop GPU'), c('same machine')],
    [l('Renderer'), c('Forward+, D3D12, no MSAA / TAA, VSync off, FPS uncapped'), c('same')],
    [l('Resolution'), c('Normal 1920x1080  |  Stress 2560x1440'), c('same')],
    [l('Scene'), c('Terrain3D 1.0.2, 41,698 instances + 403k grass clumps, seed 1337'), c('same')],
    [l('Camera'), c('528 m path, 8 m/s, 10 s warm-up, 60 s measured'), c('same, controller reset to bias 0 at start')],
    [l('LOD'), c('Fixed thresholds, 4 categories'), c('Same thresholds x PI bias; target 16.67 ms (normal), 8 ms (stress)')],
    [l('Runs'), c('Normal 3, stress 2'), c('Normal 3, stress 2 (+1 reachable-target run)')],
    [l('Metrics'), c('Per-frame frame time, GPU ms, draws, primitives, switches, policy CPU ms (CSV, ~2k to 6k rows per run)'), c('+ bias, controller terms')],
  ];
  s.addTable(rows, { x: 0.5, y: 1.35, w: 7.9, colW: [1.2, 3.9, 2.8], border: { type: 'solid', pt: 0.75, color: LINE }, fontFace: BF, valign: 'middle', rowH: [0.32, 0.45, 0.45, 0.45, 0.4, 0.45, 0.45, 0.55, 0.4, 0.62], margin: [0.03, 0.08, 0.03, 0.08] });
  card(s, 8.65, 1.35, 4.15, 2.75);
  T(s, 'Fairness risks found', { x: 8.8, y: 1.43, w: 3.9, h: 0.3, fontSize: 16, bold: true, color: AM });
  T(s, bul(['Runs alternate baseline / adaptive, but GPU speed drifted: normal baseline #1 ran at 9.3 ms GPU, #2 and #3 at ~19 ms', 'Debug + editor build, so CPU timings are inflated', 'Results used the milestone-4 mapping; the current, gentler mapping has no timed run'], { paraSpaceAfter: 3 }), { x: 8.8, y: 1.78, w: 3.95, h: 2.3, fontSize: 11.5 });
  card(s, 8.65, 4.25, 4.15, 2.7);
  T(s, 'Missing, please supply', { x: 8.8, y: 4.33, w: 3.9, h: 0.3, fontSize: 16, bold: true, color: RD });
  T(s, bul(['GPU driver version, RAM, power plan, thermals', 'Release / export-build run', 'More repeats (2 to 3 per cell is thin)', 'Idle machine, editor closed'], { paraSpaceAfter: 3 }), { x: 8.8, y: 4.68, w: 3.95, h: 2.2, fontSize: 11.5 });
  notes[5] = 'All numbers come from the project benchmark harness: Godot 4.7.2 in a debug editor build on an i7-8850H with a Quadro P3200, Forward+ on D3D12, VSync off and uncapped. The camera follows a fixed 528 metre path at 8 metres per second with a 10 second warm-up and 60 seconds measured. Baseline and adaptive runs were interleaved. Equivalent conditions: same scene, seed, path hash and resolution. Differences that threaten fairness: the machine GPU state changed between runs, which you can see in normal baseline number 1; the build is a debug editor build; and the results use an earlier controller mapping than the current code. Hardware items such as driver version and RAM were not recorded in the files, so I flag them as missing rather than guess.';
  s.addNotes(notes[5]);
}

// ---------------- Slide 6
{
  const s = base(6, 'Results: a small gain under stress, no gain at 1080p', 'BENCHMARK ANALYSIS');
  const d = stats.stress, n = stats.normal_b23;
  s.addChart(pres.charts.BAR, [
    { name: 'Baseline (n=2)', labels: ['Average FPS', 'Median FPS', '1% low FPS', 'Min FPS'], values: [d.avg.base, d.med.base, d.low1.base, d.minfps.base].map(v => +v.toFixed(1)) },
    { name: 'Adaptive (n=2)', labels: ['Average FPS', 'Median FPS', '1% low FPS', 'Min FPS'], values: [d.avg.adapt, d.med.adapt, d.low1.adapt, d.minfps.adapt].map(v => +v.toFixed(1)) },
  ], { x: 0.5, y: 1.3, w: 6.2, h: 3.1, barDir: 'col', barGrouping: 'clustered', chartColors: [GRY, CY], showLegend: true, legendPos: 'b', legendColor: TX, legendFontSize: 10, legendFontFace: BF,
    showValue: true, dataLabelColor: TX, dataLabelFontSize: 10, dataLabelFontFace: BF, dataLabelPosition: 'outEnd', dataLabelFormatCode: '0.0',
    catAxisLabelColor: MUT, valAxisLabelColor: MUT, catAxisLabelFontSize: 10, valAxisLabelFontSize: 10, catAxisLabelFontFace: BF, valAxisLabelFontFace: BF,
    valGridLine: { color: '2C3340', size: 0.5 }, catGridLine: { style: 'none' }, valAxisMinVal: 0, valAxisMaxVal: 40, valAxisTitle: 'FPS (higher is better)', showValAxisTitle: true, valAxisTitleColor: MUT, valAxisTitleFontSize: 10,
    showTitle: true, title: 'Stress profile 2560x1440, 60 s runs (mean of 2)', titleColor: TX, titleFontSize: 12, titleFontFace: BF });
  const nb = Math.min(ts.m4_stress_base_1[0].length, ts.m4_stress_adapt_1[0].length);
  const labs = Array.from({ length: nb }, (_, i) => String(i));
  s.addChart(pres.charts.LINE, [
    { name: 'Baseline #1', labels: labs, values: ts.m4_stress_base_1[0].slice(0, nb) },
    { name: 'Adaptive #1', labels: labs, values: ts.m4_stress_adapt_1[0].slice(0, nb) },
  ], { x: 6.9, y: 1.3, w: 5.9, h: 3.1, chartColors: [GRY, CY], lineSize: 2, lineDataSymbol: 'none', showLegend: true, legendPos: 'b', legendColor: TX, legendFontSize: 10, legendFontFace: BF,
    catAxisLabelColor: MUT, valAxisLabelColor: MUT, catAxisLabelFontSize: 10, valAxisLabelFontSize: 10, catAxisLabelFontFace: BF, valAxisLabelFontFace: BF, catAxisLabelFrequency: 10,
    valGridLine: { color: '2C3340', size: 0.5 }, catGridLine: { style: 'none' }, valAxisMinVal: 0, valAxisMaxVal: 45, valAxisTitle: 'FPS per 1 s bin (higher is better)', showValAxisTitle: true, valAxisTitleColor: MUT, valAxisTitleFontSize: 10,
    catAxisTitle: 'time in measured run (s)', showCatAxisTitle: true, catAxisTitleColor: MUT, catAxisTitleFontSize: 10,
    showTitle: true, title: 'Stress run #1: FPS over time', titleColor: TX, titleFontSize: 12, titleFontFace: BF });
  const f = (v, k) => v.toFixed(k === undefined ? 1 : k);
  const pc = (v) => (v >= 0 ? '+' : '') + v.toFixed(1) + '%';
  const H = (t) => ({ text: t, options: { bold: true, color: BG, fill: { color: CY }, fontSize: 10.5, align: 'center' } });
  const c = (t, o) => ({ text: t, options: Object.assign({ color: TX, fill: { color: CARD }, fontSize: 10.5, align: 'center' }, o || {}) });
  const good = (v, lowerBetter) => ((lowerBetter ? v < 0 : v > 0) ? CY : RD);
  const row = (name, k, lb) => [c(name, { align: 'left', color: MUT }), c(f(d[k].base)), c(f(d[k].adapt)), c(pc(d[k].pct), { color: good(d[k].pct, lb), bold: true }), c(f(n[k].base)), c(f(n[k].adapt)), c(pc(n[k].pct), { color: good(n[k].pct, lb), bold: true })];
  const tb = [
    [H('Metric'), H('Stress base'), H('Stress adapt'), H('Change'), H('Normal base*'), H('Normal adapt'), H('Change')],
    row('Average FPS', 'avg'), row('Median FPS', 'med'), row('1% low FPS', 'low1'), row('Min FPS', 'minfps'), row('Mean frame ms (lower = better)', 'ft_mean', true),
  ];
  s.addTable(tb, { x: 0.5, y: 4.5, w: 8.1, colW: [2.2, 0.95, 0.95, 0.85, 1.05, 1.1, 0.85], border: { type: 'solid', pt: 0.75, color: LINE }, fontFace: BF, valign: 'middle', rowH: 0.3, margin: [0.02, 0.06, 0.02, 0.06] });
  T(s, '*Normal baseline = runs #2 and #3. Including run #1 (104 FPS avg, GPU state changed) gives 66.2 vs 46.6 FPS avg, -29.6% for adaptive; that run is shown, not hidden, but is not a like-for-like pair. Change = (Adaptive - Baseline) / Baseline x 100. Normal n = 3 adapt vs 2 base.', { x: 0.5, y: 6.35, w: 8.1, h: 0.65, fontSize: 10, color: MUT });
  card(s, 8.8, 4.5, 4.0, 2.5);
  T(s, 'Sub-10 FPS check', { x: 8.95, y: 4.57, w: 3.7, h: 0.3, fontSize: 15, bold: true, color: AM });
  T(s, bul(['0 frames under 10 FPS in all 6 adaptive 60 s runs; worst frame 20.7 FPS (48 ms)', 'One frame at 3.7 FPS: baseline #1 (not adaptive)', 'Not logged: your live drops. Hypothesis only: the ~0.7 to 1 s first-enable build when switching mode'], { paraSpaceAfter: 3 }), { x: 8.95, y: 4.9, w: 3.75, h: 2.05, fontSize: 11 });
  notes[6] = 'This is the main results slide. In the stress profile at 1440p, two baseline runs and two adaptive runs agree closely with each other: adaptive averages 33.4 FPS against 31.5, a 5.8 percent increase, and mean frame time drops from 31.7 to 29.95 ms, minus 5.5 percent; for frame time lower is better, so a negative change is an improvement. Main-pass primitives fall about 17 percent and draw calls about 10 percent in that profile. At 1080p the picture is different: baseline runs 2 and 3 and the adaptive runs are statistically indistinguishable, about minus 1.5 percent average FPS, so I claim nothing there. Baseline run 1 ran at 104 FPS because the GPU was in a different state; I show it rather than drop it. On the sub-10 FPS question: I checked every recorded run. No adaptive 60 second run has a frame under 10 FPS; the worst adaptive frame is 20.7 FPS. The only sub-10 frame in this series is in baseline number 1. So the severe drops you saw while playing are not in the saved logs. One hypothesis is the first-enable build, which takes roughly 0.7 to 1 second when you switch modes live, but that is untested. Also, the controller never reached its targets: 16.67 ms at 1080p and 8 ms in stress. The performance objective is therefore not achieved; only a small stress-profile gain was measured.';
  s.addNotes(notes[6]);
}

// ---------------- Slide 7
{
  const s = base(7, 'Visual comparison: baseline vs adaptive at the same view', 'VISUAL QUALITY');
  const iw = 4.0, ih = 2.25;
  const pairs = [['Baseline, full view', 'baseline_v0.jpg', 0.5, 1.3], ['Adaptive (bias 2.0), full view', 'adaptive_v0.jpg', 4.65, 1.3], ['Baseline, crop of left treeline and mid grass', 'baseline_v0_crop.jpg', 0.5, 3.95], ['Adaptive, same crop', 'adaptive_v0_crop.jpg', 4.65, 3.95]];
  pairs.forEach(p => {
    s.addImage({ path: IMG + p[1], x: p[2], y: p[3], w: iw, h: ih, altText: p[0] });
    T(s, p[0], { x: p[2], y: p[3] + ih + 0.02, w: iw, h: 0.25, fontSize: 10.5, color: MUT });
  });
  T(s, 'What changes', { x: 8.9, y: 1.3, w: 3.9, h: 0.3, fontSize: 16, bold: true, color: CY });
  T(s, bul(['Near field is identical: nearby trees keep baseline LOD (floors)', 'Mid-field grass is thinner; distant bushes sparser', 'Main-pass primitives -9% at this view (-5% at 150 m, -10% at 300 m)', 'Mean abs image difference 4.27 / 0.87 / 0.98 (0 / 150 / 300 m)'], { paraSpaceAfter: 4 }), { x: 8.9, y: 1.65, w: 3.9, h: 2.5, fontSize: 12 });
  T(s, 'Fixed-view probe with bias pinned at 2.0, not a live controller run. Tree mesh swaps still pop (no cross-fade).', { x: 8.9, y: 4.0, w: 3.9, h: 0.65, fontSize: 10.5, color: MUT });
  s.addShape(pres.shapes.RECTANGLE, { x: 8.9, y: 4.75, w: 3.9, h: 2.2, fill: { color: CARD }, line: { color: AM, width: 1.25, dashType: 'dash' } });
  T(s, [{ text: 'VIDEO PLACEHOLDER', options: { bold: true, color: AM, breakLine: true, fontSize: 14 } }, { text: 'No screen recording or URL exists in the project folder. In PowerPoint: Insert > Video > This Device, then choose your Godot capture (baseline vs adaptive, same path).', options: { color: MUT, fontSize: 11 } }], { x: 9.05, y: 4.85, w: 3.6, h: 2.0, valign: 'middle', align: 'center' });
  notes[7] = 'These are real captures from the project, same camera position, scene and seed. The top row is the full view; the bottom row is a crop of the left treeline and mid-field grass. The visible differences are modest: nearby trees are identical because of the floors, mid-field grass is thinner, and distant bushes are sparser. Main-pass primitives are 9 percent lower at this view. Image difference is a mean absolute pixel difference, which is a crude metric, not a perceptual one. This is a fixed-view probe with the bias pinned at 2.0, so it shows the extreme of the adaptive range rather than a live controller run. Tree mesh swaps still pop because there is no cross-fade. The video box is a placeholder: no recording is in the project files, so insert your own clip here before presenting.';
  s.addNotes(notes[7]);
}

// ---------------- Slide 8
{
  const s = base(8, 'Conclusion, limitations and next steps', 'SUMMARY');
  const cols = [
    ['Implemented', CY, ['Baseline and adaptive LOD for 4 vegetation categories', 'PI controller with rate limits, deadband, anti-windup', 'Metre-based floors keep near-field detail', 'Reproducible benchmark with CSV + JSON']],
    ['What the data shows', VI, ['Stress 1440p: +5.8% avg FPS, -5.5% frame time (n=2)', '1080p: no measurable change (-1.5% avg FPS)', 'Visual change small and localised, primitives -5 to -10%', 'Targets (16.67 / 8 ms) never reached']],
    ['Limitations', AM, ['Few runs, drifting GPU state, debug build', 'No timed run of the current mapping', 'Live <10 FPS drops not captured in logs', 'No perceptual metric, tree pops, no importance']],
  ];
  cols.forEach((c, i) => {
    const x = 0.5 + i * 4.15;
    card(s, x, 1.35, 4.0, 3.35);
    T(s, c[0], { x: x + 0.2, y: 1.45, w: 3.6, h: 0.35, fontSize: 18, bold: true, color: c[1] });
    T(s, bul(c[2], { paraSpaceAfter: 6 }), { x: x + 0.2, y: 1.9, w: 3.65, h: 2.75, fontSize: 13 });
  });
  T(s, 'Future work', { x: 0.5, y: 4.9, w: 3, h: 0.3, fontSize: 16, bold: true, color: CY });
  T(s, 'Tune floors and caps, add cross-fade to remove pops, profile with release builds and a GPU profiler, move the first-enable build off the live frame, add a CPU-bound signal, repeat on an idle machine with more runs, add SSIM or FLIP.', { x: 0.5, y: 5.25, w: 12.3, h: 0.75, fontSize: 13, color: TX });
  s.addShape(pres.shapes.RECTANGLE, { x: 0.5, y: 6.1, w: 12.3, h: 0.85, fill: { color: CARD2 }, line: { color: CY, width: 1.25 } });
  T(s, [{ text: 'Takeaway  ', options: { bold: true, color: CY } }, { text: 'The adaptive mechanism is implemented and bounded, and it saves a few percent of GPU time only when the GPU is heavily overloaded. Visual quality is largely preserved. Improved performance is not yet demonstrated in the normal profile.', options: {} }], { x: 0.7, y: 6.15, w: 11.9, h: 0.75, fontSize: 14, valign: 'middle' });
  notes[8] = 'To conclude. What works: the adaptive mechanism is implemented, bounded by floors and caps, and measured with a reproducible harness. What the data supports: a 5 to 6 percent frame-time gain in the stress profile, no measurable change at 1080p, and a small, localised visual change. What it does not support: that adaptive LOD reaches the frame-time targets, or that it fixes FPS instability. The severe drops I observed while playing are not in the saved logs, so I will not explain them as fact; the first-enable build is my leading hypothesis. Next steps are tuning, cross-fading, release-build profiling and more repeats on an idle machine. The takeaway: adaptive LOD gives a controllable, quality-preserving trade-off, but the benefit on this workload is small because terrain, shadows and the rest of the frame dominate the GPU time.';
  s.addNotes(notes[8]);
}

pres.writeFile({ fileName: ROOT + 'Adaptive_LOD_Godot.pptx' }).then(f => {
  fs.writeFileSync(ROOT + 'speaker_script.md', '# Speaker script\n\n' + Object.keys(notes).map(k => `## Slide ${k}\n\n${notes[k]}\n`).join('\n'));
  console.log('wrote', f);
});
