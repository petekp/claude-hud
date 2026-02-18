import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.js";

function makeEnv() {
  const state = {
    runCalls: 0,
    lastBindValues: null,
  };

  const env = {
    INGEST_KEY: "secret",
    DB: {
      prepare(sql) {
        return {
          bind(...values) {
            state.lastBindValues = values;
            return {
              async run() {
                state.runCalls += 1;
                return { meta: { last_row_id: 42 } };
              },
            };
          },
        };
      },
    },
  };

  return { env, state };
}

function telemetryRequest(body) {
  return new Request("https://ingest.example.com/v1/telemetry", {
    method: "POST",
    headers: {
      authorization: "Bearer secret",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

test("drops non-feedback telemetry event types to prevent ingest floods", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "active_project_resolution",
      message: "Resolved active project",
      timestamp: "2026-02-16T12:00:00.000Z",
      payload: {
        active_source: "claude",
      },
    }),
    env,
  );

  assert.equal(response.status, 202);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.dropped, true);
  assert.equal(body.reason, "event_type_not_allowed");
  assert.equal(state.runCalls, 0);
});

test("persists quick feedback telemetry event types", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "quick_feedback_submit_attempt",
      message: "Quick feedback submit attempted",
      timestamp: "2026-02-16T12:01:00.000Z",
      payload: {
        feedback_id: "fb-123",
      },
    }),
    env,
  );

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.event_id, 42);
  assert.equal(state.runCalls, 1);
  assert.equal(state.lastBindValues?.[0], "quick_feedback_submit_attempt");
});

test("drops unknown quick feedback event types not on allowlist", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "quick_feedback_experimental_event",
      message: "Unexpected quick feedback event",
      timestamp: "2026-02-16T12:02:00.000Z",
      payload: {
        feedback_id: "fb-124",
      },
    }),
    env,
  );

  assert.equal(response.status, 202);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.dropped, true);
  assert.equal(body.reason, "event_type_not_allowed");
  assert.equal(state.runCalls, 0);
});
