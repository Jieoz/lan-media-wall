#!/usr/bin/env python3
"""release_readiness_review.py — mechanical, from-scratch cross-component
pre-release audit. The point: STOP shipping code that doesn't run.

Jay's redline (2026-07, 多次踩): never publish/deploy code that doesn't actually
build & run; never patch atop broken code ("屎上雕花") making the project complex
and still broken. Before ANY release/deploy, run this from-scratch review across
all components. It's mechanical (no LLM) so it can't be hand-waved.

It does NOT replace green cloud CI (compiled/multi-platform targets MUST build in
CI, not locally on ARM). It's the cheap gate that catches the dumb stuff BEFORE
you spend a CI run and BEFORE you tag a release: dangling references, unwired
handlers, cross-end contract drift, syntax errors, uncommitted/half-done work.

Usage:
  release_readiness_review.py <repo_path> [--json] [--config <yaml>]

Exit 0 = all mechanical gates pass (still requires green CI before release).
Exit 1 = at least one gate FAILED — DO NOT release; fix or redispatch to cc.

Checks (each component type contributes gates; config can extend/override):
  PYTHON   — py_compile every .py; optional pytest suites (report pass counts)
  KOTLIN   — every R.id.X / R.layout.X / R.string.X referenced in .kt exists in res/;
             flag "defined-but-never-called" for methods the review config names
             as required-wired (e.g. showImage/onVideoEnded must be invoked, not just declared)
  DART     — `dart analyze` if available; else grep for obvious unresolved symbols
  CONTRACT — cross-end field-name consistency: given a list of protocol keys,
             ensure the same spelling is used across the named files (catches the
             km-vs-key_mode class of drift)
  GIT      — worktree state summary (clean? ahead of origin? — informational)

Config (optional YAML at <repo>/.release-review.yml or via --config):
  python_dirs: [broker, windows_player]
  pytest_suites: [["broker/tests"], ["windows_player/tests"], ["broker/tests","windows_player/tests"]]
  kotlin_src: android_apps/player/app/src/main/kotlin
  android_res: android_apps/player/app/src/main/res
  required_wired:            # symbol must be CALLED somewhere, not just defined
    - {symbol: showImage, defined_in: "**/PlayerController.kt", called_in: "**/PlayerService.kt"}
    - {symbol: onVideoEnded, defined_in: "**/PlayerController.kt", called_in: "**/PlayerService.kt"}
  dart_dirs: [remote_flutter]
  contract_keys:            # each key must be spelled identically across files
    - {key: key_mode, files: ["broker/router.py","windows_player/main.py","remote_flutter/lib/protocol/messages.dart"]}

With no config, runs the auto-detected gates (py_compile on *.py, dart analyze,
R.id existence) — still useful, just less targeted.
"""
import argparse, glob, json, os, re, subprocess, sys

def sh(cmd, cwd=None, timeout=300):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:
        return 999, "", str(e)

def load_cfg(repo, cfgpath):
    path = cfgpath or os.path.join(repo, ".release-review.yml")
    if not os.path.exists(path):
        return {}
    try:
        import yaml
        return yaml.safe_load(open(path)) or {}
    except Exception as e:
        return {"_cfg_error": str(e)}

class Gate:
    def __init__(self, name):
        self.name = name; self.ok = True; self.details = []
    def fail(self, msg): self.ok = False; self.details.append("FAIL " + msg)
    def note(self, msg): self.details.append(msg)

