# Phone external brain

This experimental local service owns one Gemini Live session per phone WebSocket connection and exposes travel-agency tools. It listens only on `127.0.0.1`.

## Run

Node 22.6 or newer is required.

```sh
cd brain
npm install
GEMINI_API_KEY=... npm start
```

Environment variables:

- `GEMINI_API_KEY` is required for Gemini Live.
- `BRAIN_PORT` selects the loopback port and defaults to `8791`.
- `CONVEX_URL` enables the Tourvy Convex backend. Without it, deterministic fixtures are used.

When Convex is enabled, `findTrips` calls `public/discovery:searchPublicDiscovery` for the `take-memories` public brand. `getTripRequest` resolves that brand with `public/queries:getPublicBrandBySlug`, then calls the authenticated `trips/queries:listRequests` and filters by the verified last name and birth date. `createTripRequest` calls `public/actions:submitPublicRequest`. Any Convex error falls back to fixtures and is included in the corresponding `toolLog` result.

## WebSocket protocol

One connection represents one phone call. The client must send setup before audio:

```json
{"type":"setup","instructions":"...","greeting":true,"model":"gemini-3.1-flash-live-preview"}
```

`model` is optional. Client binary messages are raw PCM16LE mono caller audio at 16,000 Hz. Server binary messages are raw PCM16LE mono model audio at 24,000 Hz.

The server sends UTF-8 JSON text messages:

```json
{"type":"state","value":"live"}
{"type":"state","value":"failed","message":"..."}
{"type":"toolLog","name":"findTrips","args":{"query":"Oman"}}
{"type":"toolLog","name":"findTrips","args":{"query":"Oman"},"result":{"trips":[]}}
```

Closing the client connection closes its Gemini Live session. If `greeting` is true, the brain sends `Der Anruf wurde soeben angenommen. Begrüße den Anrufer jetzt.` as the first user turn so the model speaks first.

The tool contract is:

- `findTrips({query, region?, budgetMax?})`
- `getTripRequest({lastName, birthDate})`
- `createTripRequest({name, phone, destination, period, travelers, budget, notes})`

Run offline tests with `npm test`. They do not import the network clients and need no credentials.
