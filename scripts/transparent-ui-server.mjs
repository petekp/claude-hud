#!/usr/bin/env node
import http from "http";
import os from "os";
import path from "path";
import net from "net";

const PORT = Number(process.env.PORT || 9133);
const SOCKET_PATH = process.env.CAPACITOR_DAEMON_SOCK
  || path.join(os.homedir(), ".capacitor", "daemon.sock");
const TELEMETRY_LIMIT = Number(process.env.CAPACITOR_TELEMETRY_LIMIT || 500);
const BRIEFING_SHELL_LIMIT = Number(process.env.CAPACITOR_BRIEFING_SHELL_LIMIT || 25);

const telemetryClients = new Set();
const telemetryEvents = [];

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

function chooseRoutingProjectPath(projectStates = [], sessions = []) {
  const normalizedStates = Array.isArray(projectStates) ? projectStates : [];
  const normalizedSessions = Array.isArray(sessions) ? sessions : [];

  const workingProject = normalizedStates
    .filter(entry => String(entry?.state || "").toLowerCase() === "working")
    .sort((a, b) => parseTimestamp(b?.updated_at) - parseTimestamp(a?.updated_at))[0];
  if (workingProject?.project_path) return workingProject.project_path;

  const recentSession = normalizedSessions
    .filter(entry => typeof entry?.project_path === "string" && entry.project_path.length > 0)
    .sort((a, b) => parseTimestamp(b?.updated_at) - parseTimestamp(a?.updated_at))[0];
  if (recentSession?.project_path) return recentSession.project_path;

  return normalizedStates.find(entry => entry?.project_path)?.project_path || null;
}

async function requestDaemon(method, params = undefined) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKET_PATH);
    let data = "";
    let settled = false;

    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      try {
        socket.destroy();
      } catch {
        // ignore
      }
      fn(value);
    };

    socket.setTimeout(2000);

    socket.on("connect", () => {
      const payload = {
        protocol_version: 1,
        method,
        id: `req-${Date.now()}-${Math.random().toString(16).slice(2, 6)}`
      };
      if (params !== undefined) payload.params = params;
      socket.write(`${JSON.stringify(payload)}\n`);
    });

    socket.on("data", chunk => {
      data += chunk.toString("utf8");
      if (data.includes("\n")) {
        const line = data.split("\n", 1)[0];
        try {
          finish(resolve, JSON.parse(line));
        } catch (error) {
          finish(reject, error);
        }
      }
    });

    socket.on("timeout", () => finish(reject, new Error("daemon request timeout")));
    socket.on("error", error => finish(reject, error));
    socket.on("end", () => {
      if (settled) return;
      try {
        const trimmed = data.trim();
        finish(resolve, trimmed ? JSON.parse(trimmed) : {});
      } catch (error) {
        finish(reject, error);
      }
    });
  });
}

function parseRoutingParams(url) {
  const projectPath = url.searchParams.get("project_path") || "";
  const workspaceId = url.searchParams.get("workspace_id") || undefined;
  return { projectPath: projectPath.trim(), workspaceId };
}

async function requestRoutingSnapshot(projectPath, workspaceId) {
  if (!projectPath) return null;
  const params = { project_path: projectPath };
  if (workspaceId) params.workspace_id = workspaceId;
  try {
    const response = await requestDaemon("get_routing_snapshot", params);
    return response && response.ok ? response.data : null;
  } catch {
    return null;
  }
}

async function requestRoutingDiagnostics(projectPath, workspaceId) {
  if (!projectPath) return null;
  const params = { project_path: projectPath };
  if (workspaceId) params.workspace_id = workspaceId;
  try {
    const response = await requestDaemon("get_routing_diagnostics", params);
    return response && response.ok ? response.data : null;
  } catch {
    return null;
  }
}

