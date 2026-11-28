"""Windows Chromium per-node launcher. Run with Python 3.12 and Node.js."""
import argparse
from contextlib import contextmanager
import ctypes as ct
from ctypes import wintypes as wt
import ipaddress
import json
import msvcrt
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
from urllib.parse import urlsplit

SCRIPT_DIR = Path(__file__).absolute().parent
BROWSERS = {
    "chrome": Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
    "edge": Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
}
NODE = Path(r"C:\Program Files\nodejs\node.exe")
SYSTEM_ROOT = Path(os.environ.get("SystemRoot", r"C:\Windows"))
CURL = SYSTEM_ROOT / "System32" / "curl.exe"
REGIONS = {
    "AU": "en-AU", "CA": "en-CA", "CN": "zh-CN", "DE": "de-DE",
    "FR": "fr-FR", "GB": "en-GB", "HK": "zh-HK", "JP": "ja-JP",
    "KR": "ko-KR", "SG": "en-SG", "TW": "zh-TW", "US": "en-US",
}
LOCAL_HOSTS = {"127.0.0.1", "localhost"}


class JobLimits(ct.Structure):
    _fields_ = [
        ("process_time", ct.c_longlong), ("job_time", ct.c_longlong), ("flags", wt.DWORD),
        ("min_working_set", ct.c_size_t), ("max_working_set", ct.c_size_t),
        ("process_limit", wt.DWORD), ("affinity", ct.c_size_t),
        ("priority", wt.DWORD), ("scheduling", wt.DWORD),
    ]


class ExtendedJobLimits(ct.Structure):
    _fields_ = [
        ("basic", JobLimits), ("io_counters", ct.c_ulonglong * 6),
        ("process_memory", ct.c_size_t), ("job_memory", ct.c_size_t),
        ("peak_process_memory", ct.c_size_t), ("peak_job_memory", ct.c_size_t),
    ]


class GateError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def fields(value, required, optional=()):
    require(isinstance(value, dict), "expected a JSON object")
    require(set(required) <= value.keys() <= set(required) | set(optional),
            "missing or unsupported configuration field")


def safe_path(path, directory=False):
    # Inspect all components before use, including the workspace ancestors.
    for part in (*reversed(path.parents), path):
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        require(not info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT,
                f"reparse point rejected: {part.name}")
        require(part == path or stat.S_ISDIR(info.st_mode), "invalid parent directory")
        if part == path:
            if directory:
                require(stat.S_ISDIR(info.st_mode), "expected a directory")
            else:
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                        "expected a regular file without hard links")
    return path


def raise_error(error):
    raise error


def token(value):
    require(isinstance(value, str) and re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,47}", value),
            "invalid node ID or profile directory name")
    require(not re.fullmatch(r"con|prn|aux|nul|com[0-9]|lpt[0-9]", value),
            "reserved Windows name")
    return value


def ipv4(value):
    require(isinstance(value, str), "IPv4 must be a string")
    try:
        return str(ipaddress.IPv4Address(value))
    except ValueError as exc:
        raise GateError("invalid IPv4") from exc


def endpoint(value, local, *, literal=False):
    require(isinstance(value, str) and value.isascii()
            and not re.search(r"[\x00-\x20\x7f\\]", value), "invalid probe URL")
    url = urlsplit(value)
    host = url.hostname or ""
    require(url.username is None and url.password is None and "#" not in value
            and "?" not in value and host and url.port != 0,
            "probe URLs may not have credentials, query strings or fragments")
    if local:
        require(url.scheme == "http" and
                (host in LOCAL_HOSTS or (not literal and host.endswith(".test"))),
                "local mode requires HTTP on loopback or a reserved .test hostname")
    else:
        require(url.scheme == "https" and host not in LOCAL_HOSTS
                and not host.endswith((".localhost", ".test", ".invalid", ".example"))
                and "." in host, "neutral mode requires a neutral HTTPS hostname")
        require(not any(word in host for word in ("claude", "anthropic")),
                "service endpoints are forbidden")
    return url


