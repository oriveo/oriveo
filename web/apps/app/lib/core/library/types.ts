import type { Citation } from "@oriveo/shared";

export type LibraryProvider = "notion" | "google";
export type LibraryConnectionStatus =
  "active" | "needs_reauth" | "revoking" | "revoked";

export interface LibraryConnection {
  id: string;
  provider: LibraryProvider;
  providerAccount?: string;
  displayName: string;
  scopes: string[];
  status: LibraryConnectionStatus;
  createdAt?: string;
  lastUsedAt?: string;
}

export interface LibraryQuota {
  used: number;
  limit: number;
  remaining: number;
  resetsAt?: string;
  status?: string;
  unit?: "research" | string;
}

export interface LibraryConnectionQuota {
  used: number;
  limit: number;
  remaining: number;
}

export interface LibraryResearchIdentity {
  researchId: string;
  toolCallId: string;
  /**
   * Which path this call belongs to, which decides the read limit the server applies: the
   * agent step limit exists to stop a runaway model and must be a hard cap, while the read
   * count for named documents is bounded by how many the user ticked. When omitted the
   * server treats it as agent, so a missing declaration is only ever stricter.
   */
  mode?: 'agent' | 'direct';
}

export interface LibraryEnvelope<T> {
  contractVersion?: number;
  requestId?: string;
  entitlement?: unknown;
  quota?: LibraryQuota;
  connectionQuota?: LibraryConnectionQuota;
  warnings?: string[];
  data?: T;
}

export interface LibrarySearchArgs {
  query: string;
  sources?: LibraryProvider[];
  limit?: number;
}

export interface LibraryListArgs {
  source: LibraryProvider;
  containerId?: string | null;
  cursor?: string | null;
}

export interface LibraryReadArgs {
  docId: string;
  source: LibraryProvider;
  section?: string | null;
  cursor?: string | null;
}

export interface LibrarySearchHit {
  docId: string;
  source: LibraryProvider;
  type?: string;
  title: string;
  snippet?: string;
  url: string;
  lastEdited?: string;
}

export interface LibrarySearchResult {
  requestId?: string;
  hits: LibrarySearchHit[];
  warnings?: string[];
}

export interface LibraryListItem {
  id: string;
  kind?: string;
  title: string;
  url?: string;
}

export interface LibraryDocumentRef {
  docId: string;
  source: LibraryProvider;
  title: string;
  url?: string;
  lastEdited?: string;
}

export interface LibraryListResult {
  requestId?: string;
  items: LibraryListItem[];
  nextCursor?: string | null;
  warnings?: string[];
}

export interface LibraryReadSection {
  heading?: string;
  text: string;
  anchor?: string;
}

export interface LibraryReadResult {
  requestId?: string;
  docId?: string;
  source?: LibraryProvider;
  title: string;
  url: string;
  lastEdited?: string;
  sections: LibraryReadSection[];
  nextCursor?: string | null;
  sensitive?: { hit: boolean; kinds?: string[] };
  riskLevel?: "normal" | "sensitive" | "high_cost" | "broad_read" | string;
  redacted?: {
    title: string;
    sections: LibraryReadSection[];
  };
  warnings?: string[];
  citationIndex?: number;
  /**
   * The server already sent only the beginning of this document. Same fact as a non-empty
   * nextCursor arriving from a different source: paging stopped halfway versus the server
   * truncating a single retrieval. buildLibraryContextEnvelope reads this signal and sets
   * truncated="true" plus a truncation_notice, rendering exactly like the named-document path.
   */
  truncated?: boolean;
}

/**
 * A single piece of evidence returned by server-side retrieval.
 *
 * The body fields are identical to the `POST /read` response so the client can feed it
 * straight into the named-document envelope, sensitive-confirmation and citation pipeline
 * instead of carrying a parallel implementation.
 */
export interface LibraryResearchDocument {
  docId: string;
  source: LibraryProvider;
  title: string;
  url: string;
  lastEdited?: string;
  sections: LibraryReadSection[];
  sensitive?: { hit: boolean; kinds?: string[] };
  riskLevel?: "normal" | "sensitive" | "broad_read" | string;
  /** Sent only when sensitive.hit is true; replaces title + sections wholesale when the user chooses to continue redacted. */
  redacted?: {
    title: string;
    sections: LibraryReadSection[];
  };
  /** The server sent only the beginning of this document; defaults to false. */
  truncated?: boolean;
}

/** One-shot step trace from server-side retrieval; it carries no id/step, which the client fills in before handing it to the existing progress bar. */
export interface LibraryResearchServerStep {
  tool: string;
  label: string;
  status: string;
}

