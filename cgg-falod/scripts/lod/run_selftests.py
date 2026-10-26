#!/usr/bin/env python3
"""External runner for the LOD self-tests: a run only passes if its log is clean, not just if the test says PASS.

Why: the tests count failed _check() calls and print "PASS (0 failures)", but GDScript has no try/except, so a script
error (e.g. a null node) silently aborts the rest of a coroutine while the test still reaches the final PASS line.
Godot's own log is the only place that error shows, so this runner reads it.

A test run FAILS when any of these hold:
  * the process exit code is not 0 or it did not finish within the timeout;
  * there is not exactly one final "<prefix> PASS (0 failures)" line, or any "<prefix> FAIL" line exists;
  * the log contains SCRIPT ERROR, Parse Error, USER ERROR/USER SCRIPT ERROR or a Debugger Break;
  * any other ERROR:/WARNING: line appears that is not on the allowlist below (shutdown leak reports are accepted only
    AFTER the final result line; environment noise such as audio-device warnings is accepted anywhere);
  * fewer "ok" checks were executed than the recorded minimum, or the required last check never ran
    (catches sections that were skipped or aborted without an error message).
Minimums are floors taken from clean runs on 2026-10-23 (adaptive lowered 130 -> 124 on 2026-10-26 when the panel lost its Baseline button); raise them when checks are added, never lower them to hide a skip.

Usage (from anywhere):
  python scripts/lod/run_selftests.py                 all four tests
  python scripts/lod/run_selftests.py adaptive lod    a subset (names: adaptive, multi, lod, grass)
  python scripts/lod/run_selftests.py --negative-test deliberately injects a script error and requires the run to FAIL
Environment: GODOT_CONSOLE overrides the Godot console executable. Logs go to --log-dir (default: <project>/results/selftest_logs).
Exit code 0 only if every requested run passed."""
import argparse
import os
import re
import subprocess
import sys
import time

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_GODOT = r"S:\godot\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"

# name -> (res:// script, log prefix, extra user args, minimum ok checks, text of the last check that must have run)
TESTS = {
    "adaptive": ("res://scripts/lod/adaptive_selftest.gd", "[adaptive-test]", [], 124, "panel: F3 hides it"),
    "multi": ("res://scripts/lod/multi_lod_selftest.gd", "[multi-test]", [], 90, "path: 0 chunk tier changes returned to the previous tier within 12 m (flicker)"),
    "lod": ("res://scripts/lod/lod_selftest.gd", "[selftest]", [], 51, "path: integrity at 500 m"),
    "grass": ("res://scripts/lod/grass_selftest.gd", "[grass-test]", ["--", "skip-determinism"], 17, "hysteresis: the test cell stays at tier 1 while the camera jitters inside the band"),
}

FATAL = re.compile(r"SCRIPT ERROR|Parse Error|USER SCRIPT ERROR|USER ERROR|Debugger Break|Failed to load script|Cannot open file")
# accepted anywhere: hardware/environment noise that is not about the code under test
NOISE_ANYWHERE = [
    re.compile(r"^(ERROR|WARNING): WASAPI"),
    re.compile(r"^WARNING: instance_reset_physics_interpolation\(\) is deprecated"),
]
# accepted only after the final result line: engine shutdown leak reports of a test process that quits with live nodes
SHUTDOWN_ONLY = [
    re.compile(r"^ERROR: \d+ RID allocations of type .* were leaked at exit"),
    re.compile(r"^ERROR: \d+ shaders of type \w+ were never freed"),
    re.compile(r"^ERROR: \d+ resources still in use at exit"),
    re.compile(r"^ERROR: Pages in use exist at exit in PagedAllocator"),
    re.compile(r"^WARNING: \d+ RIDs of type \"\w+\" were leaked"),
    re.compile(r"^WARNING: \d+ ObjectDB instances were leaked at exit"),
]