def validate(config, permit_neutral):
    fields(config, ("mode", "nodes"), ("browser",))
    mode = config["mode"]
    require(mode in ("local", "neutral"), "mode must be local or neutral")
    local = mode == "local"
    require(local or permit_neutral, "neutral mode requires --allow-neutral")
    browser = config.get("browser", "chrome")
    require(browser in ("chrome", "edge"), "browser must be chrome or edge")
    nodes = config["nodes"]
    require(isinstance(nodes, dict) and nodes, "at least one node is required")
    paths, ports = set(), set()
    for name, node in nodes.items():
        token(name)
        fields(node, ("proxy_port", "expected_ipv4", "locale", "timezone", "dns", "probes"),
               ("profile",))
        profile = token(node.get("profile", name))
        port = node["proxy_port"]
        require(type(port) is int and 1 <= port <= 65535, "invalid HTTP proxy port")
        require(profile not in paths and port not in ports, "duplicate profile or proxy port")
        paths.add(profile)
        ports.add(port)
        ipv4(node["expected_ipv4"])
        require(node["dns"] == "remote", "dns must be remote")
        for key, pattern in (
            ("locale", r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{2,8})+"),
            ("timezone", r"(?:UTC|[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)+)"),
        ):
            value = node[key]
            require(isinstance(value, str) and (value == "auto" or re.fullmatch(pattern, value)),
                    f"invalid {key}")
        probes = node["probes"]
        require(isinstance(probes, list) and 1 <= len(probes) <= 8, "expected 1–8 probes")
        origins = set()
        for probe in probes:
            fields(probe, ("url", "format"))
            url = endpoint(probe["url"], local)
            require(url.port != port or url.hostname not in LOCAL_HOSTS,
                    "probe must not target its own proxy listener")
            require(probe["format"] in ("text", "json"), "unsupported probe format")
            origins.add(url.hostname)
        require(local or len(origins) >= 2, "neutral mode requires two probe hostnames")
        require("auto" not in (node["locale"], node["timezone"])
                or any(p["format"] == "json" for p in probes), "auto requires a JSON probe")
    return BROWSERS[browser], local


def clean_env(base, keep_user_dirs=False):
    env = {
        "SystemRoot": str(SYSTEM_ROOT), "WINDIR": str(SYSTEM_ROOT),
        "SystemDrive": SYSTEM_ROOT.drive,
        "PATH": str(SYSTEM_ROOT / "System32"),
        "USERPROFILE": os.environ.get("USERPROFILE", str(base)) if keep_user_dirs else str(base),
        "HOME": str(base),
        "LOCALAPPDATA": os.environ.get("LOCALAPPDATA", str(base)) if keep_user_dirs else str(base),
        "APPDATA": os.environ.get("APPDATA", str(base)) if keep_user_dirs else str(base),
        "TEMP": str(base), "TMP": str(base),
    }
    return env


def probe_node(node, environment):
    metadata = {"locale": set(), "timezone": set()}
    for probe in node["probes"]:
        url = probe["url"]
        result = subprocess.run([
            str(CURL), "-q", "-4", "--silent", "--fail", "--connect-timeout", "3",
            "--max-time", "6", "--max-filesize", "16384", "--noproxy", "",
            "--proxy", f"http://127.0.0.1:{node['proxy_port']}",
            "--proto", f"={urlsplit(url).scheme}", "--write-out", "\n%{http_code}", "--", url,
        ], capture_output=True, env=environment, cwd=SCRIPT_DIR, timeout=8, check=False)
        body, _, status = result.stdout.rpartition(b"\n")
        require(result.returncode == 0 and status == b"200",
                f"proxy probe failed ({urlsplit(url).hostname}, curl={result.returncode})")
        if probe["format"] == "text":
            observed = body.decode("ascii").strip()
        else:
            data = json.loads(body, object_pairs_hook=unique)
            require(isinstance(data, dict), "invalid JSON probe body")
            observed = data.get("ip")
            tz = data.get("timezone")
            if isinstance(tz, dict):
                tz = tz.get("id")
            country = data.get("country_code", data.get("country"))
            locale = data.get("locale")
            if locale is None and isinstance(country, str):
                locale = REGIONS.get(country.upper())
            for key, value in (("locale", locale), ("timezone", tz)):
                if value is not None and node[key] == "auto":
                    require(isinstance(value, str) and 0 < len(value) <= 100,
                            f"invalid probe {key}")
                    metadata[key].add(value)
        require(ipv4(observed) == node["expected_ipv4"], "egress IPv4 mismatch")
    chosen = {}
    for key, values in metadata.items():
        if node[key] == "auto":
            require(len(values) == 1, f"missing or conflicting automatic {key}")
            chosen[key] = next(iter(values))
        else:
            chosen[key] = node[key]
    return chosen


