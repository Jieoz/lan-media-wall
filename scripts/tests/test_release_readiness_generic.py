#!/usr/bin/env python3
import json, subprocess, sys, tempfile, zipfile
from pathlib import Path
SCRIPT = Path(__file__).resolve().parents[1] / "release_readiness_review.py"

def run(repo, cfg):
    p = subprocess.run([sys.executable, str(SCRIPT), str(repo), "--config", str(cfg), "--json"], capture_output=True, text=True)
    return p.returncode, json.loads(p.stdout)

with tempfile.TemporaryDirectory() as td:
    repo = Path(td)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    (repo / "ok.py").write_text("print('ok')\n")
    (repo / "bad.py").write_text("raise SystemExit(7)\n")
    cfg = repo / "cfg.json"
    cfg.write_text(json.dumps({"command_gates": [{"name": "policy", "run": [sys.executable, "ok.py"]}], "archive_contracts": [{"path": "bundle.zip", "required_entries": ["tool", "README.md"]}]}))
    with zipfile.ZipFile(repo / "bundle.zip", "w") as zf:
        zf.writestr("tool", "x")
    rc, data = run(repo, cfg)
    assert rc == 1 and any("README.md" in item for gate in data["gates"] for item in gate["details"])
    with zipfile.ZipFile(repo / "bundle.zip", "a") as zf:
        zf.writestr("README.md", "x")
    assert run(repo, cfg)[0] == 0
    cfg.write_text(json.dumps({"command_gates": [{"name": "policy", "run": [sys.executable, "bad.py"]}]}))
    rc, data = run(repo, cfg)
    assert rc == 1 and any(gate["name"] == "COMMANDS" and not gate["ok"] for gate in data["gates"])
    cfg.write_text("{")
    rc, data = run(repo, cfg)
    assert rc == 1 and any(gate["name"] == "CONFIG" and not gate["ok"] for gate in data["gates"])
print("GENERIC_RELEASE_GATES_PASS")
