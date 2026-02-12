#!/usr/bin/env node
import http from "http";
import fs from "fs";
import os from "os";
import path from "path";
import net from "net";

const PORT = Number(process.env.PORT || 9133);
const LOG_PATH = process.env.CAPACITOR_TRACE_LOG
  || path.join(os.homedir(), ".capacitor", "daemon", "app-debug.log");
const SOCKET_PATH = process.env.CAPACITOR_DAEMON_SOCK
  || path.join(os.homedir(), ".capacitor", "daemon.sock");
const TELEMETRY_LIMIT = Number(process.env.CAPACITOR_TELEMETRY_LIMIT || 500);
const BRIEFING_SHELL_LIMIT = Number(process.env.CAPACITOR_BRIEFING_SHELL_LIMIT || 25);

const sseClients = new Set();
const telemetryClients = new Set();
const telemetryEvents = [];
let filePosition = 0;
let currentTrace = null;
let flushTimer = null;
let lastShellState = null;
let lastShellStateAt = 0;

function jsonResponse(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*"
  });
  res.end(body);
}

function sendSse(res, payload) {
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function broadcast(payload) {
  sseClients.forEach(res => {
    try {
      sendSse(res, payload);
    } catch {
      sseClients.delete(res);
    }
  });
}

function broadcastTelemetry(payload) {
  telemetryClients.forEach(res => {
    try {
      sendSse(res, payload);
    } catch {
      telemetryClients.delete(res);
    }
  });
}

function addTelemetryEvent(event) {
  const receivedAt = new Date().toISOString();
  const entry = {
    id: `telemetry-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    received_at: receivedAt,
    ...event
  };
  telemetryEvents.unshift(entry);
  if (telemetryEvents.length > TELEMETRY_LIMIT) {
    telemetryEvents.length = TELEMETRY_LIMIT;
  }
  broadcastTelemetry(entry);
}

function parseTimestamp(value) {
  if (!value) return 0;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeShellState(shellState, options = {}) {
  const mode = options.mode === "all" ? "all" : "recent";
  const limit = Number.isFinite(options.limit) && options.limit > 0
    ? options.limit
    : BRIEFING_SHELL_LIMIT;
  const base = shellState && typeof shellState === "object"
    ? shellState
    : { version: 1, shells: {} };
  const shellsMap = base.shells && typeof base.shells === "object" ? base.shells : {};
  const entries = Object.entries(shellsMap);
  const totalCount = entries.length;
  let selectedEntries = entries;
  if (mode !== "all") {
    selectedEntries = entries
      .sort((a, b) => parseTimestamp(b[1]?.updated_at) - parseTimestamp(a[1]?.updated_at))
      .slice(0, limit);
  }
  const shells = Object.fromEntries(selectedEntries);
  return {
    ...base,
    shells,
    total_count: totalCount,
    recent_count: selectedEntries.length,
    selection: mode,
    selection_limit: mode === "all" ? totalCount : limit
  };
}

function parsePreferLine(line) {
  const match = line.match(/ActivationTrace preferTmux=(true|false) selectedPid=([0-9]+|nil)/);
  if (!match) return null;
  return {
    prefer_tmux: match[1] === "true",
    selected_pid: match[2] === "nil" ? null : Number(match[2]),
    policy_order: [],
    candidates: []
  };
}

function parsePolicyLine(line) {
  const match = line.match(/ActivationTrace policyOrder=(.*)/);
  if (!match) return null;
  return match[1].split(" | ").map(value => value.trim()).filter(Boolean);
}

function parseCandidateLine(line) {
  const match = line.match(
    /ActivationTrace candidate pid=([0-9]+) match=([^ ]+) rank=([0-9]+) live=(true|false) tmux=(true|false) updatedAt=([^ ]+) parent=(.*)/
  );
  if (!match) return null;
  return {
    pid: Number(match[1]),
    match: match[2],
    match_rank: Number(match[3]),
    live: match[4] === "true",
    tmux: match[5] === "true",
    updated_at: match[6],
    parent: match[7],
    rank_key: []
  };
}

function parseRankKeyLine(line) {
  const match = line.match(/ActivationTrace rankKey=(.*)/);
  if (!match) return null;
  return match[1].split(", ").map(item => item.trim()).filter(Boolean);
}

function scheduleFlush() {
  if (flushTimer) clearTimeout(flushTimer);
  flushTimer = setTimeout(() => {
    flushTimer = null;
    flushTrace();
  }, 200);
}

async function requestDaemon(method, params = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKET_PATH);
    let data = "";
    socket.on("connect", () => {
      const payload = {
        protocol_version: 1,
        method,
        id: `req-${Date.now()}`,
        params
      };
      socket.write(`${JSON.stringify(payload)}\n`);
    });
    socket.on("data", chunk => {
      data += chunk.toString("utf8");
    });
    socket.on("end", () => {
      try {
        resolve(JSON.parse(data));
      } catch (error) {
        reject(error);
      }
    });
    socket.on("error", reject);
  });
}

async function getShellState() {
  const now = Date.now();
  if (lastShellState && now - lastShellStateAt < 2000) {
    return lastShellState;
  }
  try {
    const response = await requestDaemon("get_shell_state");
    if (response && response.ok) {
      lastShellState = response.data;
      lastShellStateAt = now;
      return response.data;
    }
  } catch {
    // ignore
  }
  return null;
}

async function flushTrace() {
  if (!currentTrace) return;
  const trace = currentTrace;
  currentTrace = null;

  const shellState = await getShellState();
  const shells = shellState && shellState.shells ? shellState.shells : {};

  const candidates = trace.candidates.map(candidate => {
    const shell = shells[String(candidate.pid)] || {};
    return {
      pid: candidate.pid,
      cwd: shell.cwd,
      tty: shell.tty,
      match: candidate.match,
      match_rank: candidate.match_rank,
      live: candidate.live,
      tmux: candidate.tmux,
      parent: shell.parent_app || candidate.parent,
      rank_key: candidate.rank_key
    };
  });

  const decision = {
    prefer_tmux: trace.prefer_tmux,
    policy_order: trace.policy_order,
    selected_pid: trace.selected_pid,
    candidates
  };

  broadcast({
    flowId: "activation",
    edgeId: "e11",
    action: "activation-trace",
    detail: `ActivationTrace selectedPid=${trace.selected_pid ?? "nil"}`,
    decision
  });
}

function handleTraceLine(line) {
  if (!line.includes("ActivationTrace")) return;

  const prefer = parsePreferLine(line);
  if (prefer) {
    if (currentTrace) {
      flushTrace();
    }
    currentTrace = prefer;
    scheduleFlush();
    return;
  }

  if (!currentTrace) return;

  const policy = parsePolicyLine(line);
  if (policy) {
    currentTrace.policy_order = policy;
    scheduleFlush();
    return;
  }

  const candidate = parseCandidateLine(line);
  if (candidate) {
    currentTrace.candidates.push(candidate);
    scheduleFlush();
    return;
  }

  const rankKey = parseRankKeyLine(line);
  if (rankKey && currentTrace.candidates.length > 0) {
    currentTrace.candidates[currentTrace.candidates.length - 1].rank_key = rankKey;
    scheduleFlush();
  }
}

async function readNewLines() {
  try {
    const stats = await fs.promises.stat(LOG_PATH);
    if (stats.size < filePosition) {
      filePosition = 0;
    }
    if (stats.size === filePosition) return;

    const handle = await fs.promises.open(LOG_PATH, "r");
    const length = stats.size - filePosition;
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, filePosition);
    await handle.close();
    filePosition = stats.size;

    const chunk = buffer.toString("utf8");
    chunk.split(/\r?\n/).forEach(line => {
      if (line.trim().length > 0) {
        handleTraceLine(line.trim());
      }
    });
  } catch {
    // ignore if file doesn't exist yet
  }
}

async function startTail() {
  try {
    const stats = await fs.promises.stat(LOG_PATH);
    filePosition = stats.size;
  } catch {
    filePosition = 0;
  }

  try {
    fs.watch(path.dirname(LOG_PATH), (event, filename) => {
      if (!filename || filename !== path.basename(LOG_PATH)) return;
      readNewLines();
    });
  } catch {
    // directory may not exist yet; polling will still pick up changes
  }

  setInterval(readNewLines, 1000);
}

async function buildSnapshot(options = {}) {
  try {
    const [sessions, projectStates, shellState, health] = await Promise.all([
      requestDaemon("get_sessions"),
      requestDaemon("get_project_states"),
      requestDaemon("get_shell_state"),
      requestDaemon("get_health")
    ]);
    const shellData = shellState && shellState.ok ? shellState.data : { version: 1, shells: {} };
    const normalizedShellState = normalizeShellState(shellData, {
      mode: options.shellsMode || "all",
      limit: options.shellLimit
    });
    return {
      ok: true,
      timestamp: new Date().toISOString(),
      sessions: sessions && sessions.ok ? sessions.data : [],
      project_states: projectStates && projectStates.ok ? projectStates.data : [],
      shell_state: normalizedShellState,
      health: health && health.ok ? health.data : null
    };
  } catch (error) {
    return {
      ok: false,
      error: String(error),
      timestamp: new Date().toISOString()
    };
  }
}

async function buildBriefing(options = {}) {
  const limit = Number.isFinite(options.limit) ? options.limit : 200;
  const shellsMode = options.shellsMode === "all" ? "all" : "recent";
  const shellLimit = Number.isFinite(options.shellLimit) ? options.shellLimit : BRIEFING_SHELL_LIMIT;
  const snapshot = await buildSnapshot();
  if (snapshot && snapshot.shell_state) {
    snapshot.shell_state = normalizeShellState(snapshot.shell_state, {
      mode: shellsMode,
      limit: shellLimit
    });
  }
  const sessions = Array.isArray(snapshot.sessions) ? snapshot.sessions : [];
  const projects = Array.isArray(snapshot.project_states) ? snapshot.project_states : [];
  const shellState = snapshot.shell_state || {};
  const health = snapshot.health && typeof snapshot.health === "object" ? snapshot.health : null;
  const totalShells = Number.isFinite(shellState.total_count) ? shellState.total_count : 0;
  const recentShells = Number.isFinite(shellState.recent_count) ? shellState.recent_count : 0;
  const telemetry = telemetryEvents.slice(0, limit);
  return {
    ok: true,
    timestamp: new Date().toISOString(),
    snapshot,
    telemetry,
    summary: {
      sessions: { count: sessions.length },
      projects: { count: projects.length },
      shells: {
        total: totalShells,
        recent: recentShells,
        mode: shellState.selection || shellsMode,
        limit: shellState.selection_limit || shellLimit
      },
      daemon: {
        status: health && typeof health.status === "string" ? health.status : "unknown",
        pid: health && Number.isFinite(health.pid) ? health.pid : null,
        version: health && typeof health.version === "string" ? health.version : null
      },
      telemetry: { count: telemetry.length, limit }
    },
    request: {
      limit,
      shells: shellsMode,
      shell_limit: shellLimit
    },
    endpoints: {
      activationTrace: "/activation-trace",
      telemetry: "/telemetry",
      telemetryStream: "/telemetry-stream",
      daemonSnapshot: "/daemon-snapshot",
      agentBriefing: "/agent-briefing"
    }
  };
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (!req.url) {
    jsonResponse(res, 400, { ok: false, error: "missing url" });
    return;
  }

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type"
    });
    res.end();
    return;
  }

  if (req.url.startsWith("/activation-trace")) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
      "Access-Control-Allow-Origin": "*"
    });
    res.write(": connected\n\n");
    sseClients.add(res);
    req.on("close", () => sseClients.delete(res));
    return;
  }

  if (req.url.startsWith("/telemetry-stream")) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
      "Access-Control-Allow-Origin": "*"
    });
    res.write(": connected\n\n");
    telemetryClients.add(res);
    req.on("close", () => telemetryClients.delete(res));
    return;
  }

  if (req.url.startsWith("/telemetry") && req.method === "POST") {
    try {
      const body = await readRequestBody(req);
      const payload = body ? JSON.parse(body) : {};
      addTelemetryEvent(payload || {});
      jsonResponse(res, 200, { ok: true });
    } catch (error) {
      jsonResponse(res, 400, { ok: false, error: String(error) });
    }
    return;
  }

  if (req.url.startsWith("/telemetry")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const limit = Math.min(Number(url.searchParams.get("limit") || 50), TELEMETRY_LIMIT);
    jsonResponse(res, 200, {
      ok: true,
      timestamp: new Date().toISOString(),
      events: telemetryEvents.slice(0, limit)
    });
    return;
  }

  if (req.url.startsWith("/agent-briefing")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const limit = Math.min(Number(url.searchParams.get("limit") || 200), TELEMETRY_LIMIT);
    const shellsParam = url.searchParams.get("shells");
    const shellsMode = shellsParam === "all" ? "all" : "recent";
    const shellLimitParam = Number(url.searchParams.get("shell_limit"));
    const shellLimit = Number.isFinite(shellLimitParam) && shellLimitParam > 0
      ? shellLimitParam
      : BRIEFING_SHELL_LIMIT;
    const briefing = await buildBriefing({ limit, shellsMode, shellLimit });
    jsonResponse(res, 200, briefing);
    return;
  }

  if (req.url.startsWith("/daemon-snapshot")) {
    const snapshot = await buildSnapshot();
    jsonResponse(res, 200, snapshot);
    return;
  }

  jsonResponse(res, 200, {
    ok: true,
    endpoints: {
      activationTrace: "/activation-trace",
      telemetry: "/telemetry",
      telemetryStream: "/telemetry-stream",
      agentBriefing: "/agent-briefing",
      daemonSnapshot: "/daemon-snapshot"
    },
    logPath: LOG_PATH,
    socketPath: SOCKET_PATH
  });
});

server.listen(PORT, () => {
  console.log(`transparent-ui server listening on http://localhost:${PORT}`);
  console.log(`trace log: ${LOG_PATH}`);
  console.log(`daemon sock: ${SOCKET_PATH}`);
});

setInterval(() => {
  sseClients.forEach(res => {
    try {
      res.write(": ping\n\n");
    } catch {
      sseClients.delete(res);
    }
  });
  telemetryClients.forEach(res => {
    try {
      res.write(": ping\n\n");
    } catch {
      telemetryClients.delete(res);
    }
  });
}, 15000);

startTail();