export interface LibraryResearchResult {
  requestId?: string;
  query?: string;
  /** An empty array is not an error: it means the library holds nothing relevant, and the model has to be told that. */
  documents: LibraryResearchDocument[];
  steps?: LibraryResearchServerStep[];
  warnings?: string[];
}

export type LibraryToolName =
  "library_search" | "library_list" | "library_read";
export type LibraryToolArgs =
  LibrarySearchArgs | LibraryListArgs | LibraryReadArgs;
export type LibraryToolResult =
  LibrarySearchResult | LibraryListResult | LibraryReadResult;

export interface LibraryRuntimeConfig {
  version: number;
  toolDescriptions: Record<LibraryToolName, string>;
  maxSteps: number;
  toolTimeoutMs: number;
  maxEmptyHits: number;
  maxSelfCorrections: number;
  tokenBudget: number;
  estimatedTokensPerStep: number;
  highCostConfirmationUSD: number;
  weakModelDenylist: string[];
  sensitiveGateEnabled: boolean;
  /**
   * Master switch for the Library feature. When off, no Library entry point is shown.
   * A server that does not send the field is treated as true so the feature does not
   * vanish during an upgrade.
   */
  enabled?: boolean;
  /**
   * Sources that can actually be connected: both enabled and configured with OAuth
   * credentials. The client renders its source cards from this instead of hardcoding them.
   * Falls back to all known sources when absent.
   */
  availableProviders?: string[];
  /** Maximum number of documents that can be ticked at once for named documents. Falls back to a conservative client default when absent. */
  directMaxDocuments?: number;
  /** Grapheme budget for the body text injected for named documents; also clamped against the model window. */
  directContextMaxChars?: number;
  /**
   * When true, the bundled catalog enables server-side research.
   */
  serverResearchEnabled?: boolean;
  /** provider kinds excluded from server research */
  serverResearchProviderDenylist?: string[];
  /** Suggested document count sent with a server retrieval request; the server still applies its own hard cap. */
  serverResearchMaxDocuments?: number;
}

/** Client fallback for the named-document selection cap, used when the server does not send one. */
export const DEFAULT_DIRECT_MAX_DOCUMENTS = 12;
/** Fallback document count suggested with a server retrieval request. */
export const DEFAULT_SERVER_RESEARCH_MAX_DOCUMENTS = 5;
/** provider kinds excluded from server research by default */
export const DEFAULT_SERVER_RESEARCH_PROVIDER_DENYLIST: string[] = [];
/** Fallback grapheme budget for the body text injected for named documents. */
export const DEFAULT_DIRECT_CONTEXT_MAX_CHARS = 60_000;
/**
 * How much of the context window evidence may take. The rest is left for conversation
 * history, the system prompt and the answer itself - ticked documents are concatenated into
 * the message in full, and with no headroom a long document runs straight into a provider 400.
 */
const DIRECT_CONTEXT_WINDOW_SHARE = 0.5;
/** Conservative window assumption when contextLength is unknown, as with a relay or custom endpoint. */
const DIRECT_CONTEXT_DEFAULT_WINDOW = 32_000;

/** Backend authority: the cap on how many documents can be ticked for named documents. */
export function resolveDirectMaxDocuments(
  config: LibraryRuntimeConfig,
): number {
  const configured = config.directMaxDocuments;
  return typeof configured === "number" && configured > 0
    ? Math.floor(configured)
    : DEFAULT_DIRECT_MAX_DOCUMENTS;
}

/**
 * Grapheme budget for the body text injected for named documents: the smaller of the server
 * limit and the model window.
 *
 * The worst case is estimated at 1 grapheme ~ 1 token, which is the ratio for CJK; English
 * is closer to 4:1 and so has more headroom. Being conservative for English is preferable
 * to under-counting a long CJK document and having the whole message rejected with a 400.
 */
export function resolveDirectContextCharBudget(
  config: LibraryRuntimeConfig,
  modelContextLength?: number,
): number {
  const configured = config.directContextMaxChars;
  const cap = typeof configured === "number" && configured > 0
    ? Math.floor(configured)
    : DEFAULT_DIRECT_CONTEXT_MAX_CHARS;
  const window = typeof modelContextLength === "number" &&
      Number.isFinite(modelContextLength) && modelContextLength > 0
    ? modelContextLength
    : DIRECT_CONTEXT_DEFAULT_WINDOW;
  return Math.max(0, Math.min(cap, Math.floor(window * DIRECT_CONTEXT_WINDOW_SHARE)));
}

