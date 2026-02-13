const test = require("node:test");
const assert = require("node:assert/strict");

const model = require("./session-machine-model.js");

function isoFromOffset(seconds) {
  return new Date(Date.now() + (seconds * 1000)).toISOString();
}

function makeSession(overrides) {
  return Object.assign(
    {
      session_id: "session-1",
      state: "ready",
      updated_at: isoFromOffset(-2),
      state_changed_at: isoFromOffset(-2),
      last_event: null,
      last_activity_at: null,
      tools_in_flight: 0,
      ready_reason: null,
      is_alive: true
    },
    overrides || {}
  );
}

test("effectiveState uses stop-gate grace while pid alive", function() {
  const now = Date.now();
  const session = makeSession({
    state: "ready",
    ready_reason: "stop_gate",
    updated_at: new Date(now - 8_000).toISOString(),
    is_alive: true
  });
  assert.equal(model.effectiveState(session, now), "working");
});

test("effectiveState stop-gate expires to ready", function() {
  const now = Date.now();
  const session = makeSession({
    state: "ready",
    ready_reason: "stop_gate",
    updated_at: new Date(now - ((model.STOP_GATE_GRACE_SECONDS + 5) * 1000)).toISOString(),
    is_alive: true
  });
  assert.equal(model.effectiveState(session, now), "ready");
});

test("effectiveState ready with dead pid becomes idle", function() {
  const now = Date.now();
  const session = makeSession({
    state: "ready",
    is_alive: false
  });
  assert.equal(model.effectiveState(session, now), "idle");
});

test("effectiveState auto-ready after task_completed inactivity", function() {
  const now = Date.now();
  const stale = new Date(now - ((model.AUTO_READY_SECONDS + 4) * 1000)).toISOString();
  const session = makeSession({
    state: "working",
    last_event: "task_completed",
    last_activity_at: stale,
    updated_at: stale,
    tools_in_flight: 0
  });
  assert.equal(model.effectiveState(session, now), "ready");
});

test("inferTransition uses effective stop-gate trigger", function() {
  const now = Date.now();
  const previous = makeSession({
    state: "working",
    updated_at: new Date(now - 15_000).toISOString(),
    ready_reason: null,
    is_alive: true
  });
  const current = makeSession({
    state: "ready",
    last_event: "stop",
    ready_reason: "stop_gate",
    updated_at: new Date(now - 3_000).toISOString(),
    is_alive: true
  });
  const transition = model.inferTransition(previous, current, now);
  assert.equal(transition.from, "working");
  assert.equal(transition.to, "working");
  assert.equal(transition.trigger, "effective.stop_gate_grace");
});

test("normalizeState maps unknown state to idle", function() {
  assert.equal(model.normalizeState("waiting"), "waiting");
  assert.equal(model.normalizeState("compacting"), "compacting");
  assert.equal(model.normalizeState("unknown"), "idle");
});
