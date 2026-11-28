#!/usr/bin/env node
/**
 * Host Agent Task Dispatcher (generic, zero external dependencies).
 *
 * Watches <SHARE_ROOT>/dispatch/pending/*.json written by a guest VM agent
 * (via a shared folder mount, zero network ports exposed) and dispatches
 * whitelisted tasks to host CLIs (codex / agy / dsh) non-interactively.
 *
 * Usage:
 *   node scripts/host-dispatcher.mjs --share-root <PATH> [--max-concurrent 2] [--once]
 *
 * Environment variables:
 *   DISPATCH_SHARE_ROOT   Shared root directory (overridden by --share-root)
 *   DISPATCH_MAX_CONC     Max concurrent tasks (default: 2)
 *   DISPATCH_POLL_MS      Poll interval in ms (default: 1000)
 *   DISPATCH_ALLOW_FULL   Set to "1" to allow mode="full" (disabled by default)
 *   DISPATCH_ONCE         Set to "1" to process current pending tasks and exit
 */

import fs from "node:fs";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";

const IS_WIN = process.platform === "win32";

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--share-root" && argv[i + 1]) out.shareRoot = argv[++i];
    else if (a === "--max-concurrent" && argv[i + 1]) out.maxConc = argv[++i];
    else if (a === "--poll-ms" && argv[i + 1]) out.pollMs = argv[++i];
    else if (a === "--once") out.once = true;
    else if (a === "--help" || a === "-h") out.help = true;
  }
  return out;
}

const CLI = parseArgs(process.argv.slice(2));
if (CLI.help) {
  console.log("Usage: node host-dispatcher.mjs --share-root <PATH> [--max-concurrent 2] [--once]");
  process.exit(0);
}

const RAW_SHARE_ROOT = CLI.shareRoot || process.env.DISPATCH_SHARE_ROOT;
if (!RAW_SHARE_ROOT) {
  console.error("ERROR: --share-root <PATH> or DISPATCH_SHARE_ROOT is required.");
  process.exit(2);
}

const SHARE_ROOT = fs.existsSync(RAW_SHARE_ROOT)
  ? fs.realpathSync(path.resolve(RAW_SHARE_ROOT))
  : path.resolve(RAW_SHARE_ROOT);

const DISPATCH_DIR = path.join(SHARE_ROOT, "dispatch");
const DIRS = {
  pending: path.join(DISPATCH_DIR, "pending"),
  running: path.join(DISPATCH_DIR, "running"),
  done: path.join(DISPATCH_DIR, "done"),
  logs: path.join(DISPATCH_DIR, "logs"),
  prompts: path.join(DISPATCH_DIR, "prompts"),
  cancel: path.join(DISPATCH_DIR, "cancel"),
};

const MAX_CONC = Math.max(1, parseInt(CLI.maxConc || process.env.DISPATCH_MAX_CONC || "2", 10) || 2);
const POLL_MS = Math.max(200, parseInt(CLI.pollMs || process.env.DISPATCH_POLL_MS || "1000", 10) || 1000);
const ALLOW_FULL = process.env.DISPATCH_ALLOW_FULL === "1";
const RUN_ONCE = Boolean(CLI.once || process.env.DISPATCH_ONCE === "1");

const HEARTBEAT_FILE = path.join(DISPATCH_DIR, "dispatcher.heartbeat.json");
const LEDGER_FILE = path.join(DISPATCH_DIR, "usage-ledger.json");
const DAEMON_LOG = path.join(DIRS.logs, "dispatcher.log");
const PID_FILE = path.join(DISPATCH_DIR, "dispatcher.pid");
const STARTED_AT = new Date().toISOString();

function readJsonSafe(filePath, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return fallback;
  }
}

