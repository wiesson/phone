import type { ToolName } from "./tool-schemas.ts";

export type FindTripsArgs = { query: string; region?: string; budgetMax?: number };
export type GetTripRequestArgs = { lastName: string; birthDate: string };
export type CreateTripRequestArgs = {
  name: string;
  phone: string;
  destination: string;
  period: string;
  travelers: string;
  budget: string;
  notes: string;
};

export type ToolEnvelope = {
  backend: "fixtures" | "convex";
  data: unknown;
  fallback?: string;
};

export interface TravelToolBackend {
  readonly name: "fixtures" | "convex";
  findTrips(args: FindTripsArgs): Promise<unknown>;
  getTripRequest(args: GetTripRequestArgs): Promise<unknown>;
  createTripRequest(args: CreateTripRequestArgs): Promise<unknown>;
}

const trips = [
  {
    id: "TPL-OMAN-12-LUX",
    title: "Oman Classic · Private Luxury Journey",
    destination: "Oman",
    region: "Muscat, Jabal Akhdar, Wahiba Sands",
    duration: "12 days",
    priceFromEUR: 9_800,
    highlights: ["The Chedi Muscat", "Alila Jabal Akhdar", "Canvas Club Private Camp"],
  },
  {
    id: "TPL-OMAN-14-EXT",
    title: "Oman North to South",
    destination: "Oman",
    region: "Muscat to Salalah",
    duration: "14 days",
    priceFromEUR: 12_600,
    highlights: ["Private guide", "Canvas Club", "Dhofar coast"],
  },
  {
    id: "TPL-TZA-10-SAFARI",
    title: "Tanzania Private Safari",
    destination: "Tanzania",
    region: "Serengeti and Ngorongoro",
    duration: "10 days",
    priceFromEUR: 8_400,
    highlights: ["Private safari", "Luxury tented camps", "Crater drive"],
  },
  {
    id: "TPL-MDV-8-RETREAT",
    title: "Maldives Island Retreat",
    destination: "Maldives",
    region: "North Malé Atoll",
    duration: "8 days",
    priceFromEUR: 7_200,
    highlights: ["Water villa", "Private transfers", "Half board"],
  },
];

const bookings = [
  {
    bookingCode: "TRV-2417",
    lastName: "Sommerfeld",
    name: "Petra Sommerfeld",
    birthDate: "14.03.1978",
    trip: "Andalusia round trip",
    period: "21–31 days from today in the Swift demo preset",
    travelers: "2 adults",
    status: "Confirmed; final payment due 7 days from today",
    services: ["Flight from Düsseldorf", "Rental car", "4 hotels", "Alhambra tour"],
  },
  {
    bookingCode: "TRV-2508",
    lastName: "Brandt",
    name: "Brandt family (contact Jonas Brandt)",
    birthDate: "02.11.1985",
    trip: "Crete family holiday",
    period: "42–52 days from today in the Swift demo preset",
    travelers: "2 adults and 2 children, ages 6 and 9",
    status: "Offer accepted; deposit received",
    services: ["Flight from Cologne", "Family suite with half board", "Kids club"],
  },
];

function normalized(value: string): string {
  return value.trim().toLocaleLowerCase("de-DE");
}

function normalizedBirthDate(value: string): string {
  const trimmed = value.trim();
  const iso = /^(\d{4})-(\d{2})-(\d{2})$/.exec(trimmed);
  return iso ? `${iso[3]}.${iso[2]}.${iso[1]}` : trimmed;
}

export class FixturesBackend implements TravelToolBackend {
  readonly name = "fixtures" as const;
  private nextRequest = 1001;

  async findTrips(args: FindTripsArgs): Promise<unknown> {
    const terms = normalized(`${args.query} ${args.region ?? ""}`).split(/\s+/).filter(Boolean);
    const matches = trips.filter((trip) => {
      const searchable = normalized(`${trip.title} ${trip.destination} ${trip.region} ${trip.highlights.join(" ")}`);
      const textMatches = terms.length === 0 || terms.some((term) => searchable.includes(term));
      return textMatches && (args.budgetMax === undefined || trip.priceFromEUR <= args.budgetMax);
    });
    return { trips: matches };
  }

  async getTripRequest(args: GetTripRequestArgs): Promise<unknown> {
    const match = bookings.find(
      (booking) =>
        normalized(booking.lastName) === normalized(args.lastName) &&
        booking.birthDate === normalizedBirthDate(args.birthDate),
    );
    if (!match) return { found: false };
    const { lastName: _, birthDate: __, ...verifiedBooking } = match;
    return { found: true, booking: verifiedBooking };
  }

  async createTripRequest(args: CreateTripRequestArgs): Promise<unknown> {
    const requestId = `DEMO-REQ-${this.nextRequest++}`;
    return { requestId, status: "received", request: { ...args } };
  }
}

export class FallbackBackend implements TravelToolBackend {
  readonly name = "convex" as const;
  private readonly primary: TravelToolBackend;
  private readonly fallback: TravelToolBackend;

  constructor(primary: TravelToolBackend, fallback: TravelToolBackend) {
    this.primary = primary;
    this.fallback = fallback;
  }

  async findTrips(args: FindTripsArgs): Promise<ToolEnvelope> {
    return this.run("findTrips", args);
  }

  async getTripRequest(args: GetTripRequestArgs): Promise<ToolEnvelope> {
    return this.run("getTripRequest", args);
  }

  async createTripRequest(args: CreateTripRequestArgs): Promise<ToolEnvelope> {
    return this.run("createTripRequest", args);
  }

  private async run(name: ToolName, args: Record<string, unknown>): Promise<ToolEnvelope> {
    try {
      return { backend: "convex", data: await this.primary[name](args as never) };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        backend: "fixtures",
        fallback: `Convex ${name} failed: ${message}`,
        data: await this.fallback[name](args as never),
      };
    }
  }
}

export function invokeTool(backend: TravelToolBackend, name: ToolName, args: Record<string, unknown>): Promise<unknown> {
  return backend[name](args as never);
}

export async function createTravelToolBackend(convexURL?: string): Promise<TravelToolBackend> {
  const fixtures = new FixturesBackend();
  if (!convexURL?.trim()) return fixtures;
  const { ConvexBackend } = await import("./convex-tools.ts");
  return new FallbackBackend(new ConvexBackend(convexURL), fixtures);
}
