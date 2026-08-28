export type SetupMessage = {
  type: "setup";
  instructions: string;
  greeting: boolean;
  model?: string;
};

export type ClientFrame =
  | { kind: "audio"; pcm: Uint8Array }
  | { kind: "setup"; value: SetupMessage };

export type ServerMessage =
  | { type: "state"; value: "live" | "failed"; message?: string }
  | { type: "toolLog"; name: string; args: unknown; result?: unknown };

function bytes(value: string | Uint8Array | ArrayBuffer | ArrayBufferView): Uint8Array {
  if (typeof value === "string") return new TextEncoder().encode(value);
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
}

export function decodeClientFrame(
  value: string | Uint8Array | ArrayBuffer | ArrayBufferView,
  isBinary: boolean,
): ClientFrame {
  const data = bytes(value);
  if (isBinary) return { kind: "audio", pcm: data };
  const parsed = JSON.parse(new TextDecoder().decode(data)) as Partial<SetupMessage>;
  if (
    parsed.type !== "setup" ||
    typeof parsed.instructions !== "string" ||
    typeof parsed.greeting !== "boolean" ||
    (parsed.model !== undefined && typeof parsed.model !== "string")
  ) {
    throw new Error("Expected a valid setup message");
  }
  return { kind: "setup", value: parsed as SetupMessage };
}

export function encodeServerMessage(message: ServerMessage): string {
  return JSON.stringify(message);
}
