#!/usr/bin/env python3
"""Convert local documents into a private, single-writer Markdown cache."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

IS_WINDOWS = os.name == "nt"
EXE = ".exe" if IS_WINDOWS else ""


def _known_locations() -> dict[str, list[str]]:
    """环境变量优先，其次是各平台的官方默认安装位置（不含任何个人目录）。"""
    known: dict[str, list[str]] = {"pdftotext": [], "pdfinfo": [], "soffice": []}
    poppler_bin = os.environ.get("TO_MD_POPPLER_BIN")
    if poppler_bin:
        known["pdftotext"].append(os.path.join(poppler_bin, "pdftotext" + EXE))
        known["pdfinfo"].append(os.path.join(poppler_bin, "pdfinfo" + EXE))
    soffice_env = os.environ.get("TO_MD_SOFFICE")
    if soffice_env:
        known["soffice"].append(soffice_env)
    if IS_WINDOWS:
        known["soffice"].append(r"C:\Program Files\LibreOffice\program\soffice.exe")
    elif sys.platform == "darwin":
        known["soffice"].append("/Applications/LibreOffice.app/Contents/MacOS/soffice")
    return known


KNOWN = _known_locations()

MARKITDOWN_EXT = {".docx", ".pptx", ".xlsx", ".xls", ".html", ".htm", ".csv", ".json", ".xml", ".epub"}
LEGACY_EXT = {".doc": "docx", ".rtf": "docx", ".odt": "docx",
              ".ppt": "pptx", ".odp": "pptx", ".ods": "xlsx"}
COPY_EXT = {".txt", ".md"}
PDF_EXT = {".pdf"}
ALL_EXT = MARKITDOWN_EXT | set(LEGACY_EXT) | COPY_EXT | PDF_EXT


def find_tool(name: str) -> str | None:
    p = shutil.which(name)
    if p:
        return str(safe_path(Path(p)))
    for c in KNOWN.get(name, []):
        if os.path.isfile(c):
            return str(safe_path(Path(c)))
    return None


def sha256_file(path: Path, bufsize: int = 8 * 1024 * 1024) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(bufsize)
            if not b:
                break
            h.update(b)
    return h.hexdigest().upper()


def safe_path(path: Path) -> Path:
    if ".." in path.parts:
        raise ValueError("PARENT_SEGMENT")
    absolute = Path(os.path.abspath(path))
    if IS_WINDOWS and (absolute.drive.startswith("\\\\") or ":" in str(absolute)[2:]):
        raise ValueError("NONLOCAL_PATH")
    for candidate in (*reversed(absolute.parents), absolute):
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ValueError("LINK_OR_REPARSE_POINT")
    return absolute


def path_key(src: Path) -> str:
    return hashlib.sha256(os.fsencode(str(safe_path(src)))).hexdigest()


def atomic_write_text(path: Path, text: str) -> None:
    path = safe_path(path)
    fd, temporary = tempfile.mkstemp(prefix=".fortress-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, safe_path(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def single_writer(root: Path):
    lock = safe_path(root / ".conversion.lock")
    if lock.exists() and not lock.is_file():
        raise ValueError("INVALID_LOCK_TYPE")
    with lock.open("a+b") as stream:
        stream.seek(0)
        if IS_WINDOWS:
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def run_cmd(cmd: list[str], timeout: int = 300) -> bytes:
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("CONVERTER_EXIT_NONZERO")
    return r.stdout


def pdf_to_md(src: Path) -> tuple[str, dict]:
    pdftotext = find_tool("pdftotext")
    pdfinfo = find_tool("pdfinfo")
    if not pdftotext:
        raise RuntimeError("找不到 pdftotext（需要安装 poppler）")
    pages = None
    if pdfinfo:
        info = run_cmd([pdfinfo, str(src)], timeout=60).decode("utf-8", "replace")
        for line in info.splitlines():
            if line.startswith("Pages:"):
                pages = int(line.split(":", 1)[1].strip())
    raw = run_cmd([pdftotext, "-enc", "UTF-8", "-layout", str(src), "-"], timeout=300).decode("utf-8", "replace")
    parts = raw.split("\f")
    if parts and not parts[-1].strip():
        parts = parts[:-1]
    out, empty = [], []
    for i, t in enumerate(parts, 1):
        if not t.strip():
            empty.append(i)
        out.append(f"<!-- page {i} -->\n{t.rstrip()}\n")
    meta = {"pages": pages, "pages_extracted": len(parts), "empty_pages": empty, "tool": "pdftotext -layout"}
    if pages is not None and pages != len(parts):
        meta["warning"] = f"pdfinfo 页数 {pages} 与提取页数 {len(parts)} 不一致"
    if pages and len(empty) > pages * 0.5:
        meta["warning"] = (meta.get("warning", "") + " 超过一半页面无文字，疑似扫描件，需要 OCR").strip()
    return "\n".join(out), meta


_md = None


def markitdown_convert(src: Path) -> tuple[str, dict]:
    global _md
    if _md is None:
        try:
            from markitdown import MarkItDown
        except ImportError as e:
            raise RuntimeError("未安装 markitdown：pip install \"markitdown[all]\"") from e
        _md = MarkItDown(enable_plugins=False)
    res = _md.convert(str(src))
    text = getattr(res, "text_content", None) or getattr(res, "markdown", None) or str(res)
    return text, {"tool": "markitdown"}


def legacy_to_md(src: Path, target_ext: str) -> tuple[str, dict]:
    soffice = find_tool("soffice")
    if not soffice:
        raise RuntimeError("找不到 soffice（需要安装 LibreOffice）")
    with tempfile.TemporaryDirectory(prefix="to_md_lo_") as td:
        profile_dir = Path(td) / "profile"
        out_dir = Path(td) / "out"
        out_dir.mkdir(parents=True, exist_ok=True)
        run_cmd([
            soffice, "--headless", "--norestore", "--nolockcheck",
            f"-env:UserInstallation={profile_dir.as_uri()}",
            "--convert-to", target_ext, "--outdir", str(out_dir), str(src)
        ], timeout=300)
        converted = list(out_dir.glob(f"*.{target_ext}"))
        if not converted:
            raise RuntimeError(f"LibreOffice 未生成 .{target_ext} 文件")
        text, meta = markitdown_convert(converted[0])
        meta["tool"] = f"libreoffice->{target_ext}+markitdown"
        return text, meta


def convert_one(src: Path) -> tuple[str, dict]:
    ext = src.suffix.lower()
    if ext in PDF_EXT:
        return pdf_to_md(src)
    if ext in MARKITDOWN_EXT:
        return markitdown_convert(src)
    if ext in LEGACY_EXT:
        return legacy_to_md(src, LEGACY_EXT[ext])
    if ext in COPY_EXT:
        return src.read_text(encoding="utf-8", errors="replace"), {"tool": "copy"}
    raise RuntimeError(f"不支持的扩展名: {ext}")


def load_manifest(manifest_path: Path) -> dict[str, dict]:
    cache: dict[str, dict] = {}
    manifest_path = safe_path(manifest_path)
    if not manifest_path.exists():
        return cache
    if not manifest_path.is_file():
        raise ValueError("INVALID_MANIFEST_TYPE")
    with manifest_path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                rec = json.loads(line)
                key = rec["cache_key"]
                if rec.get("format_version") != 2 or not valid_digest(key):
                    continue
                if rec.get("status") == "ok" and valid_digest(rec.get("src_sha256")) and valid_digest(rec.get("out_sha256")):
                    cache[key] = {field: rec[field] for field in ("format_version", "cache_key", "status", "src_sha256", "out_sha256")}
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
    return cache


def valid_digest(value) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(ch in "0123456789abcdefABCDEF" for ch in value)


def save_manifest(manifest_path: Path, cache: dict[str, dict]) -> None:
    body = "".join(json.dumps(value, ensure_ascii=False) + "\n" for _, value in sorted(cache.items()))
    atomic_write_text(manifest_path, body)


def collect_inputs(inputs: list[str], out_root: Path) -> list[Path]:
    found: dict[str, Path] = {}
    def walk_error(error):
        raise error

    for raw in inputs:
        path = safe_path(Path(raw))
        if path == out_root or out_root in path.parents:
            raise ValueError("INPUT_INSIDE_OUTPUT_ROOT")
        if path.is_file() and path.suffix.lower() in ALL_EXT:
            found[path_key(path)] = path
        elif path.is_dir():
            for current, subdirs, files in os.walk(path, followlinks=False, onerror=walk_error):
                base = safe_path(Path(current))
                allowed = []
                for name in sorted(subdirs):
                    candidate = base / name
                    if candidate == out_root or name == ".git":
                        continue
                    safe_path(candidate)
                    allowed.append(name)
                subdirs[:] = allowed
                for name in sorted(files):
                    candidate = base / name
                    if candidate.suffix.lower() not in ALL_EXT:
                        continue
                    safe_path(candidate)
                    if not candidate.is_file():
                        raise ValueError("INPUT_NOT_REGULAR_FILE")
                    found[path_key(candidate)] = candidate
        else:
            raise ValueError("MISSING_OR_UNSUPPORTED_INPUT")
    return list(found.values())


def check_deps(paths: list[Path]) -> None:
    """按本次输入实际涉及的格式检查依赖，每种缺失只提示一次（不中止，缺依赖的文件会记为 error）。"""
    exts = {src.suffix.lower() for src in paths}
    hints: list[str] = []
    if exts & PDF_EXT and not find_tool("pdftotext"):
        hints.append("PDF 需要 poppler 的 pdftotext：加入 PATH，或设置 TO_MD_POPPLER_BIN=<poppler bin 目录>")
    if exts & (MARKITDOWN_EXT | set(LEGACY_EXT)):
        try:
            import markitdown  # noqa: F401
        except ImportError:
            hints.append('Office/HTML 等格式需要 markitdown：pip install "markitdown[all]"')
    if exts & set(LEGACY_EXT) and not find_tool("soffice"):
        hints.append("旧版 Office/ODF 格式需要 LibreOffice：加入 PATH，或设置 TO_MD_SOFFICE=<soffice 完整路径>")
    for h in hints:
        print(f"[DEPS] {h}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description="将大文档本地转为 Markdown（带防串档缓存与原子清单）")
    ap.add_argument("inputs", nargs="+", help="源文件或目录")
    ap.add_argument("--out", default="artifacts/md", help="输出目录（默认 artifacts/md）")
    ap.add_argument("--force", action="store_true", help="忽略缓存强制重转")
    args = ap.parse_args()

    try:
        out_root = safe_path(Path(args.out))
        sources = collect_inputs(args.inputs, out_root)
        if not sources:
            print("[ERR] NO_INPUTS", file=sys.stderr)
            return 2
        out_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        check_deps(sources)
        with single_writer(out_root):
            manifest_path = out_root / "manifest.jsonl"
            cache = load_manifest(manifest_path)
            errors = 0
            for index, src in enumerate(sources, 1):
                outcome = process_one(src, out_root, cache, args.force)
                print(f"INPUT_{index}: {outcome}")
                if outcome != "CACHED":
                    save_manifest(manifest_path, cache)
                errors += outcome == "FAILED"
            return int(errors > 0)
    except KeyboardInterrupt:
        return 130
    except (RuntimeError, OSError, ValueError):
        print("[ERR] UNSAFE_INPUT_OR_OUTPUT_OR_WRITER_UNAVAILABLE", file=sys.stderr)
        return 2


def process_one(src: Path, out_root: Path, cache: dict[str, dict], force: bool) -> str:
    key = path_key(src)
    try:
        out_path = safe_path(out_root / f"{key}{src.suffix.lower()}.md")
        if out_path.parent != out_root:
            raise ValueError("OUTPUT_ESCAPE")
        src_hash = sha256_file(safe_path(src))
        prev = cache.get(key, {})
        if (not force and prev.get("status") == "ok" and prev.get("src_sha256") == src_hash
                and out_path.is_file() and sha256_file(out_path) == prev.get("out_sha256")):
            return "CACHED"
        text, metadata = convert_one(safe_path(src))
        if sha256_file(safe_path(src)) != src_hash:
            raise ValueError("INPUT_CHANGED")
        atomic_write_text(out_path, text)
        cache[key] = {"format_version": 2, "cache_key": key, "status": "ok", "src_sha256": src_hash,
                      "out_sha256": sha256_file(out_path)}
        return "CONVERTED_REVIEW_REQUIRED" if metadata.get("warning") else "CONVERTED"
    except Exception:
        cache[key] = {"format_version": 2, "cache_key": key, "status": "error"}
        return "FAILED"


if __name__ == "__main__":
    sys.exit(main())
