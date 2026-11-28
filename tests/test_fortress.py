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


if __name__ == "__main__":
    unittest.main()
