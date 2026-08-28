import assert from "node:assert/strict";
import test from "node:test";

import { decodeClientFrame, encodeServerMessage } from "../src/protocol.ts";

test("decodes setup text frames", () => {
  const frame = decodeClientFrame(
    JSON.stringify({ type: "setup", instructions: "Be helpful", greeting: true, model: "live-test" }),
    false,
  );
  assert.deepEqual(frame, {
    kind: "setup",
    value: { type: "setup", instructions: "Be helpful", greeting: true, model: "live-test" },
  });
});

test("preserves binary PCM frames", () => {
  const pcm = Uint8Array.from([0, 1, 254, 255]);
  const frame = decodeClientFrame(pcm, true);
  assert.equal(frame.kind, "audio");
  if (frame.kind === "audio") assert.deepEqual(frame.pcm, pcm);
});

test("encodes state and tool log frames", () => {
  assert.equal(encodeServerMessage({ type: "state", value: "live" }), '{"type":"state","value":"live"}');
  assert.deepEqual(JSON.parse(encodeServerMessage({ type: "toolLog", name: "findTrips", args: { query: "Oman" } })), {
    type: "toolLog",
    name: "findTrips",
    args: { query: "Oman" },
  });
});