def browser_policy(browser):
    # Managed settings can supersede command-line browser settings.
    import winreg

    vendor = r"Google\Chrome" if browser == BROWSERS["chrome"] else r"Microsoft\Edge"
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        for view in (winreg.KEY_WOW64_32KEY, winreg.KEY_WOW64_64KEY):
            try:
                with winreg.OpenKey(hive, rf"SOFTWARE\Policies\{vendor}", 0,
                                    winreg.KEY_READ | view) as key:
                    subkeys, values, _ = winreg.QueryInfoKey(key)
                    require(not (subkeys or values), "managed browser policy present")
            except FileNotFoundError:
                continue


@contextmanager
def exclusive(lock_path, name="profile"):
    safe_path(lock_path)
    with lock_path.open("a+b", buffering=0) as handle:
        handle.seek(0)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise GateError(f"{name} is locked by another launcher") from exc
        try:
            yield
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def bind_profile(profile, identity):
    marker = safe_path(profile / ".a1-node.json")
    if profile.exists():
        if marker.exists():
            require(read_json(marker) == identity, "profile identity mismatch")
            for root, directories, files in os.walk(profile, onerror=raise_error):
                for directory in directories:
                    safe_path(Path(root) / directory, directory=True)
                for name in files:
                    safe_path(Path(root) / name)
            return
        require(not any(profile.iterdir()), "unmarked nonempty profile")
    else:
        profile.mkdir()
    with marker.open("x", encoding="utf-8") as file:
        json.dump(identity, file, indent=2)


def configure_preferences(profile):
    default = safe_path(profile / "Default", directory=True)
    preference_file = safe_path(default / "Preferences")
    policy = "disable_non_proxied_udp"
    if preference_file.exists():
        prefs = read_json(preference_file)
        rtc = prefs.get("webrtc", {})
        session = prefs.get("session", {})
        require(rtc.get("ip_handling_policy") == policy
                and not (rtc.get("ip_handling_url") or rtc.get("ip_handling_urls")),
                "profile WebRTC preference changed")
        require(session.get("restore_on_startup") == 5, "profile startup preference changed")
    else:
        default.mkdir(exist_ok=True)
        with preference_file.open("x", encoding="utf-8") as file:
            json.dump({"webrtc": {"ip_handling_policy": policy},
                       "session": {"restore_on_startup": 5}}, file)