/** Backend authority: how many pieces of evidence one server retrieval should return. */
export function resolveServerResearchMaxDocuments(
  config: LibraryRuntimeConfig,
): number {
  const configured = config.serverResearchMaxDocuments;
  return typeof configured === "number" && configured > 0
    ? Math.floor(configured)
    : DEFAULT_SERVER_RESEARCH_MAX_DOCUMENTS;
}

/**
 * Whether this server and this provider support server-side retrieval.
 *
 * `hasActiveConnection` must be passed in: connection state lives in the store and this
 * module stays pure, and starting retrieval with no connected source only earns a
 * library_needs_reauth, which a default value should not let through.
 */
export function isServerResearchAvailable(
  config: LibraryRuntimeConfig,
  providerKind: string | undefined,
  hasActiveConnection: boolean,
): boolean {
  if (!isLibraryEnabledByServer(config)) return false;
  if (config.serverResearchEnabled !== true) return false;
  if (!hasActiveConnection) return false;
  if (!providerKind) return false;
  const denylist = config.serverResearchProviderDenylist ??
    DEFAULT_SERVER_RESEARCH_PROVIDER_DENYLIST;
  return !denylist.includes(providerKind);
}

/** Whether the backend reports the feature as available. A server that does not send the field is treated as available. */
export function isLibraryEnabledByServer(config: LibraryRuntimeConfig): boolean {
  return config.enabled ?? true;
}

/**
 * Sources the backend reports as connectable.
 *
 * When the field is absent, fall back to Notion only rather than to every known source:
 * older servers do not send it, and falling back to everything draws a Google card the
 * server was never configured for, so tapping it earns a 503. Google appears on its own
 * once the backend sends availableProviders containing "google", with no client change.
 */
export function resolveAvailableLibraryProviders(
  config: LibraryRuntimeConfig,
): LibraryProvider[] {
  if (!config.availableProviders) return ["notion"];
  return config.availableProviders.filter(
    (value): value is LibraryProvider => value === "notion" || value === "google",
  );
}

export const DEFAULT_LIBRARY_RUNTIME_CONFIG: LibraryRuntimeConfig = {
  version: 6,
  toolDescriptions: {
    library_search:
      "Search connected Library sources by keyword. Notion search may primarily match titles, and Google results do not include content snippets. Read title-relevant Google results to verify them. If results are empty or irrelevant, use library_list to inspect available documents. Retry with synonyms or key terms instead of giving up after one search.",
    library_list:
      "List documents and containers in a connected Library source. Use this after library_search returns empty or irrelevant results, then choose likely documents to inspect with library_read.",
    library_read:
      "Read a selected Library document or section. Base the answer only on returned content and cite the relevant source as [n]. Continue with section or cursor when the result indicates more content.",
  },
  maxSteps: 6,
  toolTimeoutMs: 15_000,
  maxEmptyHits: 2,
  maxSelfCorrections: 3,
  tokenBudget: 0,
  estimatedTokensPerStep: 2_000,
  highCostConfirmationUSD: 0.25,
  weakModelDenylist: [],
  sensitiveGateEnabled: true,
  directMaxDocuments: DEFAULT_DIRECT_MAX_DOCUMENTS,
  directContextMaxChars: DEFAULT_DIRECT_CONTEXT_MAX_CHARS,
  // Bundled catalog default: server research off
  serverResearchEnabled: false,
  serverResearchProviderDenylist: DEFAULT_SERVER_RESEARCH_PROVIDER_DENYLIST,
  serverResearchMaxDocuments: DEFAULT_SERVER_RESEARCH_MAX_DOCUMENTS,
};

export type LibraryResearchStepStatus =
  "pending" | "running" | "completed" | "failed";

export interface LibraryResearchStep {
  id: string;
  tool: LibraryToolName | "synthesize";
  label: string;
  status: LibraryResearchStepStatus;
  step: number;
}

export type LibraryConfirmationChoice = "continue" | "redact" | "cancel";

export interface LibraryConfirmationRequest {
  id: string;
  reason:
    | "sensitive"
    | "high_cost"
    | "broad_read"
    | "unknown_relay"
    | "hosted_provider";
  detail: {
    kinds?: string[];
    docTitles?: string[];
    estTokens?: number;
    estCostUSD?: string;
  };
}

export type LibraryCitation = Citation & {
  docId?: string;
  source?: LibraryProvider;
  anchor?: string;
  lastEdited?: string;
};
