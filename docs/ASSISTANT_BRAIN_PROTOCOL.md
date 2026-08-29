# Assistant brain protocol

Phone can send call audio to its own external "brain" instead of talking to
Gemini directly. Set **Settings → Assistant → Brain URL** to a `ws://` or
`wss://` URL; any other value (including an empty field) uses Gemini directly,
and only then is an API key needed in Phone.

One WebSocket connection is one call. The reference implementation lives in the
private `zentrale` repository; this file is the contract, so a brain can be
written against it without that code.

## Client → server

The first message is text and must arrive before any audio:

```json
{"type":"setup","instructions":"…","greeting":true,"model":"gemini-3.1-flash-live-preview"}
```

- `instructions` is the fully composed system instruction for the line that is
  on the call: profile text, context data, and the phone etiquette preamble are
  already merged. The brain should not add its own persona.
- `greeting` is true when the assistant is expected to speak first — an
  answered incoming call. It is false for an assistant call that dialled out,
  where the callee speaks first.
- `model` is what the app has configured; a brain may ignore it.

Every following client message is binary: raw **PCM16LE, mono, 16 kHz** caller
audio.

## Server → client

Binary messages are raw **PCM16LE, mono, 24 kHz** model audio. They are
resampled to the negotiated codec rate and injected into the call.

Text messages are UTF-8 JSON. Phone understands two types and ignores the rest:

```json
{"type":"state","value":"live"}
{"type":"state","value":"failed","message":"…"}
{"type":"toolLog","name":"findTrips","args":{"query":"Oman"}}
{"type":"toolLog","name":"findTrips","args":{"query":"Oman"},"result":{"trips":[]}}
```

- `state` drives the bridge indicator. `live` means audio is flowing;
  `failed` ends the bridge and shows `message`.
- `toolLog` is written to the diagnostic log, once when a tool is called and
  again with `result`. It is informational: Phone never acts on it.

Closing the connection ends the bridge. Phone closes it when the call ends.

## Notes

- The brain owns the model session, its tools, and its credentials. Phone sends
  no API key over this connection, which is why a brain URL removes the key
  requirement in Settings.
- Local transcription stays independent of the bridge and keeps running.
- Send audio as it arrives rather than buffering whole utterances; the caller
  hears every millisecond of added latency.
