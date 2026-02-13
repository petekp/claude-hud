(function(root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.SessionMachineModel = factory();
  }
})(typeof self !== "undefined" ? self : this, function() {
  const STOP_GATE_GRACE_SECONDS = 20;
  const AUTO_READY_SECONDS = 60;

  const STATES = ["working", "waiting", "compacting", "ready", "idle"];

  const GRAPH_TRANSITIONS = [
    {
      id: "session_start_to_ready",
      from: "idle",
      to: "ready",
      trigger: "session_start",
      guardKey: "session_start_when_not_active",
      guardDescription: "Reducer skips session_start if current state is active."
    },
    {
      id: "prompt_to_working",
      from: "ready",
      to: "working",
      trigger: "user_prompt_submit/pre_tool_use",
      guardKey: null,
      guardDescription: null
    },
    {
      id: "permission_to_waiting",
      from: "working",
      to: "waiting",
      trigger: "permission_request/notification.permission_prompt",
      guardKey: null,
      guardDescription: null
    },
    {
      id: "compaction_start",
      from: "working",
      to: "compacting",
      trigger: "pre_compact",
      guardKey: null,
      guardDescription: null
    },
    {
      id: "idle_prompt_ready",
      from: "working",
      to: "ready",
      trigger: "notification.idle_prompt",
      guardKey: "tools_in_flight",
      guardDescription: "idle_prompt -> ready only when tools_in_flight == 0."
    },
    {
      id: "stop_to_ready",
      from: "working",
      to: "ready",
      trigger: "stop",
      guardKey: "stop_event_guards",
      guardDescription: "Skip stop when compacting, stop_hook_active=true, or metadata.agent_id exists."
    },
    {
      id: "task_completed_to_ready",
      from: "working",
      to: "ready",
      trigger: "task_completed",
      guardKey: null,
      guardDescription: null
    },
    {
      id: "session_end_to_idle",
      from: "ready",
      to: "idle",
      trigger: "session_end",
      guardKey: null,
      guardDescription: "Reducer deletes session on session_end."
    },
    {
      id: "effective_stop_gate",
      from: "ready",
      to: "working",
      trigger: "effective.stop_gate_grace",
      guardKey: "stop_gate_grace",
      guardDescription: "Ready stop_gate stays working while pid is alive and within grace."
    },
    {
      id: "effective_dead_pid",
      from: "ready",
      to: "idle",
      trigger: "effective.dead_pid",
      guardKey: "dead_or_unknown_pid",
      guardDescription: "Ready session collapses to idle when pid is dead."
    },
    {
      id: "effective_auto_ready",
      from: "working",
      to: "ready",
      trigger: "effective.auto_ready",
      guardKey: "task_completed_auto_ready",
      guardDescription: "Auto-ready requires task_completed, tools=0, >=60s inactivity."
    }
  ];

  function parseTimestamp(value) {
    if (!value || typeof value !== "string") return null;
    const ms = Date.parse(value);
    return Number.isFinite(ms) ? ms : null;
  }

  function normalizeState(value) {
    const normalized = String(value || "").toLowerCase();
    if (STATES.includes(normalized)) return normalized;
    return "idle";
  }

  function stopGateGraceActive(session, nowMs) {
    if (normalizeState(session.state) !== "ready") return false;
    if (session.ready_reason !== "stop_gate" && session.readyReason !== "stop_gate") return false;
    if (session.is_alive !== true && session.isAlive !== true) return false;
    const updated = parseTimestamp(session.updated_at || session.updatedAt);
    if (!updated) return false;
    return nowMs - updated <= STOP_GATE_GRACE_SECONDS * 1000;
  }

  function autoReadyActive(session, nowMs) {
    if (normalizeState(session.state) !== "working") return false;
    const lastEvent = session.last_event || session.lastEvent;
    if (lastEvent !== "task_completed") return false;
    const toolsInFlight = session.tools_in_flight != null ? session.tools_in_flight : session.toolsInFlight;
    if ((toolsInFlight || 0) !== 0) return false;
    const lastActivity = parseTimestamp(session.last_activity_at || session.lastActivityAt);
    const updated = parseTimestamp(session.updated_at || session.updatedAt);
    if (!lastActivity || !updated) return false;
    if (nowMs - lastActivity < AUTO_READY_SECONDS * 1000) return false;
    return nowMs - updated >= AUTO_READY_SECONDS * 1000;
  }

  function effectiveState(session, nowMs) {
    const now = Number.isFinite(nowMs) ? nowMs : Date.now();
    const raw = normalizeState(session.state);
    if (raw === "ready") {
      if (stopGateGraceActive(session, now)) return "working";
      if (session.is_alive === false || session.isAlive === false) return "idle";
    }
    if (raw === "working" && autoReadyActive(session, now)) return "ready";
    return raw;
  }

  function inferTransition(previousSession, currentSession, nowMs) {
    const now = Number.isFinite(nowMs) ? nowMs : Date.now();
    const from = previousSession ? effectiveState(previousSession, now) : normalizeState(currentSession.state);
    const to = effectiveState(currentSession, now);
    const lastEvent = currentSession.last_event || currentSession.lastEvent;

    if (from === to && !lastEvent) {
      return null;
    }

    let trigger = lastEvent || "session_snapshot";
    let guardKey = null;

    if (stopGateGraceActive(currentSession, now)) {
      trigger = "effective.stop_gate_grace";
      guardKey = "stop_gate_grace";
    } else if (normalizeState(currentSession.state) === "ready" && (currentSession.is_alive === false || currentSession.isAlive === false)) {
      trigger = "effective.dead_pid";
      guardKey = "dead_or_unknown_pid";
    } else if (autoReadyActive(currentSession, now)) {
      trigger = "effective.auto_ready";
      guardKey = "task_completed_auto_ready";
    }

    return {
      from,
      to,
      trigger,
      guardKey
    };
  }

  function guardStatusToolsInFlight(session) {
    const toolsInFlight = session.tools_in_flight != null ? session.tools_in_flight : session.toolsInFlight;
    if (toolsInFlight == null) {
      return {
        status: "unknown",
        detail: "tools_in_flight missing in daemon snapshot."
      };
    }
    if (toolsInFlight > 0) {
      return {
        status: "active",
        detail: `tools_in_flight=${toolsInFlight}. idle_prompt/auto-ready blocked.`
      };
    }
    return {
      status: "inactive",
      detail: "tools_in_flight=0. idle_prompt/auto-ready eligible."
    };
  }

  function guardStatusPid(session) {
    const isAlive = session.is_alive != null ? session.is_alive : session.isAlive;
    if (isAlive === true) {
      return {
        status: "inactive",
        detail: "PID alive."
      };
    }
    if (isAlive === false) {
      return {
        status: "active",
        detail: "PID dead; ready state collapses to idle."
      };
    }
    return {
      status: "unknown",
      detail: "PID unknown (pid=0 or unavailable)."
    };
  }

  function evaluateGuards(session, nowMs) {
    const now = Number.isFinite(nowMs) ? nowMs : Date.now();
    const tools = guardStatusToolsInFlight(session);
    const pid = guardStatusPid(session);
    return [
      {
        key: "stop_gate_grace",
        label: "stop-gate grace",
        status: stopGateGraceActive(session, now) ? "active" : "inactive",
        detail: `ready_reason=stop_gate && is_alive=true && age<=${STOP_GATE_GRACE_SECONDS}s`
      },
      {
        key: "task_completed_auto_ready",
        label: "task_completed auto-ready",
        status: autoReadyActive(session, now) ? "active" : "inactive",
        detail: `working + task_completed + tools=0 + inactivity>=${AUTO_READY_SECONDS}s`
      },
      {
        key: "tools_in_flight",
        label: "tools in flight gate",
        status: tools.status,
        detail: tools.detail
      },
      {
        key: "dead_or_unknown_pid",
        label: "dead/unknown pid",
        status: pid.status,
        detail: pid.detail
      },
      {
        key: "stop_hook_active",
        label: "stop_hook_active skip",
        status: "unknown",
        detail: "Only visible on raw stop event envelope; not persisted in sessions snapshot."
      },
      {
        key: "agent_id",
        label: "agent_id skip",
        status: "unknown",
        detail: "Only visible on raw stop event metadata; not persisted in sessions snapshot."
      }
    ];
  }

  function findGraphTransition(from, to) {
    return GRAPH_TRANSITIONS.find(function(t) { return t.from === from && t.to === to; }) || null;
  }

  return {
    STATES,
    STOP_GATE_GRACE_SECONDS,
    AUTO_READY_SECONDS,
    GRAPH_TRANSITIONS,
    normalizeState,
    effectiveState,
    inferTransition,
    evaluateGuards,
    findGraphTransition,
    _internal: {
      parseTimestamp,
      stopGateGraceActive,
      autoReadyActive
    }
  };
});
