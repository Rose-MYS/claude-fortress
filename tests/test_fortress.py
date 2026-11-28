"""Cross-platform stdlib regression tests for claude-fortress (zero third-party deps)."""
import json
import os
import pathlib
import py_compile
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
ASSETS = ROOT / "assets"
REFS = ROOT / "references"
IS_WINDOWS = os.name == "nt"


class TestStaticIntegrity(unittest.TestCase):
    def test_all_json_files_valid(self):
        json_files = sorted(ROOT.rglob("*.json"))
        self.assertGreaterEqual(len(json_files), 6)
        for path in json_files:
            with self.subTest(file=str(path.relative_to(ROOT))):
                json.loads(path.read_text(encoding="utf-8"))

    def test_all_python_files_compile(self):
        py_files = sorted(SCRIPTS.glob("*.py"))
        self.assertGreaterEqual(len(py_files), 2)
        for path in py_files:
            with self.subTest(file=path.name):
                py_compile.compile(str(path), doraise=True)

    def test_node_esm_syntax(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node not installed")
        for path in sorted(SCRIPTS.glob("*.mjs")):
            with self.subTest(file=path.name):
                res = subprocess.run([node, "--check", str(path)], capture_output=True, text=True)
                self.assertEqual(res.returncode, 0, res.stderr)

    def test_shell_scripts_posix_syntax(self):
        sh = shutil.which("sh")
        if not sh or IS_WINDOWS:
            self.skipTest("POSIX sh syntax check runs on Linux/macOS")
        for path in sorted(SCRIPTS.glob("*.sh")) + sorted(ASSETS.glob("*.init")):
            with self.subTest(file=path.name):
                res = subprocess.run([sh, "-n", str(path)], capture_output=True, text=True)
                self.assertEqual(res.returncode, 0, res.stderr)

    def test_powershell_ast_syntax(self):
        ps = shutil.which("powershell") or shutil.which("pwsh")
        if not ps:
            self.skipTest("PowerShell not installed")
        cmd = (
            "$errs = @(); "
            f"Get-ChildItem -LiteralPath '{SCRIPTS}' -Filter '*.ps1' | ForEach-Object {{ "
            "$t=$null; $e=$null; "
            "[void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e); "
            "if ($e.Count) { $errs += \"$($_.Name): $($e.Count)\" } "
            "}; if ($errs.Count) { Write-Error ($errs -join '; '); exit 1 }"
        )
        res = subprocess.run([ps, "-NoProfile", "-NonInteractive", "-Command", cmd], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_markdown_relative_links_exist(self):
        link_re = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
        broken = []
        total = 0
        for path in sorted(ROOT.rglob("*.md")):
            text = path.read_text(encoding="utf-8")
            for match in link_re.finditer(text):
                target = match.group(1).strip().split()[0]
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                rel_part = target.split("#")[0]
                if not rel_part:
                    continue
                total += 1
                if not (path.parent / rel_part).resolve().exists():
                    broken.append((str(path.relative_to(ROOT)), target))
        self.assertGreater(total, 50)
        self.assertEqual(broken, [], f"Broken local links: {broken}")

    def test_references_en_zh_parity(self):
        zh = {p.name for p in REFS.glob("*.md")}
        en = {p.name for p in (REFS / "en").glob("*.md")}
        self.assertEqual(zh, en, f"Parity diff: {sorted(zh ^ en)}")

    def test_zero_pii_and_secrets(self):
        patterns = {
            "email": re.compile(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"),
            "secret": re.compile(r"(?:sk-ant-|ghp_|gho_|AIza[0-9A-Za-z\-_]{20,}|AKIA[0-9A-Z]{16})"),
            "personal_path": re.compile(r"(?:[A-Za-z]:\\Users\\(?!<)|D:\\Claude|/Users/(?!<)[a-zA-Z0-9_-]+)"),
        }
        leaks = []
        for path in sorted(ROOT.rglob("*")):
            if not path.is_file() or ".git" in path.parts or "__pycache__" in path.parts:
                continue
            if path.name == "test_fortress.py":
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for kind, pat in patterns.items():
                hits = pat.findall(text)
                if hits:
                    leaks.append((kind, str(path.relative_to(ROOT)), hits[:3]))
        self.assertEqual(leaks, [], f"Potential PII/secret leaks: {leaks}")


class TestOfflineFailClosedAndTooling(unittest.TestCase):
    def test_to_md_convert_cache_force_and_security(self):
        to_md = SCRIPTS / "to_md.py"
        with tempfile.TemporaryDirectory(prefix="cf_test_tomd_") as td:
            lab = pathlib.Path(td)
            src = lab / "src"
            out = lab / "out"
            src.mkdir()
            (src / "sample.txt").write_text("Hello Claude Fortress\n", encoding="utf-8")

            r1 = subprocess.run([sys.executable, str(to_md), str(src), "--out", str(out)], capture_output=True, text=True)
            self.assertEqual(r1.returncode, 0, r1.stderr)
            self.assertIn("CONVERTED", r1.stdout)

            r2 = subprocess.run([sys.executable, str(to_md), str(src), "--out", str(out)], capture_output=True, text=True)
            self.assertEqual(r2.returncode, 0, r2.stderr)
            self.assertIn("CACHED", r2.stdout)

            r3 = subprocess.run([sys.executable, str(to_md), str(src), "--out", str(out), "--force"], capture_output=True, text=True)
            self.assertEqual(r3.returncode, 0, r3.stderr)
            self.assertIn("CONVERTED", r3.stdout)

            # Reject input inside --out
            r_in_out = subprocess.run([sys.executable, str(to_md), str(out), "--out", str(out)], capture_output=True, text=True)
            self.assertEqual(r_in_out.returncode, 2)

            # Reject parent traversal
            r_trav = subprocess.run([sys.executable, str(to_md), str(src / ".." / "src"), "--out", str(out)], capture_output=True, text=True)
            self.assertEqual(r_trav.returncode, 2)

    @unittest.skipUnless(IS_WINDOWS, "Windows-only Route A1 & B script tests")
    def test_route_a1_launcher_rejects_unavailable_proxy(self):
        res = subprocess.run(
            [sys.executable, str(SCRIPTS / "route-a1-browser-launcher.py"),
             str(ASSETS / "route-a1-nodes.example.json"), "taipei"],
            capture_output=True, text=True,
        )
        self.assertEqual(res.returncode, 2)
        self.assertIn("REFUSED:", res.stderr)

    @unittest.skipUnless(IS_WINDOWS, "Windows-only GPO & collaboration script tests")
    def test_route_b_gpo_setup_rejects_placeholder_config(self):
        res = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(SCRIPTS / "guest-gpo-setup.ps1"),
             "-ConfigPath", str(ASSETS / "route-b-config.example.json"), "-Mode", "DryRun"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(res.returncode, 0)

    @unittest.skipUnless(IS_WINDOWS, "Windows-only collaboration script tests")
    def test_scaffold_and_check_handoff_roundtrip(self):
        git_exe = shutil.which("git")
        self.assertIsNotNone(git_exe)
        with tempfile.TemporaryDirectory(prefix="cf_test_collab_") as td:
            share = pathlib.Path(td)
            job = share / "projects" / "20261128-测试作业"
            job.mkdir(parents=True)

            r_scaf = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                 "-File", str(SCRIPTS / "scaffold-projects.ps1"),
                 "-ShareRoot", str(share), "-InitGit", "-GitExe", git_exe],
                capture_output=True, text=True,
            )
            self.assertEqual(r_scaf.returncode, 0, r_scaf.stderr)

            # Unfilled template must fail
            r_tpl = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                 "-File", str(SCRIPTS / "check-handoff.ps1"), "-ShareRoot", str(share), "-Strict"],
                capture_output=True, text=True,
            )
            self.assertEqual(r_tpl.returncode, 1)

            # Valid 7-section handoff must pass
            valid = (
                "# 测试\n\n## 一句话\n测试。\n\n## 当前状态\n进行中。\n\n## 先读什么\n本文件。\n\n"
                "## 怎么运行 / 复现\n无。\n\n## 待办与未决\n无。\n\n## 注意事项\n无。\n\n## 变更记录\n2026-11-28。\n"
            )
            (job / "交接文档.md").write_text(valid, encoding="utf-8")
            r_ok = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                 "-File", str(SCRIPTS / "check-handoff.ps1"), "-ShareRoot", str(share), "-Strict"],
                capture_output=True, text=True,
            )
            self.assertEqual(r_ok.returncode, 0, r_ok.stdout + r_ok.stderr)

    def test_host_dispatch_mcp_and_guardrails(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node not installed")
        with tempfile.TemporaryDirectory(prefix="cf_test_dispatch_") as td:
            share = pathlib.Path(td) / "share"
            outside = pathlib.Path(td) / "outside"
            share.mkdir()
            outside.mkdir()

            disp = subprocess.Popen(
                [node, str(SCRIPTS / "host-dispatcher.mjs"), "--share-root", str(share), "--poll-ms", "200"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            mcp = subprocess.Popen(
                [node, str(SCRIPTS / "guest-host-dispatch-mcp.mjs"), "--share-root", str(share)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                def rpc(req_id, method, params):
                    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}) + "\n")
                    mcp.stdin.flush()
                    return json.loads(mcp.stdout.readline())

                init = rpc(1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "ci", "version": "1.0"}})
                self.assertEqual(init["result"]["serverInfo"]["name"], "host-dispatch")

                tools = rpc(2, "tools/list", {})
                names = {t["name"] for t in tools["result"]["tools"]}
                self.assertTrue({"host_health", "host_dispatch", "host_task_status", "host_list_tasks", "host_cancel_task"}.issubset(names))

                # Wait briefly for dispatcher heartbeat
                import time
                hb_ok = False
                for _ in range(25):
                    h = rpc(3, "tools/call", {"name": "host_health", "arguments": {}})
                    payload = json.loads(h["result"]["content"][0]["text"])
                    if payload.get("online"):
                        hb_ok = True
                        break
                    time.sleep(0.2)
                self.assertTrue(hb_ok, "host-dispatcher heartbeat did not come online")

                # Guardrail: directory escape must be rejected
                esc = rpc(4, "tools/call", {
                    "name": "host_dispatch",
                    "arguments": {"agent": "codex", "cwd": str(outside), "prompt": "hi", "mode": "read-only", "wait": True, "wait_sec": 5},
                })
                esc_res = json.loads(esc["result"]["content"][0]["text"])
                self.assertEqual(esc_res["status"], "rejected")
                self.assertIn("escapes share root", esc_res["error"])

                # Guardrail: unsupported agent rejected at MCP layer
                bad_agent = rpc(5, "tools/call", {
                    "name": "host_dispatch",
                    "arguments": {"agent": "bash", "prompt": "hi"},
                })
                self.assertTrue(bad_agent["result"]["isError"])
            finally:
                for proc in (mcp, disp):
                    for stream in (proc.stdin, proc.stdout, proc.stderr):
                        if stream:
                            try:
                                stream.close()
                            except Exception:
                                pass
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except Exception:
                        proc.kill()


