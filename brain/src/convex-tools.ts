import { ConvexHttpClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";

import type {
  CreateTripRequestArgs,
  FindTripsArgs,
  GetTripRequestArgs,
  TravelToolBackend,
} from "./tools.ts";

const brandSlug = "take-memories";
const searchPublicDiscovery = makeFunctionReference<"query">("public/discovery:searchPublicDiscovery");
const getPublicBrandBySlug = makeFunctionReference<"query">("public/queries:getPublicBrandBySlug");
const listRequests = makeFunctionReference<"query">("trips/queries:listRequests");
const submitPublicRequest = makeFunctionReference<"action">("public/actions:submitPublicRequest");

function splitName(name: string): { firstName?: string; lastName: string } {
  const parts = name.trim().split(/\s+/);
  if (parts.length === 1) return { lastName: parts[0] };
  return { firstName: parts.slice(0, -1).join(" "), lastName: parts.at(-1)! };
}

function sanitizedRequest(request: Record<string, unknown>) {
  const data = (request.data ?? {}) as Record<string, unknown>;
  return {
    requestId: request._id,
    title: request.publicTitle ?? null,
    customerName: request.customerName ?? null,
    destinations: data.destinations ?? [],
    dateFrom: data.dateFrom ?? null,
    dateTo: data.dateTo ?? null,
    adults: data.adults ?? null,
    children: data.children ?? null,
    budget: data.budget ?? null,
    status: request.status ?? null,
    bookingStatus: request.bookingStatus ?? null,
  };
}

export class ConvexBackend implements TravelToolBackend {
  readonly name = "convex" as const;
  private readonly client: ConvexHttpClient;

  constructor(url: string) {
    this.client = new ConvexHttpClient(url.trim());
  }

  async findTrips(args: FindTripsArgs): Promise<unknown> {
    const result = (await this.client.query(searchPublicDiscovery, {
      brandSlugOrCode: brandSlug,
      query: args.query,
      region: args.region,
      matchMode: "any",
      limit: 8,
    })) as { results?: Array<Record<string, unknown>> } | null;
    if (!result) throw new Error(`Public brand ${brandSlug} was not found`);
    if (args.budgetMax === undefined) return result;
    const filtered = (result.results ?? []).filter((row) => {
      const price = row.priceFromEUR ?? row.priceFrom ?? row.totalPrice;
      return typeof price !== "number" || price <= args.budgetMax!;
    });
    return { ...result, results: filtered, budgetMax: args.budgetMax };
  }

  async getTripRequest(args: GetTripRequestArgs): Promise<unknown> {
    const brand = (await this.client.query(getPublicBrandBySlug, { slug: brandSlug })) as
      | { organizationId?: string }
      | null;
    if (!brand?.organizationId) throw new Error(`Public brand ${brandSlug} was not found`);
    const requests = (await this.client.query(listRequests, {
      organizationId: brand.organizationId,
      limit: 200,
    })) as Array<Record<string, unknown>>;
    const expectedName = args.lastName.trim().toLocaleLowerCase("de-DE");
    const expectedBirthDate = args.birthDate.trim();
    const match = requests.find((request) => {
      const name = String(request.customerName ?? "").toLocaleLowerCase("de-DE");
      return name.includes(expectedName) && JSON.stringify(request).includes(expectedBirthDate);
    });
    return match ? { found: true, request: sanitizedRequest(match) } : { found: false };
  }

  async createTripRequest(args: CreateTripRequestArgs): Promise<unknown> {
    const contact = splitName(args.name);
    const text = [
      `Destination: ${args.destination}`,
      `Period: ${args.period}`,
      `Travelers: ${args.travelers}`,
      `Budget: ${args.budget}`,
      `Notes: ${args.notes}`,
    ].join("\n");
    return this.client.action(submitPublicRequest, {
      slug: brandSlug,
      text,
      firstName: contact.firstName,
      lastName: contact.lastName,
      phone: args.phone,
      callMeBack: true,
      sendProposal: false,
    });
  }
}