function parseTokensFromLogs(stdoutText, stderrText) {
  const combined = `${stdoutText || ""}\n${stderrText || ""}`;
  const m1 = combined.match(/tokens\s+used[\s:\r\n]+([\d,]+)/i);
  if (m1) return parseInt(m1[1].replace(/,/g, ""), 10) || 0;
  const m2 = combined.match(/"total_tokens"\s*:\s*(\d+)/i);
  if (m2) return parseInt(m2[1], 10) || 0;
  return 0;
}

function classifyFailure(status, summary, stderrTail, errMsg) {
  if (status === "succeeded") return { health: "ready", cooldownMin: 0, reason: null };
  const text = `${errMsg || ""}\n${stderrTail || ""}\n${summary || ""}`;
  if (/not logged in|authentication required|missing_credential|please (run|use) \/login|no api key/i.test(text)) {
    return { health: "needs_login", cooldownMin: 0, reason: "Authentication or credential required" };
  }
  if (/429|rate[\s_-]*limit|quota[\s_-]*exceeded|insufficient[\s_-]*(quota|balance|credit)|too many requests|usage limit/i.test(text)) {
    return { health: "rate_limited", cooldownMin: 45, reason: "Rate-limited or quota exhausted (45m cooldown)" };
  }
  return { health: "ready", cooldownMin: 0, reason: null };
}

function recordUsage(agentId, record) {
  try {
    const ledger = readJsonSafe(LEDGER_FILE, { version: 1, agents: {}, history: [] });
    ledger.agents = ledger.agents || {};
    ledger.history = Array.isArray(ledger.history) ? ledger.history : [];

    const prev = ledger.agents[agentId] || {
      health_status: "ready",
      cooldown_until: null,
      last_reason: null,
      total_runs: 0,
      succeeded_runs: 0,
      failed_runs: 0,
      total_tokens_reported: 0,
      last_run_at: null,
      last_status: null,
    };

    const diag = classifyFailure(record.status, record.summary, record.stderr_tail, record.error);
    prev.total_runs += 1;
    if (record.status === "succeeded") prev.succeeded_runs += 1;
    else prev.failed_runs += 1;
    prev.total_tokens_reported += record.tokens || 0;
    prev.last_run_at = record.finished_at;
    prev.last_status = record.status;
    prev.health_status = diag.health;
    prev.last_reason = diag.reason;
    prev.cooldown_until =
      diag.cooldownMin > 0 ? new Date(Date.now() + diag.cooldownMin * 60 * 1000).toISOString() : null;

    ledger.agents[agentId] = prev;
    ledger.history.push({
      id: record.id,
      agent: agentId,
      status: record.status,
      tokens: record.tokens || 0,
      duration_ms: record.duration_ms || 0,
      finished_at: record.finished_at,
    });
    if (ledger.history.length > 500) ledger.history = ledger.history.slice(-500);
    ledger.updated_at = new Date().toISOString();
    atomicWriteJson(LEDGER_FILE, ledger);
  } catch (err) {
    log(`Ledger write failed: ${err.message}`);
  }
}

function ensureDirs() {
  for (const d of Object.values(DIRS)) {
    fs.mkdirSync(d, { recursive: true });
  }
}

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try {
    fs.appendFileSync(DAEMON_LOG, line + "\n", "utf8");
  } catch {
    /* ignore */
  }
}