def gate_python(repo, cfg):
    g = Gate("PYTHON")
    dirs = cfg.get("python_dirs") or []
    pyfiles = []
    if dirs:
        for d in dirs:
            pyfiles += glob.glob(os.path.join(repo, d, "*.py"))
    else:
        pyfiles = glob.glob(os.path.join(repo, "**", "*.py"), recursive=True)
    if pyfiles:
        rc, out, err = sh([sys.executable, "-m", "py_compile", *pyfiles], cwd=repo)
        if rc != 0: g.fail("py_compile: " + (err or out)[:400])
        else: g.note(f"py_compile OK ({len(pyfiles)} files)")
    pytest_cmd = [sys.executable, "-m", "pytest"]
    if sh([sys.executable, "-c", "import pytest"], cwd=repo)[0] != 0:
        if sh(["which", "uv"])[0] != 0:
            g.fail("pytest is unavailable and uv is not installed")
            return g
        pytest_cmd = ["uv", "run", "--with", "pytest", "--with", "websockets",
                      "--with", "pyyaml", "--with", "pillow", "python", "-m", "pytest"]
    for suite in cfg.get("pytest_suites") or []:
        rc, out, err = sh([*pytest_cmd, *suite, "-q"], cwd=repo)
        tail = (out + err).strip().splitlines()[-1:] or [""]
        if rc != 0: g.fail(f"pytest {' '.join(suite)}: {tail[0]}")
        else: g.note(f"pytest {' '.join(suite)}: {tail[0]}")
    return g

def gate_kotlin(repo, cfg):
    g = Gate("KOTLIN")
    src = cfg.get("kotlin_src"); res = cfg.get("android_res")
    if not src:
        found = glob.glob(os.path.join(repo, "**", "src", "main", "kotlin"), recursive=True)
        src = os.path.relpath(found[0], repo) if found else None
    if not src or not os.path.isdir(os.path.join(repo, src)):
        return None
    kt = glob.glob(os.path.join(repo, src, "**", "*.kt"), recursive=True)
    # collect R.<type>.<name> references and check they exist in res/ (id/layout/string/drawable)
    refs = set()
    for f in kt:
        for m in re.finditer(r"R\.(id|layout|string|drawable)\.([A-Za-z0-9_]+)", open(f, errors="replace").read()):
            refs.add((m.group(1), m.group(2)))
    if res and refs:
        resroot = os.path.join(repo, res)
        # build a text blob of all res xml + values for name lookup
        blob = ""
        for x in glob.glob(os.path.join(resroot, "**", "*.xml"), recursive=True):
            blob += open(x, errors="replace").read()
        layouts = {os.path.splitext(os.path.basename(p))[0]
                   for p in glob.glob(os.path.join(resroot, "layout*", "*.xml"))}
        drawables = {os.path.splitext(os.path.basename(p))[0]
                     for p in glob.glob(os.path.join(resroot, "drawable*", "*"))}
        missing = []
        for typ, name in sorted(refs):
            if typ == "id" and (f'@+id/{name}' not in blob and f'@id/{name}' not in blob):
                missing.append(f"R.id.{name}")
            elif typ == "layout" and name not in layouts:
                missing.append(f"R.layout.{name}")
            elif typ == "string" and f'name="{name}"' not in blob:
                missing.append(f"R.string.{name}")
            elif typ == "drawable" and (name not in drawables and f'@+id/{name}' not in blob and f'name="{name}"' not in blob):
                missing.append(f"R.drawable.{name}")
        if missing: g.fail("dangling res refs: " + ", ".join(missing[:15]))
        else: g.note(f"R.* refs resolve ({len(refs)} checked)")
    # required-wired: symbol must be CALLED (not just declared)
    for rw in cfg.get("required_wired") or []:
        sym = rw["symbol"]
        called_glob = os.path.join(repo, rw.get("called_in", ""))
        callers = glob.glob(called_glob, recursive=True) if rw.get("called_in") else kt
        called = any(re.search(rf"\b{re.escape(sym)}\s*\(|\.{re.escape(sym)}\b|{re.escape(sym)}\s*=",
                                open(c, errors="replace").read()) for c in callers)
        # crude but effective: is it referenced anywhere OTHER than its own declaration line?
        decl_glob = rw.get("defined_in", "")
        decl_files = glob.glob(os.path.join(repo, decl_glob), recursive=True) if decl_glob else []
        ref_count = 0
        for c in callers:
            txt = open(c, errors="replace").read()
            ref_count += len(re.findall(rf"{re.escape(sym)}", txt))
        if not called or ref_count == 0:
            g.fail(f"'{sym}' defined but NOT wired (never called in {rw.get('called_in','callers')})")
        else:
            g.note(f"'{sym}' wired ({ref_count} refs in callers)")
    return g