async function buildSnapshot(options = {}) {
  try {
    const [sessions, projectStates, shellState, health, activity] = await Promise.all([
      requestDaemon("get_sessions"),
      requestDaemon("get_project_states"),
      requestDaemon("get_shell_state"),
      requestDaemon("get_health"),
      requestDaemon("get_activity", { limit: 120 })
    ]);

    const sessionsData = sessions && sessions.ok ? sessions.data : [];
    const projectStatesData = projectStates && projectStates.ok ? projectStates.data : [];
    const shellData = shellState && shellState.ok ? shellState.data : { version: 1, shells: {} };
    const healthData = health && health.ok ? health.data : null;
    const activityData = activity && activity.ok ? activity.data : [];

    const normalizedShellState = normalizeShellState(shellData, {
      mode: options.shellsMode || "all",
      limit: options.shellLimit
    });

    const projectPath = options.projectPath || chooseRoutingProjectPath(projectStatesData, sessionsData);
    const workspaceId = options.workspaceId;
    const [routingSnapshot, routingDiagnostics] = await Promise.all([
      requestRoutingSnapshot(projectPath, workspaceId),
      requestRoutingDiagnostics(projectPath, workspaceId)
    ]);

    return {
      ok: true,
      timestamp: new Date().toISOString(),
      sessions: sessionsData,
      project_states: projectStatesData,
      activity: activityData,
      shell_state: normalizedShellState,
      health: healthData,
      routing: {
        project_path: projectPath,
        workspace_id: workspaceId || null,
        snapshot: routingSnapshot,
        diagnostics: routingDiagnostics,
        rollout: healthData && healthData.routing ? healthData.routing.rollout || null : null,
        health: healthData && healthData.routing ? healthData.routing : null
      }
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

  const snapshot = await buildSnapshot({
    shellsMode,
    shellLimit,
    projectPath: options.projectPath,
    workspaceId: options.workspaceId
  });

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
  const routing = snapshot.routing || {};

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
      routing: {
        project_path: routing.project_path || null,
        status: routing.snapshot ? routing.snapshot.status : null,
        reason_code: routing.snapshot ? routing.snapshot.reason_code : null,
        comparisons: routing.rollout ? routing.rollout.comparisons : null,
        status_row_default_ready: routing.rollout ? routing.rollout.status_row_default_ready : null,
        launcher_default_ready: routing.rollout ? routing.rollout.launcher_default_ready : null
      },
      telemetry: { count: telemetry.length, limit }
    },
    request: {
      limit,
      shells: shellsMode,
      shell_limit: shellLimit,
      project_path: options.projectPath || null,
      workspace_id: options.workspaceId || null
    },
    endpoints: {
      telemetry: "/telemetry",
      telemetryStream: "/telemetry-stream",
      daemonSnapshot: "/daemon-snapshot",
      routingSnapshot: "/routing-snapshot",
      routingDiagnostics: "/routing-diagnostics",
      routingRollout: "/routing-rollout",
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

  if (req.url.startsWith("/telemetry-stream")) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
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

  if (req.url.startsWith("/routing-snapshot")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const { projectPath, workspaceId } = parseRoutingParams(url);
    if (!projectPath) {
      jsonResponse(res, 400, {
        ok: false,
        error: "project_path query param is required"
      });
      return;
    }
    try {
      const params = { project_path: projectPath };
      if (workspaceId) params.workspace_id = workspaceId;
      const response = await requestDaemon("get_routing_snapshot", params);
      jsonResponse(res, 200, {
        ok: Boolean(response && response.ok),
        timestamp: new Date().toISOString(),
        project_path: projectPath,
        workspace_id: workspaceId || null,
        response
      });
    } catch (error) {
      jsonResponse(res, 200, {
        ok: false,
        timestamp: new Date().toISOString(),
        project_path: projectPath,
        workspace_id: workspaceId || null,
        error: String(error)
      });
    }
    return;
  }

  if (req.url.startsWith("/routing-diagnostics")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const { projectPath, workspaceId } = parseRoutingParams(url);
    if (!projectPath) {
      jsonResponse(res, 400, {
        ok: false,
        error: "project_path query param is required"
      });
      return;
    }
    try {
      const params = { project_path: projectPath };
      if (workspaceId) params.workspace_id = workspaceId;
      const response = await requestDaemon("get_routing_diagnostics", params);
      jsonResponse(res, 200, {
        ok: Boolean(response && response.ok),
        timestamp: new Date().toISOString(),
        project_path: projectPath,
        workspace_id: workspaceId || null,
        response
      });
    } catch (error) {
      jsonResponse(res, 200, {
        ok: false,
        timestamp: new Date().toISOString(),
        project_path: projectPath,
        workspace_id: workspaceId || null,
        error: String(error)
      });
    }
    return;
  }

  if (req.url.startsWith("/routing-rollout")) {
    try {
      const health = await requestDaemon("get_health");
      const routing = health && health.ok && health.data ? health.data.routing || null : null;
      jsonResponse(res, 200, {
        ok: Boolean(health && health.ok),
        timestamp: new Date().toISOString(),
        routing,
        rollout: routing ? routing.rollout || null : null
      });
    } catch (error) {
      jsonResponse(res, 200, {
        ok: false,
        timestamp: new Date().toISOString(),
        error: String(error)
      });
    }
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
    const projectPath = (url.searchParams.get("project_path") || "").trim() || undefined;
    const workspaceId = (url.searchParams.get("workspace_id") || "").trim() || undefined;
    const briefing = await buildBriefing({ limit, shellsMode, shellLimit, projectPath, workspaceId });
    jsonResponse(res, 200, briefing);
    return;
  }

  if (req.url.startsWith("/daemon-snapshot")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const shellsParam = url.searchParams.get("shells");
    const shellsMode = shellsParam === "all" ? "all" : "recent";
    const shellLimitParam = Number(url.searchParams.get("shell_limit"));
    const shellLimit = Number.isFinite(shellLimitParam) && shellLimitParam > 0
      ? shellLimitParam
      : BRIEFING_SHELL_LIMIT;
    const projectPath = (url.searchParams.get("project_path") || "").trim() || undefined;
    const workspaceId = (url.searchParams.get("workspace_id") || "").trim() || undefined;
    const snapshot = await buildSnapshot({ shellsMode, shellLimit, projectPath, workspaceId });
    jsonResponse(res, 200, snapshot);
    return;
  }

  jsonResponse(res, 200, {
    ok: true,
    endpoints: {
      telemetry: "/telemetry",
      telemetryStream: "/telemetry-stream",
      daemonSnapshot: "/daemon-snapshot",
      routingSnapshot: "/routing-snapshot",
      routingDiagnostics: "/routing-diagnostics",
      routingRollout: "/routing-rollout",
      agentBriefing: "/agent-briefing"
    },
    socketPath: SOCKET_PATH
  });
});

server.listen(PORT, () => {
  console.log(`transparent-ui server listening on http://localhost:${PORT}`);
  console.log(`daemon sock: ${SOCKET_PATH}`);
});

setInterval(() => {
  telemetryClients.forEach(res => {
    try {
      res.write(": ping\n\n");
    } catch {
      telemetryClients.delete(res);
    }
  });
}, 15000);
