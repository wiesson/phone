import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

import { decodeClientFrame, encodeServerMessage, type ServerMessage, type SetupMessage } from "./protocol.ts";
import { functionDeclarations, parseToolArguments } from "./tool-schemas.ts";
import { createTravelToolBackend, invokeTool, type TravelToolBackend } from "./tools.ts";

const defaultModel = "gemini-3.1-flash-live-preview";
const greetingTrigger = "Der Anruf wurde soeben angenommen. Begrüße den Anrufer jetzt.";

type PhoneSocket = {
  readyState: number;
  send(data: string | Uint8Array): void;
  on(event: string, listener: (...args: any[]) => void): void;
};

type GeminiSession = {
  sendRealtimeInput(input: unknown): void;
  sendClientContent(input: unknown): void;
  sendToolResponse(input: unknown): void;
  close(): void;
};

function sendJSON(socket: PhoneSocket, message: ServerMessage) {
  if (socket.readyState === 1) socket.send(encodeServerMessage(message));
}

function fail(socket: PhoneSocket, message: string) {
  sendJSON(socket, { type: "state", value: "failed", message });
}

async function openGeminiSession(
  socket: PhoneSocket,
  setup: SetupMessage,
  tools: TravelToolBackend,
  isClosed: () => boolean,
): Promise<GeminiSession> {
  const apiKey = process.env.GEMINI_API_KEY?.trim();
  if (!apiKey) throw new Error("GEMINI_API_KEY is required");
  const { GoogleGenAI, Modality } = await import("@google/genai");
  const ai = new GoogleGenAI({ apiKey });
  let session: GeminiSession | undefined;
  session = (await ai.live.connect({
    model: setup.model?.trim() || defaultModel,
    config: {
      responseModalities: [Modality.AUDIO],
      systemInstruction: setup.instructions,
      tools: [{ functionDeclarations }],
    },
    callbacks: {
      onmessage(message: any) {
        for (const part of message.serverContent?.modelTurn?.parts ?? []) {
          const encoded = part.inlineData?.data;
          if (typeof encoded === "string" && socket.readyState === 1) {
            socket.send(Uint8Array.from(Buffer.from(encoded, "base64")));
          }
        }
        for (const call of message.toolCall?.functionCalls ?? []) {
          void handleToolCall(socket, session, tools, call);
        }
      },
      onerror(event: any) {
        if (!isClosed()) fail(socket, event?.error?.message ?? event?.message ?? "Gemini Live failed");
      },
      onclose(event: any) {
        if (!isClosed()) fail(socket, event?.reason || "Gemini Live session closed");
      },
    },
  })) as GeminiSession;
  if (setup.greeting) {
    session.sendClientContent({
      turns: [{ role: "user", parts: [{ text: greetingTrigger }] }],
      turnComplete: true,
    });
  }
  return session;
}

async function handleToolCall(
  socket: PhoneSocket,
  session: GeminiSession | undefined,
  tools: TravelToolBackend,
  call: { id?: string; name?: string; args?: unknown },
) {
  const name = call.name ?? "unknown";
  const args = call.args ?? {};
  sendJSON(socket, { type: "toolLog", name, args });
  let result: unknown;
  try {
    const parsed = parseToolArguments(name, args);
    result = await invokeTool(tools, parsed.name, parsed.args);
  } catch (error) {
    result = { error: error instanceof Error ? error.message : String(error) };
  }
  sendJSON(socket, { type: "toolLog", name, args, result });
  session?.sendToolResponse({
    functionResponses: [{ id: call.id, name, response: { result } }],
  });
}

async function handleConnection(socket: PhoneSocket, tools: TravelToolBackend) {
  let gemini: GeminiSession | undefined;
  let closed = false;
  let setupStarted = false;

  socket.on("message", (data: string | Uint8Array | ArrayBuffer | ArrayBufferView, isBinary: boolean) => {
    void (async () => {
      try {
        const frame = decodeClientFrame(data, isBinary);
        if (frame.kind === "setup") {
          if (setupStarted) throw new Error("Setup was already received");
          setupStarted = true;
          gemini = await openGeminiSession(socket, frame.value, tools, () => closed);
          if (!closed) sendJSON(socket, { type: "state", value: "live" });
          return;
        }
        if (!gemini) throw new Error("Setup must be sent before audio");
        gemini.sendRealtimeInput({
          audio: { data: Buffer.from(frame.pcm).toString("base64"), mimeType: "audio/pcm;rate=16000" },
        });
      } catch (error) {
        fail(socket, error instanceof Error ? error.message : String(error));
      }
    })();
  });
  socket.on("close", () => {
    closed = true;
    gemini?.close();
  });
  socket.on("error", () => {
    closed = true;
    gemini?.close();
  });
}

export async function startServer() {
  const { WebSocketServer } = await import("ws");
  const port = Number.parseInt(process.env.BRAIN_PORT ?? "8791", 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) throw new Error("BRAIN_PORT must be a valid port");
  const tools = await createTravelToolBackend(process.env.CONVEX_URL);
  const server = new WebSocketServer({ host: "127.0.0.1", port });
  server.on("connection", (socket: PhoneSocket) => void handleConnection(socket, tools));
  server.on("listening", () => process.stdout.write(`Phone brain listening on ws://127.0.0.1:${port}\n`));
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  startServer().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
