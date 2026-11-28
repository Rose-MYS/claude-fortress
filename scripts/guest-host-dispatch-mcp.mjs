#!/usr/bin/env node
/**
 * Guest-side zero-dependency MCP Server: host-dispatch.
 *
 * Lets a VM-isolated Claude (Desktop or Claude Code) dispatch tasks to host-side
 * agents (codex / agy / dsh) through a shared-folder queue with zero network ports.
 *
 * Configuration:
 *   HOST_DISPATCH_SHARE_ROOT  Shared directory path (or pass --share-root <PATH>)
 */

import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

function parseShareRoot(argv) {
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--share-root" && argv[i + 1]) return argv[i + 1];
  }
  return process.env.HOST_DISPATCH_SHARE_ROOT || "";
}

const SHARE_ROOT = parseShareRoot(process.argv.slice(2));
if (!SHARE_ROOT) {
  console.error("ERROR: Set HOST_DISPATCH_SHARE_ROOT or pass --share-root <PATH>.");
  process.exit(2);
}

const DISPATCH_DIR = path.join(SHARE_ROOT, "dispatch");
const DIRS = {
  pending: path.join(DISPATCH_DIR, "pending"),
  running: path.join(DISPATCH_DIR, "running"),
  done: path.join(DISPATCH_DIR, "done"),
  logs: path.join(DISPATCH_DIR, "logs"),
  cancel: path.join(DISPATCH_DIR, "cancel"),
};
const HEARTBEAT_FILE = path.join(DISPATCH_DIR, "dispatcher.heartbeat.json");
const CATALOG_FILE = path.join(DISPATCH_DIR, "agents-catalog.json");
const LEDGER_FILE = path.join(DISPATCH_DIR, "usage-ledger.json");

function ensureDirs() {
  for (const d of Object.values(DIRS)) {
    fs.mkdirSync(d, { recursive: true });
  }
}

