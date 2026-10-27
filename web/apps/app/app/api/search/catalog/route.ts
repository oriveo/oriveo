import { getSearchCatalog } from "../../../../lib/search/search-catalog-loader";

export const runtime = "nodejs";

/**
 * Adopted catalog for the settings page (read-only): uses the same server-side loader as /api/search/forward (the same signature-verified adoption result),
 * so the entries, hosts and withdrawals the settings page shows match exactly what is checked at forward time. Makes no outbound call to any search service.
 * Preset unavailable (404 withdrawal / never adopted) = `available: false` with empty entries.
 */
export async function GET(): Promise<Response> {
  let available = false;
  let entries: unknown[] = [];
  let withdrawn: string[] = [];
  try {
    const catalog = await getSearchCatalog();
    if (catalog) {
      available = true;
      entries = [...catalog.active.values()].map((service) => service.entry);
      withdrawn = [...catalog.withdrawn];
    }
  } catch {
    available = false;
  }
  return new Response(JSON.stringify({ available, entries, withdrawn }), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
