import assert from "node:assert/strict";
import test from "node:test";

import { FallbackBackend, FixturesBackend, type TravelToolBackend } from "../src/tools.ts";

test("fixture search returns the Canvas Club Oman trip", async () => {
  const result = (await new FixturesBackend().findTrips({ query: "Canvas Club", budgetMax: 10_000 })) as {
    trips: Array<{ id: string }>;
  };
  assert.deepEqual(result.trips.map((trip) => trip.id), ["TPL-OMAN-12-LUX"]);
});

test("fixture booking requires the correct birth date", async () => {
  const fixtures = new FixturesBackend();
  assert.deepEqual(await fixtures.getTripRequest({ lastName: "Sommerfeld", birthDate: "01.01.1970" }), {
    found: false,
  });
  const verified = (await fixtures.getTripRequest({
    lastName: "Sommerfeld",
    birthDate: "1978-03-14",
  })) as { found: boolean; booking: { bookingCode: string } };
  assert.equal(verified.found, true);
  assert.equal(verified.booking.bookingCode, "TRV-2417");
});

test("fixture intake IDs are deterministic", async () => {
  const fixtures = new FixturesBackend();
  const args = {
    name: "Ada Example",
    phone: "+49 30 1234",
    destination: "Oman",
    period: "November",
    travelers: "2 adults",
    budget: "EUR 12,000",
    notes: "Private guide",
  };
  assert.equal((await fixtures.createTripRequest(args) as { requestId: string }).requestId, "DEMO-REQ-1001");
  assert.equal((await fixtures.createTripRequest(args) as { requestId: string }).requestId, "DEMO-REQ-1002");
});

test("Convex failures fall back to fixtures with an observable note", async () => {
  const failing: TravelToolBackend = {
    name: "convex",
    async findTrips() { throw new Error("offline"); },
    async getTripRequest() { throw new Error("offline"); },
    async createTripRequest() { throw new Error("offline"); },
  };
  const backend = new FallbackBackend(failing, new FixturesBackend());
  const result = await backend.getTripRequest({ lastName: "Brandt", birthDate: "02.11.1985" });
  assert.equal(result.backend, "fixtures");
  assert.equal(result.fallback, "Convex getTripRequest failed: offline");
  assert.equal((result.data as { found: boolean }).found, true);
});