function atomicWriteJson(filePath, obj) {
  const tmp = `${filePath}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), "utf8");
  fs.renameSync(tmp, filePath);
}

function readJsonSafe(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function readTail(filePath, maxBytes = 4096) {
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function makeTaskId(agent) {
  const now = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  const stamp =
    now.getFullYear() +
    pad(now.getMonth() + 1) +
    pad(now.getDate()) +
    "-" +
    pad(now.getHours()) +
    pad(now.getMinutes()) +
    pad(now.getSeconds());
  const rand = Math.random().toString(36).slice(2, 6);
  return `task-${stamp}-${agent}-${rand}`;
}

function getHealth() {
  ensureDirs();
  const hb = readJsonSafe(HEARTBEAT_FILE);
  if (!hb) {
    return {
      online: false,
      share_root: SHARE_ROOT,
      message: "Host Dispatcher heartbeat not found. Start host-dispatcher.mjs on the host first.",
    };
  }
  const updatedMs = hb.updated_at ? Date.parse(hb.updated_at) : 0;
  const ageSec = updatedMs ? Math.round((Date.now() - updatedMs) / 1000) : null;
  const online = hb.status === "online" && ageSec !== null && ageSec <= 25;
  return { online, heartbeat_age_sec: ageSec, share_root: SHARE_ROOT, ...hb };
}

function getAgentsOverview() {
  const health = getHealth();
  const catalog = readJsonSafe(CATALOG_FILE) || { routing_policy: {}, agents: {} };
  const ledger = readJsonSafe(LEDGER_FILE) || { agents: {}, history: [] };
  const now = Date.now();
  const ms5h = 5 * 3600 * 1000;
  const ms7d = 7 * 24 * 3600 * 1000;
  const startOfToday = new Date();
  startOfToday.setHours(0, 0, 0, 0);
  const todayMs = startOfToday.getTime();

  const runningByAgent = {};
  for (const t of health.running_tasks || []) {
    runningByAgent[t.agent] = (runningByAgent[t.agent] || 0) + 1;
  }

  const allIds = Array.from(
    new Set([
      ...Object.keys(catalog.agents || {}),
      ...Object.keys(health.available_agents || {}),
      ...Object.keys(ledger.agents || {}),
    ])
  );

  const agents = allIds.map((id) => {
    const cat = (catalog.agents && catalog.agents[id]) || {};
    const led = (ledger.agents && ledger.agents[id]) || {};
    const installed = Boolean(health.available_agents && health.available_agents[id]);
    const hist = (ledger.history || []).filter((h) => h.agent === id);

    let runs5h = 0, tokens5h = 0, runsToday = 0, tokensToday = 0, runs7d = 0, tokens7d = 0;
    for (const h of hist) {
      const ts = Date.parse(h.finished_at || "");
      if (!ts) continue;
      const tok = h.tokens || 0;
      if (now - ts <= ms5h) { runs5h++; tokens5h += tok; }
      if (ts >= todayMs) { runsToday++; tokensToday += tok; }
      if (now - ts <= ms7d) { runs7d++; tokens7d += tok; }
    }

    const cooldownUntilMs = led.cooldown_until ? Date.parse(led.cooldown_until) : 0;
    const inCooldown = cooldownUntilMs > now;
    const enabled = cat.enabled !== false;

    let effectiveStatus = "ready";
    if (!health.online) effectiveStatus = "dispatcher_offline";
    else if (!installed) effectiveStatus = "not_installed";
    else if (!enabled) effectiveStatus = "disabled";
    else if (inCooldown) effectiveStatus = "rate_limited";
    else if (led.health_status === "needs_login") effectiveStatus = "needs_login";
    else if ((runningByAgent[id] || 0) > 0) effectiveStatus = "busy";

    return {
      id,
      display_name: cat.display_name || id,
      effective_status: effectiveStatus,
      enabled,
      installed,
      tier: cat.tier || "medium",
      priority: cat.priority ?? 99,
      strengths: cat.strengths || [],
      quota_hint: cat.quota_hint || "",
      notes: cat.notes || "",
      running_now: runningByAgent[id] || 0,
      cooldown_until: inCooldown ? led.cooldown_until : null,
      last_reason: led.last_reason || null,
      last_run_at: led.last_run_at || null,
      last_status: led.last_status || null,
      usage: {
        last_5h: { runs: runs5h, tokens_reported: tokens5h },
        today: { runs: runsToday, tokens_reported: tokensToday },
        last_7d: { runs: runs7d, tokens_reported: tokens7d },
        total_runs: led.total_runs || 0,
      },
    };
  });

  agents.sort((a, b) => a.priority - b.priority);
  return {
    dispatcher_online: health.online,
    running_total: health.running_count || 0,
    max_concurrent: health.max_concurrent || 2,
    routing_policy: catalog.routing_policy || {},
    agents,
  };
}

function getTaskSnapshot(taskId) {
  const safeId = String(taskId || "").replace(/[^a-zA-Z0-9._-]/g, "_");
  const doneFile = path.join(DIRS.done, `${safeId}.result.json`);
  if (fs.existsSync(doneFile)) {
    const res = readJsonSafe(doneFile);
    if (res) return res;
  }
  const runFile = path.join(DIRS.running, `${safeId}.json`);
  if (fs.existsSync(runFile)) {
    const task = readJsonSafe(runFile) || { id: safeId };
    return {
      id: safeId,
      status: "running",
      agent: task.agent,
      project: task.project,
      cwd: task.cwd,
      stdout_tail: readTail(path.join(DIRS.logs, `${safeId}.stdout.log`), 3000),
      stderr_tail: readTail(path.join(DIRS.logs, `${safeId}.stderr.log`), 1500),
      hint: "Task is still running on host. Call host_task_status again to continue waiting.",
    };
  }
  const pendFile = path.join(DIRS.pending, `${safeId}.json`);
  if (fs.existsSync(pendFile)) {
    const task = readJsonSafe(pendFile) || { id: safeId };
    return {
      id: safeId,
      status: "pending",
      agent: task.agent,
      project: task.project,
      cwd: task.cwd,
      hint: "Task is queued. Check host_health if it remains pending.",
    };
  }
  return { id: safeId, status: "not_found", error: `Task not found: ${safeId}` };
}

async function waitForTask(taskId, waitSec) {
  const deadline = Date.now() + Math.max(0, waitSec) * 1000;
  while (true) {
    const snap = getTaskSnapshot(taskId);
    if (!["pending", "running"].includes(snap.status)) return snap;
    if (Date.now() >= deadline) return snap;
    await sleep(500);
  }
}

const TOOLS = [
  {
    name: "host_health",
    description: "Check whether the host-side dispatcher is online, which agents are available, and active tasks.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "host_agents_overview",
    description:
      "Return the host multi-agent capability, quota hint, cooldown/login health, 5h/today/7d usage stats, and routing policy board.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "host_update_agent_note",
    description:
      "Update an agent's quota_hint, enabled flag, or clear its cooldown/login status in the overview board.",
    inputSchema: {
      type: "object",
      properties: {
        agent: { type: "string", enum: ["dsh", "agy", "codex", "autoclaw", "workbuddy", "qoder"] },
        quota_hint: { type: "string" },
        enabled: { type: "boolean" },
        clear_status: { type: "boolean" },
      },
      required: ["agent"],
      additionalProperties: false,
    },
  },
  {
    name: "host_dispatch",
    description:
      "Dispatch a task to a whitelisted host agent (codex, agy/antigravity, autoclaw/zcode, qoder/qoderclicn, workbuddy/codebuddy, or dsh) via the shared-folder queue.",
    inputSchema: {
      type: "object",
      properties: {
        agent: {
          type: "string",
          enum: [
            "dsh",
            "agy",
            "antigravity",
            "codex",
            "autoclaw",
            "zcode",
            "workbuddy",
            "codebuddy",
            "qoder",
            "qodercli",
            "qoderclicn",
          ],
        },
        prompt: { type: "string" },
        project: { type: "string" },
        cwd: { type: "string" },
        mode: { type: "string", enum: ["auto", "read-only"] },
        model: { type: "string" },
        timeout_sec: { type: "integer" },
        wait: { type: "boolean" },
        wait_sec: { type: "integer" },
      },
      required: ["agent", "prompt"],
      additionalProperties: false,
    },
  },
  {
    name: "host_task_status",
    description: "Query a host task status, log tail, or final result (optionally waiting up to wait_sec).",
    inputSchema: {
      type: "object",
      properties: {
        task_id: { type: "string" },
        wait_sec: { type: "integer" },
      },
      required: ["task_id"],
      additionalProperties: false,
    },
  },
  {
    name: "host_list_tasks",
    description: "List pending, running, and recent completed host tasks.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer" } },
      additionalProperties: false,
    },
  },
  {
    name: "host_cancel_task",
    description: "Request cancellation of a pending or running host task.",
    inputSchema: {
      type: "object",
      properties: { task_id: { type: "string" } },
      required: ["task_id"],
      additionalProperties: false,
    },
  },
];

async function handleToolCall(name, args) {
  ensureDirs();
  if (name === "host_health") {
    return { text: JSON.stringify(getHealth(), null, 2) };
  }
  if (name === "host_agents_overview") {
    return { text: JSON.stringify(getAgentsOverview(), null, 2) };
  }
  if (name === "host_update_agent_note") {
    const id = String(args.agent || "").trim().toLowerCase();
    if (!["dsh", "agy", "codex", "autoclaw", "workbuddy", "qoder"].includes(id)) {
      return { isError: true, text: `Unsupported agent: ${args.agent}` };
    }
    const catalog = readJsonSafe(CATALOG_FILE) || { routing_policy: {}, agents: {} };
    catalog.agents = catalog.agents || {};
    catalog.agents[id] = catalog.agents[id] || { display_name: id, enabled: true };
    if (typeof args.quota_hint === "string") catalog.agents[id].quota_hint = args.quota_hint;
    if (typeof args.enabled === "boolean") catalog.agents[id].enabled = args.enabled;
    catalog.updated_at = new Date().toISOString();
    atomicWriteJson(CATALOG_FILE, catalog);
    if (args.clear_status) {
      const ledger = readJsonSafe(LEDGER_FILE);
      if (ledger && ledger.agents && ledger.agents[id]) {
        ledger.agents[id].health_status = "ready";
        ledger.agents[id].cooldown_until = null;
        ledger.agents[id].last_reason = null;
        ledger.updated_at = new Date().toISOString();
        atomicWriteJson(LEDGER_FILE, ledger);
      }
    }
    return {
      text: JSON.stringify({ updated: id, overview: getAgentsOverview().agents.find((a) => a.id === id) }, null, 2),
    };
  }
  if (name === "host_dispatch") {
    const rawAgent = String(args.agent || "").trim().toLowerCase();
    const aliasMap = {
      antigravity: "agy",
      agy: "agy",
      dsh: "dsh",
      codex: "codex",
      autoclaw: "autoclaw",
      zcode: "autoclaw",
      workbuddy: "workbuddy",
      codebuddy: "workbuddy",
      qoder: "qoder",
      qodercli: "qoder",
      qoderclicn: "qoder",
      qodercn: "qoder",
    };
    const agent = aliasMap[rawAgent];
    if (!agent) {
      return { isError: true, text: `Unsupported agent: ${args.agent}` };
    }
    if (!args.prompt || !String(args.prompt).trim()) {
      return { isError: true, text: "prompt is required" };
    }
    const health = getHealth();
    const taskId = makeTaskId(agent);
    atomicWriteJson(path.join(DIRS.pending, `${taskId}.json`), {
      id: taskId,
      origin: "guest-agent",
      created_at: new Date().toISOString(),
      agent,
      prompt: String(args.prompt),
      project: args.project || null,
      cwd: args.cwd || null,
      mode: args.mode || "auto",
      model: args.model || null,
      timeout_sec: Math.min(1800, Math.max(30, parseInt(args.timeout_sec || "600", 10) || 600)),
    });
    if (args.wait === false) {
      return {
        text: JSON.stringify({ id: taskId, status: "pending", dispatcher_online: health.online }, null, 2),
      };
    }
    const waitSec = Math.min(240, Math.max(1, parseInt(args.wait_sec || "55", 10) || 55));
    const snap = await waitForTask(taskId, waitSec);
    return { text: JSON.stringify(snap, null, 2) };
  }
  if (name === "host_task_status") {
    const waitSec = Math.min(240, Math.max(0, parseInt(args.wait_sec || "0", 10) || 0));
    const snap = waitSec > 0 ? await waitForTask(args.task_id, waitSec) : getTaskSnapshot(args.task_id);
    return { text: JSON.stringify(snap, null, 2) };
  }
  if (name === "host_list_tasks") {
    const limit = Math.min(50, Math.max(1, parseInt(args.limit || "10", 10) || 10));
    const listDir = (dir, suffix) =>
      fs
        .readdirSync(dir)
        .filter((f) => f.endsWith(suffix))
        .map((f) => ({ file: path.join(dir, f), mtimeMs: fs.statSync(path.join(dir, f)).mtimeMs }))
        .sort((a, b) => b.mtimeMs - a.mtimeMs);
    const pending = listDir(DIRS.pending, ".json").map((x) => readJsonSafe(x.file));
    const running = listDir(DIRS.running, ".json").map((x) => readJsonSafe(x.file));
    const done = listDir(DIRS.done, ".result.json")
      .slice(0, limit)
      .map((x) => readJsonSafe(x.file))
      .filter(Boolean)
      .map((d) => ({ id: d.id, agent: d.agent, status: d.status, cwd: d.cwd, duration_ms: d.duration_ms }));
    return { text: JSON.stringify({ pending, running, done }, null, 2) };
  }
  if (name === "host_cancel_task") {
    const safeId = String(args.task_id || "").replace(/[^a-zA-Z0-9._-]/g, "_");
    if (!safeId) return { isError: true, text: "task_id is required" };
    fs.writeFileSync(path.join(DIRS.cancel, `${safeId}.cancel`), new Date().toISOString(), "utf8");
    return { text: JSON.stringify({ id: safeId, cancel_requested: true }, null, 2) };
  }
  return { isError: true, text: `Unknown tool: ${name}` };
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", async (line) => {
  const s = line.trim();
  if (!s) return;
  let req;
  try {
    req = JSON.parse(s);
  } catch {
    return;
  }
  const { id, method, params } = req;
  if (id === undefined || id === null) return;

  try {
    if (method === "initialize") {
      send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: (params && params.protocolVersion) || "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "host-dispatch", version: "1.0.0" },
        },
      });
      return;
    }
    if (method === "ping") {
      send({ jsonrpc: "2.0", id, result: {} });
      return;
    }
    if (method === "tools/list") {
      send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
      return;
    }
    if (method === "tools/call") {
      const out = await handleToolCall(params?.name, params?.arguments || {});
      send({
        jsonrpc: "2.0",
        id,
        result: { content: [{ type: "text", text: out.text }], isError: Boolean(out.isError) },
      });
      return;
    }
    send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
  } catch (err) {
    send({ jsonrpc: "2.0", id, error: { code: -32603, message: err?.message || String(err) } });
  }
});