def supervise(command, environment, runtime, config):
    # Hold the Windows job until Node exits. Its entire browser process tree
    # is terminated on handle close even if CDP or graceful shutdown fails.
    kernel = ct.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = (ct.c_void_p, wt.LPCWSTR)
    kernel.CreateJobObjectW.restype = wt.HANDLE
    kernel.SetInformationJobObject.argtypes = (wt.HANDLE, ct.c_int, ct.c_void_p, wt.DWORD)
    kernel.AssignProcessToJobObject.argtypes = (wt.HANDLE, wt.HANDLE)
    kernel.CloseHandle.argtypes = (wt.HANDLE,)
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise ct.WinError(ct.get_last_error())
    try:
        limits = ExtendedJobLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(job, 9, ct.byref(limits), ct.sizeof(limits)):
            raise ct.WinError(ct.get_last_error())
        child = subprocess.Popen(command, stdin=subprocess.PIPE, encoding="utf-8",
                                 env=environment, cwd=runtime,
                                 creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
        # Node waits for its input before it can spawn Chromium.
        if not kernel.AssignProcessToJobObject(job, int(child._handle)):
            error = ct.WinError(ct.get_last_error())
            child.kill()
            child.communicate()
            raise error
        try:
            child.communicate(json.dumps(config))
        except KeyboardInterrupt:
            try:
                child.send_signal(signal.CTRL_BREAK_EVENT)
                child.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                pass
            raise
        return child.returncode
    finally:
        kernel.CloseHandle(job)


def run(args, cached_test_browser=None):
    safe_path(SCRIPT_DIR, directory=True)
    config_path = Path(args.config).absolute()
    require(config_path.suffix.lower() == ".json", "config must be a .json file")
    config = read_json(safe_path(config_path))
    browser, local = validate(config, args.allow_neutral)
    require(not (args.smoke or args.diagnostic) or (local and args.headless),
            "smoke requires local headless mode")
    if cached_test_browser:
        require(local and args.headless and args.smoke, "cached test browser requires local CDP smoke")
    executable = cached_test_browser or browser
    require(executable.is_file() and NODE.is_file() and CURL.is_file(),
            "browser, Node.js or curl.exe unavailable")
    smoke = None
    if args.smoke:
        page, cut, canary = args.smoke
        endpoint(page, True)
        endpoint(cut, True)
        endpoint(canary, True, literal=True)
        smoke = {"page": page, "cut": cut, "canary": canary}
    if args.diagnostic:
        endpoint(args.diagnostic, True)
        require(not args.smoke, "choose only one test mode")
    name = token(args.node)
    require(name in config["nodes"], "unknown node ID")
    node = config["nodes"][name]
    browser_policy(browser)
    probes = probe_node(node, clean_env(SCRIPT_DIR))
    environment = {**probes, "browser": str(executable), "local": local,
                   "headless": args.headless, "smoke": smoke, "port": node["proxy_port"],
                   "diagnostic": args.diagnostic, "cachedTest": bool(cached_test_browser)}
    supervisor = safe_path(SCRIPT_DIR / "route-a1-browser-session.mjs")
    validation = subprocess.run([str(NODE), str(supervisor), "--validate"],
                                input=json.dumps(probes), encoding="utf-8",
                                env=clean_env(SCRIPT_DIR), cwd=SCRIPT_DIR, check=False, timeout=10)
    require(validation.returncode == 0, "invalid browser locale or IANA timezone")

    state_root = Path(args.state_dir).absolute() if args.state_dir else (config_path.parent / "a1-profiles")
    profiles = safe_path(state_root, directory=True)
    profiles.mkdir(exist_ok=True)
    bindings = safe_path(profiles / ".bindings", directory=True)
    bindings.mkdir(exist_ok=True)
    profile_name = node.get("profile", name)
    profile = safe_path(profiles / profile_name, directory=True)
    lock_path = profiles / f"{profile_name}.lock"
    identity = {"id": name, "port": node["proxy_port"], "ipv4": node["expected_ipv4"],
                "browser": browser.name, "mode": config["mode"]}
    with (exclusive(lock_path), exclusive(bindings / f"node-{name}.lock", "node"),
          exclusive(bindings / f"port-{node['proxy_port']}.lock", "proxy port")):
        registry = safe_path(bindings / f"{name}.json")
        if registry.exists():
            require(read_json(registry) == profile_name, "node is already bound to another profile")
        bind_profile(profile, identity)
        configure_preferences(profile)
        if not registry.exists():
            with registry.open("x", encoding="utf-8") as file:
                json.dump(profile_name, file)
        runtime = safe_path(profiles / f"{profile_name}.runtime", directory=True)
        runtime.mkdir(exist_ok=True)
        environment["profile"] = str(profile)
        print(f"GATE PASS {name} {node['expected_ipv4']} {probes['locale']} {probes['timezone']}",
              flush=True)
        status = supervise([str(NODE), str(supervisor)], clean_env(runtime, keep_user_dirs=True), runtime, environment)
        require(status == 0, "browser session failed")


def main(cached_test_browser=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("node")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--state-dir", help="directory for isolated per-node profiles and locks")
    parser.add_argument("--allow-neutral", action="store_true")
    parser.add_argument("--smoke", nargs=3, help=argparse.SUPPRESS)
    parser.add_argument("--diagnostic", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        run(args, cached_test_browser)
    except KeyboardInterrupt:
        return 130
    except (GateError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