if __name__ == "__main__":
    unittest.main()


def _load_level_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("fortress_level", SCRIPTS / "fortress_level.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestFortressLevels(unittest.TestCase):
    """Fortress Level spec (assets/levels.json) and the host-side reference calculator."""

    @classmethod
    def setUpClass(cls):
        cls.levels = json.loads((ASSETS / "levels.json").read_text(encoding="utf-8"))
        cls.mod = _load_level_module()

    def _profile_checks(self, prof):
        out = {}
        for entries in prof["requires"].values():
            for entry in entries:
                if isinstance(entry, str):
                    out[entry] = None
                else:
                    out[entry["check"]] = entry["when"]
        return out

    def test_levels_json_is_self_consistent(self):
        lv = self.levels
        level_ids = [x["id"] for x in lv["levels"]]
        self.assertEqual(level_ids, ["L0", "L1", "L2", "L3"])
        for cid, c in lv["checks"].items():
            with self.subTest(check=cid):
                self.assertIn(c["tier"], {"A", "B", "C"})
                self.assertTrue((ROOT / c["ref"]).exists(), c["ref"])
        for name, prof in lv["profiles"].items():
            with self.subTest(profile=name):
                keys = list(prof["requires"])
                self.assertEqual(keys, level_ids[: len(keys)], "levels must be contiguous from L0")
                self.assertEqual(prof["max_level"], keys[-1])
                for cid, cond in self._profile_checks(prof).items():
                    self.assertIn(cid, lv["checks"])
                    if cond is not None:
                        self.assertIn(cond, lv["conditions"])

    def _matrix(self, path, header_marker):
        lines = path.read_text(encoding="utf-8").splitlines()
        start = next(i for i, l in enumerate(lines) if l.startswith("|") and header_marker in l)
        rows = []
        for line in lines[start + 2:]:
            if not line.startswith("|"):
                break
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")][1:])
        self.assertEqual(len(rows), 6, f"{path.name}: expected 6 matrix rows")
        return rows

    def test_levels_match_preflight_matrix(self):
        """levels.json must not drift from the S1→S2 applicability matrix in references/01 (ZH and EN)."""
        vocab = {
            "zh": (REFS / "01-route-selection-and-preflight.md", "A1（Web",
                   {"必测": "required", "`not_applicable`": "na", "推荐": "any", "按宿主": "any", "改为应用层": "app"}),
            "en": (REFS / "en" / "01-route-selection-and-preflight.md", "A1 (Web",
                   {"Required": "required", "`not_applicable`": "na", "Recommended": "any", "Per host": "any", "App-level equivalent": "app"}),
        }
        system_drills = {"cold_boot", "reload_failure", "entry_loss", "management_ssh"}
        for lang, (path, marker, words) in vocab.items():
            rows = self._matrix(path, marker)
            for name, prof in self.levels["profiles"].items():
                present = self._profile_checks(prof)
                col = prof["matrix_column"]
                for cid, c in self.levels["checks"].items():
                    if c["matrix_row"] is None:
                        continue
                    cell = rows[c["matrix_row"]][col]
                    kind = next((v for k, v in words.items() if cell.startswith(k)), None)
                    with self.subTest(lang=lang, profile=name, check=cid):
                        self.assertIsNotNone(kind, f"unrecognised matrix cell: {cell}")
                        if kind == "app":
                            expect = cid == "app_fail_closed"
                        elif c["matrix_row"] == 4 and kind == "required":
                            expect = cid in system_drills
                        elif kind == "required":
                            expect = True
                        elif kind == "na":
                            expect = False
                        else:
                            continue
                        self.assertEqual(cid in present, expect, f"matrix says {cell!r}")

    def test_shared_level_vectors(self):
        cases = json.loads((ROOT / "tests" / "fixtures" / "levels" / "cases.json").read_text(encoding="utf-8"))["cases"]
        self.assertGreaterEqual(len(cases), 12)
        for case in cases:
            with self.subTest(case=case["name"]):
                res = self.mod.evaluate(case["evidence"], self.levels, self.mod.parse_utc(case["now"]),
                                        case.get("current_config_sha256"))
                exp = case["expect"]
                self.assertEqual(res["valid"], exp["valid"], res["errors"])
                if not exp["valid"]:
                    self.assertTrue(any(exp["error_contains"] in e for e in res["errors"]), res["errors"])
                    continue
                self.assertEqual(res["level"], exp["level"])
                self.assertEqual(res["attested"], exp["attested"])
                self.assertEqual(res["expired"], exp["expired"])
                if "expires_utc" in exp:
                    self.assertEqual(res["expires_utc"], exp["expires_utc"])
                if "config_changed" in exp:
                    self.assertEqual(res["config_changed"], exp["config_changed"])
                nxt = res["missing_for_next"][0] if res["missing_for_next"] else None
                if exp["next"] is None:
                    self.assertIsNone(nxt)
                else:
                    self.assertEqual({"level": nxt["level"], "check": nxt["check"]}, exp["next"])

    def test_evidence_v3_example_and_cli(self):
        example = ASSETS / "evidence-v3.example.json"
        data = json.loads(example.read_text(encoding="utf-8"))
        self.assertEqual(set(data["checks"]), set(self.levels["checks"]), "example must list every check")
        res = self.mod.evaluate(data, self.levels)
        self.assertTrue(res["valid"], res["errors"])
        self.assertIsNone(res["level"], "the shipped example must not claim any level")
        cli = subprocess.run([sys.executable, str(SCRIPTS / "fortress_level.py"), str(example), "--json"],
                             capture_output=True, text=True)
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertIsNone(json.loads(cli.stdout)["level"])
        with tempfile.TemporaryDirectory() as tmp:
            bad = pathlib.Path(tmp) / "bad.json"
            bad.write_text(json.dumps({**data, "schema_version": 2}), encoding="utf-8")
            cli = subprocess.run([sys.executable, str(SCRIPTS / "fortress_level.py"), str(bad)],
                                 capture_output=True, text=True)
            self.assertEqual(cli.returncode, 2)


class TestEvidenceReportPage(unittest.TestCase):
    """assets/evidence-report.html must embed the current levels.json and agree with fortress_level.py."""

    PAGE = ASSETS / "evidence-report.html"

    def _script(self, script_id):
        text = self.PAGE.read_text(encoding="utf-8")
        m = re.search(r'<script[^>]*id="%s"[^>]*>(.*?)</script>' % re.escape(script_id), text, re.S)
        self.assertIsNotNone(m, f"missing <script id={script_id}>")
        return m.group(1)

    def test_embedded_levels_match_assets(self):
        embedded = json.loads(self._script("levels-data"))
        self.assertEqual(embedded, json.loads((ASSETS / "levels.json").read_text(encoding="utf-8")),
                         "re-embed assets/levels.json into evidence-report.html")

    def test_page_is_offline(self):
        text = self.PAGE.read_text(encoding="utf-8")
        for needle in ("fetch(", "XMLHttpRequest", "WebSocket", "<script src", "<link rel=\"stylesheet\"", "import("):
            self.assertNotIn(needle, text, f"report page must stay offline: found {needle}")

    def test_js_engine_matches_python_on_shared_vectors(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node not installed")
        mod = _load_level_module()
        levels = json.loads((ASSETS / "levels.json").read_text(encoding="utf-8"))
        cases = json.loads((ROOT / "tests" / "fixtures" / "levels" / "cases.json").read_text(encoding="utf-8"))["cases"]
        with tempfile.TemporaryDirectory() as tmp:
            engine = pathlib.Path(tmp) / "engine.js"
            engine.write_text(self._script("fortress-level-engine"), encoding="utf-8")
            runner = pathlib.Path(tmp) / "run.js"
            runner.write_text(
                "const FL = require(process.argv[2]);\n"
                "const fs = require('fs');\n"
                "const levels = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));\n"
                "const cases = JSON.parse(fs.readFileSync(process.argv[4], 'utf8')).cases;\n"
                "const out = cases.map(c => FL.evaluate(c.evidence, levels, FL.parseUtc(c.now).ms,"
                " c.current_config_sha256 === undefined ? null : c.current_config_sha256));\n"
                "process.stdout.write(JSON.stringify(out));\n",
                encoding="utf-8")
            res = subprocess.run([node, str(runner), str(engine), str(ASSETS / "levels.json"),
                                  str(ROOT / "tests" / "fixtures" / "levels" / "cases.json")],
                                 capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(res.returncode, 0, res.stderr)
            js_results = json.loads(res.stdout)
        keys = ("valid", "profile", "level", "max_level", "missing_for_next", "attested", "expires_utc", "expired", "config_changed")
        for case, js in zip(cases, js_results):
            py = mod.evaluate(case["evidence"], levels, mod.parse_utc(case["now"]), case.get("current_config_sha256"))
            with self.subTest(case=case["name"]):
                self.assertEqual({k: js[k] for k in keys}, {k: py[k] for k in keys})
                self.assertEqual(bool(js["errors"]), bool(py["errors"]))
                if not case["expect"]["valid"]:
                    self.assertTrue(any(case["expect"]["error_contains"] in e for e in js["errors"]), js["errors"])


class TestRouteBOfflineCollectors(unittest.TestCase):
    """Route B Tier-A offline collectors emit valid evidence v3 accepted by both Python and JS engines."""

    FX = ROOT / "tests" / "fixtures" / "verify_offline"

    def _assert_v3_and_report_agree(self, data):
        mod = _load_level_module()
        levels = json.loads((ASSETS / "levels.json").read_text(encoding="utf-8"))
        self.assertEqual(data["schema_version"], 3)
        self.assertEqual(data["route"], "B")
        self.assertEqual(data["component"], "system")
        self.assertEqual(set(data["checks"]), set(levels["checks"]))
        py_res = mod.evaluate(data, levels)
        self.assertTrue(py_res["valid"], py_res["errors"])
        self.assertEqual(py_res["profile"], "B")
        self.assertIsNone(py_res["level"], "offline collector alone must never claim a level")

        node = shutil.which("node")
        if node:
            page_text = (ASSETS / "evidence-report.html").read_text(encoding="utf-8")
            m = re.search(r'<script[^>]*id="fortress-level-engine"[^>]*>(.*?)</script>', page_text, re.S)
            self.assertIsNotNone(m)
            with tempfile.TemporaryDirectory() as tmp:
                engine = pathlib.Path(tmp) / "engine.js"
                engine.write_text(m.group(1), encoding="utf-8")
                ev_file = pathlib.Path(tmp) / "ev.json"
                ev_file.write_text(json.dumps(data), encoding="utf-8")
                runner = pathlib.Path(tmp) / "run.js"
                runner.write_text(
                    "const FL = require(process.argv[2]);\n"
                    "const fs = require('fs');\n"
                    "const levels = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));\n"
                    "const ev = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));\n"
                    "process.stdout.write(JSON.stringify(FL.evaluate(ev, levels, Date.now(), null)));\n",
                    encoding="utf-8",
                )
                r = subprocess.run([node, str(runner), str(engine), str(ASSETS / "levels.json"), str(ev_file)],
                                   capture_output=True, text=True, encoding="utf-8")
                self.assertEqual(r.returncode, 0, r.stderr)
                js_res = json.loads(r.stdout)
                self.assertEqual(js_res["valid"], py_res["valid"])
                self.assertEqual(js_res["profile"], py_res["profile"])
                self.assertEqual(js_res["level"], py_res["level"])

    @unittest.skipUnless(IS_WINDOWS, "Windows guest collector runs on PowerShell")
    def test_windows_guest_collector_pass_and_fail_fixtures(self):
        script = SCRIPTS / "verify-offline-route-b-guest.ps1"
        r_pass = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(script), "-FixturePath", str(self.FX / "guest_pass.json")],
            capture_output=True, text=True, encoding="utf-8",
        )
        self.assertEqual(r_pass.returncode, 0, r_pass.stderr)
        d_pass = json.loads(r_pass.stdout)
        self._assert_v3_and_report_agree(d_pass)
        self.assertEqual(d_pass["checks"]["guest_policy"]["status"], "pass")
        self.assertEqual(d_pass["checks"]["second_nic"]["status"], "pass")
        self.assertEqual(d_pass["checks"]["ipv6"]["status"], "unknown")
        self.assertEqual(d_pass["checks"]["app_fail_closed"]["status"], "not_applicable")

        r_fail = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(script), "-FixturePath", str(self.FX / "guest_fail.json")],
            capture_output=True, text=True, encoding="utf-8",
        )
        self.assertEqual(r_fail.returncode, 0, r_fail.stderr)
        d_fail = json.loads(r_fail.stdout)
        self._assert_v3_and_report_agree(d_fail)
        self.assertEqual(d_fail["checks"]["guest_policy"]["status"], "fail")
        self.assertEqual(d_fail["checks"]["second_nic"]["status"], "fail")
        self.assertEqual(d_fail["checks"]["ipv6"]["status"], "fail")

    @unittest.skipIf(IS_WINDOWS, "OpenWrt POSIX sh collector runs on Linux/macOS")
    def test_openwrt_collector_pass_and_fail_fixtures(self):
        script = SCRIPTS / "verify-offline-openwrt.sh"
        r_pass = subprocess.run(
            ["sh", str(script), "--fixture-dir", str(self.FX / "openwrt_pass")],
            capture_output=True, text=True, encoding="utf-8",
        )
        self.assertEqual(r_pass.returncode, 0, r_pass.stderr)
        d_pass = json.loads(r_pass.stdout)
        self._assert_v3_and_report_agree(d_pass)
        self.assertEqual(d_pass["checks"]["ipv6"]["status"], "unknown")
        self.assertEqual(d_pass["checks"]["udp"]["status"], "unknown")
        self.assertEqual(d_pass["checks"]["wan_capture"]["status"], "not_run")
        self.assertEqual(d_pass["checks"]["app_fail_closed"]["status"], "not_applicable")

        r_fail = subprocess.run(
            ["sh", str(script), "--fixture-dir", str(self.FX / "openwrt_fail")],
            capture_output=True, text=True, encoding="utf-8",
        )
        self.assertEqual(r_fail.returncode, 0, r_fail.stderr)
        d_fail = json.loads(r_fail.stdout)
        self._assert_v3_and_report_agree(d_fail)
        self.assertEqual(d_fail["checks"]["ipv6"]["status"], "fail")
        self.assertEqual(d_fail["checks"]["udp"]["status"], "fail")