function atomicWriteJson(filePath, obj) {
  const tmp = `${filePath}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), "utf8");
  fs.renameSync(tmp, filePath);
}

function readTail(filePath, maxBytes = 8192) {
  try {
    const st = fs.statSync(filePath);
    if (st.size === 0) return "";
    const start = Math.max(0, st.size - maxBytes);
    const fd = fs.openSync(filePath, "r");
    try {
      const buf = Buffer.alloc(st.size - start);
      fs.readSync(fd, buf, 0, buf.length, start);
      return buf.toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return "";
  }
}

function resolveExecutable(candidates) {
  const finder = IS_WIN ? "where.exe" : "which";
  for (const name of candidates) {
    try {
      const out = execFileSync(finder, [name], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      const first = out
        .split(/\r?\n/)
        .map((s) => s.trim())
        .find(Boolean);
      if (first) return first;
    } catch {
      /* try next */
    }
  }
  return null;
}

function resolveExistingFile(candidates) {
  for (const p of candidates) {
    if (p && fs.existsSync(p)) return p;
  }
  return null;
}

const WORKBUDDY_PRODUCT_CFG = resolveExistingFile([
  process.env.DISPATCH_WORKBUDDY_PRODUCT_CONFIG,
  process.env.ACC_PRODUCT_CONFIG_PATH,
]);

const RESOLVED_BINS = {
  dsh: resolveExecutable(IS_WIN ? ["dsh.cmd", "dsh.exe", "dsh.ps1"] : ["dsh"]),
  agy: resolveExecutable(IS_WIN ? ["agy.exe", "agy.cmd"] : ["agy"]),
  codex: resolveExecutable(IS_WIN ? ["codex.cmd", "codex.exe", "codex.ps1"] : ["codex"]),
  autoclaw:
    resolveExistingFile([process.env.DISPATCH_AUTOCLAW_CLI]) ||
    resolveExecutable(IS_WIN ? ["zcode.cmd", "zcode.exe"] : ["zcode"]),
  workbuddy:
    resolveExistingFile([process.env.DISPATCH_WORKBUDDY_CLI]) ||
    resolveExecutable(IS_WIN ? ["codebuddy.cmd", "codebuddy.exe"] : ["codebuddy"]),
  qoder:
    resolveExistingFile([process.env.DISPATCH_QODER_CLI]) ||
    resolveExecutable(IS_WIN ? ["qoderclicn.cmd", "qoderclicn.exe", "qodercli.cmd", "qodercli.exe"] : ["qoderclicn", "qodercli"]),
};

function normalizeAgent(raw) {
  const s = String(raw || "").trim().toLowerCase();
  if (s === "antigravity" || s === "agy") return "agy";
  if (s === "dsh") return "dsh";
  if (s === "codex") return "codex";
  if (s === "autoclaw" || s === "zcode") return "autoclaw";
  if (s === "workbuddy" || s === "codebuddy") return "workbuddy";
  if (s === "qoder" || s === "qodercli" || s === "qoderclicn" || s === "qodercn") return "qoder";
  return null;
}

function isInsideRoot(targetReal, rootReal) {
  const t = IS_WIN ? targetReal.toLowerCase() : targetReal;
  const r = IS_WIN ? rootReal.toLowerCase() : rootReal;
  return t === r || t.startsWith(r + path.sep);
}

/**
 * Resolve task cwd strictly inside SHARE_ROOT (rejecting traversal and symlink escape).
 */
function resolveTaskCwd(task) {
  let raw = "";
  if (task.project && typeof task.project === "string" && task.project.trim()) {
    const proj = task.project.trim();
    if (/^[a-zA-Z]:[\\/]/.test(proj) || proj.startsWith("\\\\") || proj.startsWith("/")) {
      raw = proj;
    } else if (/^projects[\\/]/i.test(proj)) {
      raw = path.join(SHARE_ROOT, proj);
    } else {
      raw = path.join(SHARE_ROOT, "projects", proj);
    }
  } else if (task.cwd && typeof task.cwd === "string" && task.cwd.trim()) {
    raw = task.cwd.trim();
  } else {
    return { ok: true, cwd: SHARE_ROOT };
  }

  // Optional mapping of VMware HGFS UNC or mapped drive prefixes pointing at the share root
  const uncMatch = raw.match(/^\\\\vmware-host\\Shared Folders\\[^\\/]+([\\/].*)?$/i);
  if (uncMatch) {
    const rest = (uncMatch[1] || "").replace(/^[\\/]+/, "");
    raw = rest ? path.join(SHARE_ROOT, rest) : SHARE_ROOT;
  } else if (!path.isAbsolute(raw)) {
    raw = path.join(SHARE_ROOT, raw);
  }

  const candidate = path.resolve(raw);
  if (!fs.existsSync(candidate) || !fs.statSync(candidate).isDirectory()) {
    return { ok: false, error: `Working directory does not exist or is not a directory: ${candidate}` };
  }
  const real = fs.realpathSync(candidate);
  if (!isInsideRoot(real, SHARE_ROOT)) {
    return { ok: false, error: `Working directory escapes share root (${SHARE_ROOT}): ${real}` };
  }
  return { ok: true, cwd: real };
}

function buildWrappedPrompt(task, cwd) {
  const mode = task.mode || "auto";
  const prefix = [
    "[Host Dispatch Context]",
    `- Dispatched by ${task.origin || "guest-agent"} (task_id: ${task.id}).`,
    `- Target working directory: ${cwd}`,
    `- Mode: ${mode === "read-only" ? "read-only analysis (do not edit files or commit)" : "workspace read-write (never git push to remote; never touch files outside the target directory)"}`,
    `- Do NOT dispatch new tasks back into dispatch/ or the guest VM (loop prevention).`,
    `- Reply with a concise summary: what changed, files touched, and verification results.`,
    "---",
    "",
  ].join("\n");
  return prefix + String(task.prompt || "");
}

function killProcessTree(pid) {
  if (!pid) return;
  try {
    if (IS_WIN) {
      execFileSync("taskkill.exe", ["/PID", String(pid), "/T", "/F"], {
        stdio: "ignore",
        timeout: 10000,
      });
    } else {
      process.kill(-pid, "SIGKILL");
    }
  } catch {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      /* already exited */
    }
  }
}

function spawnAgent(agentId, task, cwd, wrappedPrompt, lastMsgFile) {
  const bin = RESOLVED_BINS[agentId];
  if (!bin) throw new Error(`Host CLI not found for agent: ${agentId}`);
  const mode = task.mode || "auto";
  const timeoutSec = task.timeout_sec;
  const spawnOpts = { cwd, windowsHide: true, detached: !IS_WIN };

  if (agentId === "dsh") {
    const args = ["--profile", "headless"];
    if (task.session_id) args.push("--session-id", String(task.session_id));
    args.push("-");
    const child =
      IS_WIN && /\.cmd$/i.test(bin)
        ? spawn("cmd.exe", ["/d", "/s", "/c", bin, ...args], spawnOpts)
        : spawn(bin, args, spawnOpts);
    child.stdin.write(wrappedPrompt, "utf8");
    child.stdin.end();
    return child;
  }

  if (agentId === "codex") {
    const args = ["exec", "--skip-git-repo-check", "-C", cwd, "-o", lastMsgFile, "--color", "never"];
    if (mode === "read-only") {
      args.push("-s", "read-only");
    } else if (mode === "full" && ALLOW_FULL) {
      args.push("--dangerously-bypass-approvals-and-sandbox");
    } else {
      args.push("--approve-for-me");
    }
    if (task.model) args.push("-m", String(task.model));
    args.push("-");
    const child =
      IS_WIN && /\.cmd$/i.test(bin)
        ? spawn("cmd.exe", ["/d", "/s", "/c", bin, ...args], spawnOpts)
        : spawn(bin, args, spawnOpts);
    child.stdin.write(wrappedPrompt, "utf8");
    child.stdin.end();
    return child;
  }

  if (agentId === "agy") {
    let promptArg = wrappedPrompt;
    if (Buffer.byteLength(promptArg, "utf8") > 12000) {
      const promptFile = path.join(DIRS.prompts, `${task.id}.md`);
      fs.writeFileSync(promptFile, wrappedPrompt, "utf8");
      promptArg = `Read and execute the task instructions in: ${promptFile}`;
    }
    const args = ["-p", promptArg, "--output-format", "json", "--add-dir", cwd];
    if (mode === "read-only") {
      args.push("--mode", "plan");
    } else if (mode === "full" && ALLOW_FULL) {
      args.push("--dangerously-skip-permissions");
    } else {
      args.push("--mode", "auto");
    }
    if (task.model) args.push("--model", String(task.model));
    if (timeoutSec) args.push("--print-timeout", `${timeoutSec}s`);
    const child = spawn(bin, args, spawnOpts);
    child.stdin.end();
    return child;
  }

  if (agentId === "autoclaw") {
    let promptArg = wrappedPrompt;
    if (Buffer.byteLength(promptArg, "utf8") > 12000) {
      const promptFile = path.join(DIRS.prompts, `${task.id}.md`);
      fs.writeFileSync(promptFile, wrappedPrompt, "utf8");
      promptArg = `Read and execute the task instructions in: ${promptFile}`;
    }
    const zMode = mode === "read-only" ? "plan" : mode === "full" && ALLOW_FULL ? "yolo" : "build";
    const isJs = /\.[cm]?js$/i.test(bin);
    const args = isJs
      ? [bin, "-p", promptArg, "--cwd", cwd, "--mode", zMode, "--no-color"]
      : ["-p", promptArg, "--cwd", cwd, "--mode", zMode, "--no-color"];
    const child = isJs ? spawn(process.execPath, args, spawnOpts) : spawn(bin, args, spawnOpts);
    child.stdin.end();
    return child;
  }

  if (agentId === "workbuddy") {
    let promptArg = wrappedPrompt;
    if (Buffer.byteLength(promptArg, "utf8") > 12000) {
      const promptFile = path.join(DIRS.prompts, `${task.id}.md`);
      fs.writeFileSync(promptFile, wrappedPrompt, "utf8");
      promptArg = `Read and execute the task instructions in: ${promptFile}`;
    }
    const permMode =
      mode === "read-only" ? "plan" : mode === "full" && ALLOW_FULL ? "bypassPermissions" : "auto";
    const cliArgs = ["-p", "--permission-mode", permMode, "--add-dir", cwd];
    if (task.model) cliArgs.push("--model", String(task.model));
    cliArgs.push(promptArg);
    const env = { ...process.env };
    if (WORKBUDDY_PRODUCT_CFG) env.ACC_PRODUCT_CONFIG_PATH = WORKBUDDY_PRODUCT_CFG;
    const isJs = /\.[cm]?js$/i.test(bin);
    const child = isJs
      ? spawn(process.execPath, [bin, ...cliArgs], { ...spawnOpts, env })
      : spawn(bin, cliArgs, { ...spawnOpts, env });
    child.stdin.end();
    return child;
  }

  if (agentId === "qoder") {
    let promptArg = wrappedPrompt;
    if (Buffer.byteLength(promptArg, "utf8") > 12000) {
      const promptFile = path.join(DIRS.prompts, `${task.id}.md`);
      fs.writeFileSync(promptFile, wrappedPrompt, "utf8");
      promptArg = `Read and execute the task instructions in: ${promptFile}`;
    }
    const permMode =
      mode === "read-only" ? "default" : mode === "full" && ALLOW_FULL ? "bypass_permissions" : "auto";
    const args = ["-p", "-w", cwd, "--permission-mode", permMode];
    if (task.model) args.push("-m", String(task.model));
    args.push("--", promptArg);
    const child =
      IS_WIN && /\.cmd$/i.test(bin)
        ? spawn("cmd.exe", ["/d", "/s", "/c", bin, ...args], spawnOpts)
        : spawn(bin, args, spawnOpts);
    child.stdin.end();
    return child;
  }

  throw new Error(`Unsupported agent: ${agentId}`);
}

function extractSummary(agentId, stdoutLog, lastMsgFile) {
  if (agentId === "codex" && fs.existsSync(lastMsgFile)) {
    const txt = fs.readFileSync(lastMsgFile, "utf8").trim();
    if (txt) return txt.slice(0, 12000);
  }
  const tail = readTail(stdoutLog, 24000).trim();
  if (agentId === "agy" && tail) {
    try {
      const parsed = JSON.parse(tail);
      const text =
        parsed.result ||
        parsed.response ||
        parsed.text ||
        parsed.output ||
        (typeof parsed === "string" ? parsed : null);
      if (text) return String(text).slice(0, 12000);
    } catch {
      /* fallback */
    }
  }
  return tail.slice(-8000);
}

const activeTasks = new Map();
const lockedWriteDirs = new Set();

function writeHeartbeat() {
  const runningList = [];
  for (const [id, info] of activeTasks.entries()) {
    runningList.push({
      id,
      agent: info.agentId,
      cwd: info.cwd,
      mode: info.mode,
      started_at: info.startedAt,
      pid: info.child ? info.child.pid : null,
    });
  }
  try {
    atomicWriteJson(HEARTBEAT_FILE, {
      status: "online",
      pid: process.pid,
      started_at: STARTED_AT,
      updated_at: new Date().toISOString(),
      share_root: SHARE_ROOT,
      max_concurrent: MAX_CONC,
      allow_full_mode: ALLOW_FULL,
      available_agents: Object.fromEntries(
        Object.entries(RESOLVED_BINS).map(([k, v]) => [k, Boolean(v)])
      ),
      running_count: activeTasks.size,
      running_tasks: runningList,
    });
  } catch (err) {
    log(`Heartbeat write failed: ${err.message}`);
  }
}

function writeRejected(taskId, task, reason) {
  atomicWriteJson(path.join(DIRS.done, `${taskId}.result.json`), {
    id: taskId,
    agent: task ? task.agent : null,
    status: "rejected",
    error: reason,
    finished_at: new Date().toISOString(),
  });
  log(`Rejected ${taskId}: ${reason}`);
}

function checkCancellations() {
  for (const [taskId, info] of activeTasks.entries()) {
    const cancelFlag = path.join(DIRS.cancel, `${taskId}.cancel`);
    if (fs.existsSync(cancelFlag) && !info.cancelRequested) {
      info.cancelRequested = true;
      log(`Cancelling ${taskId} (PID=${info.child?.pid})`);
      killProcessTree(info.child?.pid);
      try {
        fs.unlinkSync(cancelFlag);
      } catch {
        /* ignore */
      }
    }
  }
}

function startTask(pendingFile) {
  const baseName = path.basename(pendingFile, ".json");
  let task;
  try {
    task = JSON.parse(fs.readFileSync(pendingFile, "utf8"));
  } catch (err) {
    try {
      fs.renameSync(pendingFile, path.join(DIRS.done, `${baseName}.invalid.json`));
    } catch {
      /* ignore */
    }
    writeRejected(baseName, null, `Invalid JSON: ${err.message}`);
    return;
  }

  const taskId = String(task.id || baseName).replace(/[^a-zA-Z0-9._-]/g, "_");
  const agentId = normalizeAgent(task.agent);
  if (!agentId) {
    try { fs.unlinkSync(pendingFile); } catch { /* ignore */ }
    writeRejected(taskId, task, `Unsupported agent "${task.agent}". Allowed: dsh, agy, codex`);
    return;
  }
  if (!task.prompt || !String(task.prompt).trim()) {
    try { fs.unlinkSync(pendingFile); } catch { /* ignore */ }
    writeRejected(taskId, task, "Missing prompt");
    return;
  }

  const mode = String(task.mode || "auto").toLowerCase();
  if (!["read-only", "auto", "full"].includes(mode)) {
    try { fs.unlinkSync(pendingFile); } catch { /* ignore */ }
    writeRejected(taskId, task, `Invalid mode "${mode}". Allowed: read-only, auto`);
    return;
  }
  if (mode === "full" && !ALLOW_FULL) {
    try { fs.unlinkSync(pendingFile); } catch { /* ignore */ }
    writeRejected(taskId, task, 'mode="full" is disabled (set DISPATCH_ALLOW_FULL=1 on host to enable)');
    return;
  }

  const cwdCheck = resolveTaskCwd(task);
  if (!cwdCheck.ok) {
    try { fs.unlinkSync(pendingFile); } catch { /* ignore */ }
    writeRejected(taskId, task, cwdCheck.error);
    return;
  }
  if (!RESOLVED_BINS[agentId]) {
    try { fs.unlinkSync(pendingFile); } catch { /* ignore */ }
    writeRejected(taskId, task, `Host CLI not installed or not in PATH for agent: ${agentId}`);
    return;
  }

  const cwd = cwdCheck.cwd;
  const dirKey = IS_WIN ? cwd.toLowerCase() : cwd;
  const isWriteTask = mode !== "read-only";
  if (isWriteTask && lockedWriteDirs.has(dirKey)) return;

  const cancelFlag = path.join(DIRS.cancel, `${taskId}.cancel`);
  if (fs.existsSync(cancelFlag)) {
    try { fs.unlinkSync(pendingFile); fs.unlinkSync(cancelFlag); } catch { /* ignore */ }
    atomicWriteJson(path.join(DIRS.done, `${taskId}.result.json`), {
      id: taskId,
      agent: agentId,
      cwd,
      status: "cancelled",
      finished_at: new Date().toISOString(),
    });
    return;
  }

  const runningFile = path.join(DIRS.running, `${taskId}.json`);
  try {
    fs.renameSync(pendingFile, runningFile);
  } catch {
    return;
  }

  if (isWriteTask) lockedWriteDirs.add(dirKey);

  const timeoutSec = Math.min(1800, Math.max(30, parseInt(task.timeout_sec || "600", 10) || 600));
  const stdoutLog = path.join(DIRS.logs, `${taskId}.stdout.log`);
  const stderrLog = path.join(DIRS.logs, `${taskId}.stderr.log`);
  const lastMsgFile = path.join(DIRS.logs, `${taskId}.last_message.txt`);
  const startedAt = new Date().toISOString();
  const startMs = Date.now();
  const wrappedPrompt = buildWrappedPrompt({ ...task, id: taskId, mode }, cwd);

  log(`Starting ${taskId} | agent=${agentId} | mode=${mode} | cwd=${cwd}`);
  const outStream = fs.createWriteStream(stdoutLog, { flags: "w" });
  const errStream = fs.createWriteStream(stderrLog, { flags: "w" });

  let child;
  try {
    child = spawnAgent(agentId, { ...task, id: taskId, mode, timeout_sec: timeoutSec }, cwd, wrappedPrompt, lastMsgFile);
  } catch (err) {
    outStream.end();
    errStream.end();
    if (isWriteTask) lockedWriteDirs.delete(dirKey);
    try { fs.unlinkSync(runningFile); } catch { /* ignore */ }
    writeRejected(taskId, task, `Failed to spawn process: ${err.message}`);
    return;
  }

  child.stdout.pipe(outStream);
  child.stderr.pipe(errStream);

  const info = { id: taskId, agentId, cwd, mode, child, startedAt, cancelRequested: false, timedOut: false };
  activeTasks.set(taskId, info);
  writeHeartbeat();

  const timer = setTimeout(() => {
    info.timedOut = true;
    log(`Timeout ${taskId} (${timeoutSec}s), killing PID=${child.pid}`);
    killProcessTree(child.pid);
  }, timeoutSec * 1000);

  let finalized = false;
  const finalize = (exitCode, spawnErr) => {
    if (finalized) return;
    finalized = true;
    clearTimeout(timer);
    outStream.end();
    errStream.end();
    activeTasks.delete(taskId);
    if (isWriteTask) lockedWriteDirs.delete(dirKey);
    try { fs.unlinkSync(runningFile); } catch { /* ignore */ }

    const durationMs = Date.now() - startMs;
    let status = "succeeded";
    if (info.cancelRequested) status = "cancelled";
    else if (info.timedOut) status = "timeout";
    else if (spawnErr || exitCode !== 0) status = "failed";

    const summary = extractSummary(agentId, stdoutLog, lastMsgFile);
    const stderrTail = readTail(stderrLog, 4096).trim();
    const tokens = parseTokensFromLogs(readTail(stdoutLog, 8192), stderrTail);
    const finishedAt = new Date().toISOString();

    const resultObj = {
      id: taskId,
      agent: agentId,
      cwd,
      mode,
      status,
      exit_code: exitCode,
      error: spawnErr ? spawnErr.message : null,
      started_at: startedAt,
      finished_at: finishedAt,
      duration_ms: durationMs,
      tokens_reported: tokens,
      summary,
      stderr_tail: stderrTail,
      stdout_log: path.relative(SHARE_ROOT, stdoutLog).replace(/\\/g, "/"),
      stderr_log: path.relative(SHARE_ROOT, stderrLog).replace(/\\/g, "/"),
    };
    atomicWriteJson(path.join(DIRS.done, `${taskId}.result.json`), resultObj);
    recordUsage(agentId, { ...resultObj, tokens });
    log(`Finished ${taskId} | status=${status} | code=${exitCode} | tokens=${tokens} | ${(durationMs / 1000).toFixed(1)}s`);
    writeHeartbeat();
  };

  child.on("error", (err) => finalize(-1, err));
  child.on("close", (code) => finalize(code ?? -1, null));
}

function tick() {
  try {
    checkCancellations();
    if (activeTasks.size < MAX_CONC) {
      const files = fs.readdirSync(DIRS.pending).filter((f) => f.endsWith(".json")).sort();
      for (const f of files) {
        if (activeTasks.size >= MAX_CONC) break;
        startTask(path.join(DIRS.pending, f));
      }
    }
  } catch (err) {
    log(`Tick error: ${err.message}`);
  }
}

function main() {
  ensureDirs();
  fs.writeFileSync(PID_FILE, String(process.pid), "utf8");
  log(`Host Dispatcher started | PID=${process.pid} | SHARE_ROOT=${SHARE_ROOT} | MAX_CONC=${MAX_CONC}`);
  writeHeartbeat();

  // Recover orphaned running tasks from prior crash
  try {
    for (const f of fs.readdirSync(DIRS.running).filter((x) => x.endsWith(".json"))) {
      const id = path.basename(f, ".json");
      fs.unlinkSync(path.join(DIRS.running, f));
      atomicWriteJson(path.join(DIRS.done, `${id}.result.json`), {
        id,
        status: "failed",
        error: "Host dispatcher restarted; previous running task was interrupted.",
        finished_at: new Date().toISOString(),
      });
    }
  } catch {
    /* ignore */
  }

  tick();

  if (RUN_ONCE) {
    const checkExit = setInterval(() => {
      checkCancellations();
      if (activeTasks.size === 0) {
        clearInterval(checkExit);
        process.exit(0);
      }
    }, 200);
    return;
  }

  const pollTimer = setInterval(tick, POLL_MS);
  const hbTimer = setInterval(writeHeartbeat, 5000);
  const shutdown = (sig) => {
    log(`Received ${sig}, shutting down...`);
    clearInterval(pollTimer);
    clearInterval(hbTimer);
    for (const info of activeTasks.values()) killProcessTree(info.child?.pid);
    try {
      atomicWriteJson(HEARTBEAT_FILE, { status: "offline", pid: process.pid, stopped_at: new Date().toISOString() });
    } catch { /* ignore */ }
    process.exit(0);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main();
