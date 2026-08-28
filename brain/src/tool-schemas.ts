export const functionDeclarations = [
  {
    name: "findTrips",
    description: "Search offered trips and reusable travel templates that match the caller's request.",
    parameters: {
      type: "OBJECT",
      properties: {
        query: { type: "STRING", description: "Destination, style, hotel, or free-text request." },
        region: { type: "STRING", description: "Optional country or region." },
        budgetMax: { type: "NUMBER", description: "Optional maximum total budget in EUR." },
      },
      required: ["query"],
    },
  },
  {
    name: "getTripRequest",
    description: "Look up an existing request or booking only after verifying last name and birth date.",
    parameters: {
      type: "OBJECT",
      properties: {
        lastName: { type: "STRING", description: "Verified family name." },
        birthDate: { type: "STRING", description: "Verified birth date, preferably DD.MM.YYYY." },
      },
      required: ["lastName", "birthDate"],
    },
  },
  {
    name: "createTripRequest",
    description: "Create a new travel intake request after collecting all required details.",
    parameters: {
      type: "OBJECT",
      properties: {
        name: { type: "STRING" },
        phone: { type: "STRING" },
        destination: { type: "STRING" },
        period: { type: "STRING" },
        travelers: { type: "STRING" },
        budget: { type: "STRING" },
        notes: { type: "STRING" },
      },
      required: ["name", "phone", "destination", "period", "travelers", "budget", "notes"],
    },
  },
] as const;

export type ToolName = (typeof functionDeclarations)[number]["name"];

const schemas = new Map(functionDeclarations.map((declaration) => [declaration.name, declaration.parameters]));

export function parseToolArguments(name: string, value: unknown): { name: ToolName; args: Record<string, unknown> } {
  const schema = schemas.get(name as ToolName);
  if (!schema || !value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Invalid arguments for ${name}`);
  }
  const args = value as Record<string, unknown>;
  for (const field of schema.required) {
    if (typeof args[field] !== "string" || args[field].trim() === "") {
      throw new Error(`${name}.${field} must be a non-empty string`);
    }
  }
  for (const [field, definition] of Object.entries(schema.properties)) {
    const fieldValue = args[field];
    if (fieldValue === undefined) continue;
    const expected = definition.type === "NUMBER" ? "number" : "string";
    if (typeof fieldValue !== expected || (expected === "number" && !Number.isFinite(fieldValue))) {
      throw new Error(`${name}.${field} must be a ${expected}`);
    }
  }
  return { name: name as ToolName, args };
}