def validate(lines, exit_code, prefix, min_ok, last_check):
    """Returns a list of problems; empty means the run is clean."""
    problems = []
    if exit_code != 0:
        problems.append("exit code %s (expected 0)" % exit_code)
    results = [i for i, l in enumerate(lines) if l.startswith(prefix + " PASS") or l.startswith(prefix + " FAIL")]
    if len(results) != 1:
        problems.append("expected exactly one result line, found %d" % len(results))
    final = results[-1] if results else None
    if final is not None and not lines[final].startswith(prefix + " PASS (0 failures)"):
        problems.append("result line is not a clean PASS: %s" % lines[final].strip())
    for i, l in enumerate(lines):
        if l.startswith(prefix + " FAIL"):
            problems.append("failed check: %s" % l.strip())
    previous_allowed = False  # the stack line ("   at: ...") that follows an accepted message is accepted with it
    for i, l in enumerate(lines):
        if FATAL.search(l):
            problems.append("script/engine error at log line %d: %s" % (i + 1, l.strip()[:160]))
            previous_allowed = False
            continue
        is_at = l.startswith("   at: ")
        if not (l.startswith("ERROR") or l.startswith("WARNING") or is_at):
            previous_allowed = False
            continue
        if is_at and previous_allowed:
            continue
        if any(p.match(l) for p in NOISE_ANYWHERE):
            previous_allowed = True
            continue
        if final is not None and i > final and any(p.match(l) for p in SHUTDOWN_ONLY):
            previous_allowed = True
            continue
        previous_allowed = False
        problems.append("unexpected engine message at log line %d: %s" % (i + 1, l.strip()[:160]))
    ok_lines = [l for l in lines if l.startswith(prefix + " ok ")]
    if len(ok_lines) < min_ok:
        problems.append("only %d ok checks executed, minimum is %d (a section was skipped or aborted)" % (len(ok_lines), min_ok))
    if not any(last_check in l for l in ok_lines):
        problems.append("required last check never ran: %s" % last_check)
    return problems


def run_one(godot, script, extra, log_path, timeout):
    cmd = [godot, "--path", PROJECT, "--script", script] + extra
    started = time.time()
    try:
        # One merged stream, so the log keeps the real order of events (needed for the "after the result line" rule).
        done = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, cwd=PROJECT)
        out = done.stdout
        code = done.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"") + b"\nTIMEOUT"
        code = "timeout"
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "wb") as f:
        f.write(out)
    return code, out.decode("utf-8", errors="replace").splitlines(), time.time() - started


NEGATIVE_SCRIPT = """extends SceneTree
## Temporary fault-injection test written by run_selftests.py --negative-test; deleted right after the run.
var _failures := 0

func _initialize() -> void:
	await _section_with_error()
	for i in 130:
		print("[negtest] ok   filler check %d" % i)
	print("[negtest] ok   last check")
	print("[negtest] %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _section_with_error() -> void:
	var missing := root.find_child("DoesNotExist", true, false) as Button
	missing.pressed.emit()  # null access: SCRIPT ERROR, aborts this coroutine; the test still reaches PASS
"""


def negative_test(godot, log_dir, timeout):
    rel = "scripts/lod/_runner_negtest.gd"
    path = os.path.join(PROJECT, *rel.split("/"))
    with open(path, "w", newline="\n") as f:
        f.write(NEGATIVE_SCRIPT)
    try:
        code, lines, secs = run_one(godot, "res://" + rel, [], os.path.join(log_dir, "negative_test.log"), timeout)
    finally:
        for leftover in (path, path + ".uid"):
            if os.path.exists(leftover):
                os.remove(leftover)
    says_pass = any(l.startswith("[negtest] PASS (0 failures)") for l in lines)
    problems = validate(lines, code, "[negtest]", 130, "last check")
    print("negative test: the injected test itself printed PASS: %s; exit code %s" % (says_pass, code))
    print("negative test: runner verdict: %s" % ("FAIL (correct)" if problems else "PASS (WRONG: the fault was not detected)"))
    for p in problems[:4]:
        print("   - " + p)
    return bool(problems) and says_pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*", choices=list(TESTS), help="subset of: " + ", ".join(TESTS))
    ap.add_argument("--negative-test", action="store_true")
    ap.add_argument("--log-dir", default=os.path.join(PROJECT, "results", "selftest_logs"))
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    godot = os.environ.get("GODOT_CONSOLE", DEFAULT_GODOT)
    if not os.path.exists(godot):
        print("Godot console executable not found: %s (set GODOT_CONSOLE)" % godot)
        return 2
    if args.negative_test:
        return 0 if negative_test(godot, args.log_dir, args.timeout) else 1
    failed = 0
    for name in (args.tests or list(TESTS)):
        script, prefix, extra, min_ok, last = TESTS[name]
        code, lines, secs = run_one(godot, script, extra, os.path.join(args.log_dir, "%s.log" % name), args.timeout)
        problems = validate(lines, code, prefix, min_ok, last)
        ok = sum(1 for l in lines if l.startswith(prefix + " ok "))
        print("%-9s %s  (%d ok checks, exit %s, %.0f s)" % (name, "PASS" if not problems else "FAIL", ok, code, secs))
        for p in problems:
            print("    - " + p)
        failed += bool(problems)
    print("RESULT: %s" % ("all clean" if not failed else "%d run(s) FAILED" % failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
