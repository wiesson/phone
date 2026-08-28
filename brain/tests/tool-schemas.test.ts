import assert from "node:assert/strict";
import test from "node:test";

import { functionDeclarations, parseToolArguments } from "../src/tool-schemas.ts";

test("declares the three travel tools with required fields", () => {
  assert.deepEqual(functionDeclarations.map((declaration) => declaration.name), [
    "findTrips",
    "getTripRequest",
    "createTripRequest",
  ]);
  assert.deepEqual(functionDeclarations[0].parameters.required, ["query"]);
  assert.deepEqual(functionDeclarations[1].parameters.required, ["lastName", "birthDate"]);
  assert.deepEqual(functionDeclarations[2].parameters.required, [
    "name",
    "phone",
    "destination",
    "period",
    "travelers",
    "budget",
    "notes",
  ]);
});

test("validates tool arguments", () => {
  assert.deepEqual(parseToolArguments("findTrips", { query: "Oman", budgetMax: 12_000 }), {
    name: "findTrips",
    args: { query: "Oman", budgetMax: 12_000 },
  });
  assert.throws(() => parseToolArguments("findTrips", { query: "Oman", budgetMax: "12000" }));
  assert.throws(() => parseToolArguments("getTripRequest", { lastName: "Sommerfeld" }));
});