def gate_dart(repo, cfg):
    dirs = cfg.get("dart_dirs") or []
    if not dirs:
        found = glob.glob(os.path.join(repo, "**", "pubspec.yaml"), recursive=True)
        dirs = [os.path.relpath(os.path.dirname(p), repo) for p in found]
    if not dirs: return None
    g = Gate("DART")
    have = sh(["which", "dart"])[0] == 0
    for d in dirs:
        if have:
            rc, out, err = sh(["dart", "analyze", "--no-fatal-infos"], cwd=os.path.join(repo, d), timeout=180)
            errlines = [l for l in (out + err).splitlines() if " error " in l or l.strip().startswith("error")]
            if errlines: g.fail(f"dart analyze {d}: {len(errlines)} errors; e.g. {errlines[0][:200]}")
            else: g.note(f"dart analyze {d}: clean")
        else:
            g.note(f"dart not installed — skipped analyze of {d} (CI must cover it)")
    return g

def gate_contract(repo, cfg):
    keys = cfg.get("contract_keys") or []
    if not keys: return None
    g = Gate("CONTRACT")
    for spec in keys:
        key = spec["key"]; files = spec.get("files", [])
        present, absent = [], []
        for rel in files:
            p = os.path.join(repo, rel)
            if os.path.exists(p) and key in open(p, errors="replace").read():
                present.append(rel)
            else:
                absent.append(rel)
        if absent and present:
            g.fail(f"key '{key}' spelled/present in {present} but MISSING in {absent} (cross-end drift?)")
        else:
            g.note(f"key '{key}' consistent across {len(present)} files")
    return g

def gate_git(repo):
    g = Gate("GIT")
    rc, out, _ = sh(["git", "status", "--short"], cwd=repo)
    dirty = [l for l in out.splitlines() if l.strip()]
    g.note(f"worktree: {'clean' if not dirty else str(len(dirty))+' uncommitted files'}")
    rc, out, _ = sh(["git", "rev-list", "--count", "origin/main..HEAD"], cwd=repo)
    if rc == 0: g.note(f"local ahead of origin/main by {out.strip()} commits")
    return g

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--config", default="")
    args = ap.parse_args()
    repo = os.path.abspath(args.repo)
    if not os.path.isdir(repo):
        print(f"ERROR repo not found: {repo}"); sys.exit(2)
    cfg = load_cfg(repo, args.config)
    gates = []
    for fn in (lambda: gate_python(repo, cfg),
               lambda: gate_kotlin(repo, cfg),
               lambda: gate_dart(repo, cfg),
               lambda: gate_contract(repo, cfg),
               lambda: gate_git(repo)):
        g = fn()
        if g is not None: gates.append(g)
    overall_ok = all(g.ok for g in gates)
    if args.json:
        print(json.dumps({"repo": repo, "ok": overall_ok,
                          "gates": [{"name": g.name, "ok": g.ok, "details": g.details} for g in gates]},
                         ensure_ascii=False, indent=2))
    else:
        print(f"=== RELEASE-READINESS REVIEW: {repo} ===")
        if cfg.get("_cfg_error"): print(f"[cfg warning] {cfg['_cfg_error']}")
        for g in gates:
            mark = "PASS" if g.ok else "FAIL"
            print(f"\n[{mark}] {g.name}")
            for d in g.details: print(f"    {d}")
        print(f"\n=== OVERALL: {'PASS (still需 green CI 才能发布)' if overall_ok else 'FAIL — DO NOT RELEASE'} ===")
    sys.exit(0 if overall_ok else 1)

if __name__ == "__main__":
    main()
