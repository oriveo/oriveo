import type { AIModel, Provider } from "@oriveo/shared";
import {
  getLibraryRuntimeConfig,
  getRelayRuntimeConfig,
  isMetadataSnapshotConfirmed,
  resolveCatalogModel,
} from "../metadata/metadata-client";
import {
  effectiveCapabilityTransport,
  resolveModelCapabilityEvidence,
  type RelayCapabilityEvidenceIdentity,
} from "../chat/capability-evidence";
import { isLibraryBuildEnabled, isLibraryFeatureEnabled } from "./feature-flag";
import {
  DEFAULT_SERVER_RESEARCH_PROVIDER_DENYLIST,
  isServerResearchAvailable,
  type LibraryRuntimeConfig,
} from "./types";

/**
 * Which chain library research takes.
 *
 * - `agent`: the model drives multi-step retrieval through tools itself (the BYOK selling point,
 *   preferred whenever it works)
 * - `server`: server-side research assembles all the evidence in one shot, so the model needs no
 *   tool capability at all
 * - `pending`: the final transport is not settled yet, or the metadata snapshot is not confirmed
 *   yet, so **this cannot be decided right now** - which is not the same as deciding against it
 * - `none`: neither chain is available (feature off, or no connected source)
 *
 * `pending` must stay separate from `none`: collapsing them renders "not fetched yet" during the
 * cold-start window as "this model does not support automatic research", and the ChatView effect
 * then also clears the research toggle the user had switched on. The right reaction is to recompute
 * once the snapshot is ready, not to treat it as unsupported.
 *
 * The decision must live in exactly one place: ChatView decides whether the entry point is
 * clickable and the send path decides which chain actually runs, and writing it twice produces
 * "the button is lit but sending took the other route".
 */
export type LibraryResearchRoute = "agent" | "server" | "pending" | "none";

const LIBRARY_TOOL_ADAPTER_TRANSPORTS = new Set([
  "openai_chat",
  "openai_responses",
  "anthropic_messages",
  "gemini_generate_content",
]);

/**
 * Whether the model can take the agentic research route.
 *
 * transport is read only from the production dispatcher's final protocol; tool_call only from the
 * central evidence facade. All four native adapters can send Library tools, so the older
 * openai_chat-only `libraryAgentic` derived bit takes no part in the verdict. Models outside the
 * catalog are resolved by the facade in the order first-hand declaration > modelFacts > persisted
 * model bit > unknown; only an explicit unsupported vetoes agent, while unknown is left to the
 * existing unsupported-tools recovery path to downgrade at runtime.
 */
export function isLibraryAgentSupported(
  provider: Provider | undefined,
  model: AIModel | undefined,
  config: LibraryRuntimeConfig,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
): boolean {
  if (!provider || !model) return false;
  // A relay's catalog membership comes from the recognised upstream on the connected model, so
  // `relay` must not be looked up as an official provider kind. The weak-model fallback also checks
  // the connected model's own canonical id.
  const catalog = provider.kind === "relay" ? null : resolveCatalogModel(model.id, provider.kind);
  const transport = effectiveCapabilityTransport(provider, model);
  if (!LIBRARY_TOOL_ADAPTER_TRANSPORTS.has(transport)) return false;
  if (
    config.weakModelDenylist.includes(model.id) ||
    (model.canonicalModelId != null && config.weakModelDenylist.includes(model.canonicalModelId)) ||
    (catalog?.canonicalModelId != null && config.weakModelDenylist.includes(catalog.canonicalModelId))
  ) {
    return false;
  }
  // Unknown is deliberately fail-open: tools are only attached when Library is
  // enabled, and a deterministic unsupported-tools response is retried without
  // tools by the shared recovery path. Only an explicit unsupported verdict is
  // a model capability veto.
  return toolCallDecision(provider, model, transport, relayIdentity) !== "unsupported";
}

/**
 * Library routing owns its transport and denylist gates, but never interprets
 * a raw tool-call bit. The shared facade resolves server evidence first and
 * the Web legacy adapter only supplies the documented compatibility fallback.
 */
function toolCallDecision(
  provider: Provider,
  model: AIModel,
  effectiveTransport: string,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
): 'supported' | 'unsupported' | 'unknown' {
  return toolCallEvidence(provider, model, effectiveTransport, relayIdentity).support;
}

function toolCallEvidence(
  provider: Provider,
  model: AIModel,
  effectiveTransport: string,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
) {
  return resolveModelCapabilityEvidence({
    key: 'tool_call',
    provider,
    model,
    effectiveTransport,
    relayIdentity,
  });
}

/**
 * Whether the current metadata snapshot can answer "which chain does this model take".
 *
 * Warning: **the snapshot merely existing is not enough**. When `initMetadata()` hits the
 * localStorage cache it returns immediately and only fires one background refresh, so **a stale
 * snapshot is equally non-null**. Routing needs at least the final transport the dispatcher will
 * actually use; a Relay `auto` that has not negotiated yet is "cannot decide", not "unsupported".
 *
 * Observed in production on 2026-07-28: a direct BYOK connection to DeepSeek V4 Flash was reported
 * as "this model does not support automatic research" and only recovered minutes later when the
 * background refresh swapped in a new snapshot. The test has to go down to "is this model present".
 *
 * An unknown tool_call does not create pending: the central policy fails open and falls back to a
 * tool-free retry when the real upstream rejects tools. That keeps hand-entered models outside the
 * catalog, and subscription models, from being stuck forever on "not in the catalog".
 */
export function metadataCanDecideRoute(
  provider: Provider,
  model: AIModel,
): boolean {
  return effectiveCapabilityTransport(provider, model) !== "unknown";
}

/**
 * `metadataCanDecide` separates "this snapshot cannot answer yet" from "definitely unsupported";
 * passing undefined computes it from the real snapshot, and tests can pass `true` explicitly to mean
 * "this config is answerable".
 *
 * `snapshotConfirmed`: whether this session has confirmed metadata with the backend (200/304).
 * **A negative verdict may only rest on a confirmed snapshot** - the localStorage cache can be
 * frozen at any point in the past (an old config with the master switch off, a stale
 * `serverResearchEnabled=false`), and drawing a negative conclusion from it is exactly the shape of
 * "first computation is wrong, an async refresh papers over it later". Until confirmation the answer
 * is always pending; callers already hook `refreshMetadata()` onto pending and land on the real
 * verdict once it completes. Positive verdicts (agent / server) do not carry this bar: getting one
 * wrong only costs a graceful downgrade after a failed research pass, far cheaper than reporting a
 * working feature as unsupported. Passing undefined computes from the real session state; tests
 * inject explicitly.
 */
export function resolveLibraryResearchRoute(
  provider: Provider | undefined,
  model: AIModel | undefined,
  config: LibraryRuntimeConfig,
  hasActiveConnection: boolean,
  metadataCanDecide?: boolean,
  snapshotConfirmed?: boolean,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
): LibraryResearchRoute {
  const confirmed = snapshotConfirmed ?? isMetadataSnapshotConfirmed();
  // When the build-time kill switch and the backend master switch are both off, both chains go down.
  // The build-time one is a locally certain fact (a new snapshot cannot change it), while the backend
  // `enabled` comes from metadata and must not yield an "unavailable" verdict before this session has
  // confirmed it.
  if (!isLibraryFeatureEnabled()) {
    return isLibraryBuildEnabled() && !confirmed ? "pending" : "none";
  }
  if (!hasActiveConnection) return "none";
  if (!provider || !model) return "pending";
  const canDecide = metadataCanDecide ?? metadataCanDecideRoute(provider, model);
  if (!canDecide) {
    return "pending";
  }
  if (isLibraryAgentSupported(provider, model, config, relayIdentity)) return "agent";
  if (isServerResearchAvailable(config, provider?.kind, hasActiveConnection)) {
    return "server";
  }
  // The denylist is a static fact about the provider, so it decides before confirmation does.
  if (provider && isDeniedLibraryResearchProvider(provider.kind, config)) {
    return "none";
  }
  // With neither chain available, first separate "definitely unsupported" from "this snapshot cannot
  // answer yet". Having no connected source is a certain fact independent of metadata (already
  // handled above) and is not subject to the confirmation bar.
  //
  // An unresolved provider / model is **not** a certain fact: right after a cold start into a
  // conversation, providers and conversation records are still loading and a historical fallback
  // provider always has an empty models list, so currentModel resolves to undefined and is ready one
  // tick later. That is pending; ChatView recomputes on every render and re-decides as soon as the
  // context is ready. Only a model that still does not resolve after a forced refresh is shown as
  // unavailable by the caller.
  //
  // The only test here is "is this model in the catalog". A missing serverResearchEnabled is not
  // checked, because getLibraryRuntimeConfig() falls back to the DEFAULT's **explicit false** for a
  // missing field, so undefined never reaches this point and such a test would be dead code that
  // looks live. In other words a false from a stale or default config is indistinguishable from a
  // false the backend really sent, and only the session-level snapshotConfirmed bar can tell them
  // apart. Callers resolve pending by forcing one snapshot refresh and re-deciding; only a result
  // that is still pending afterwards is shown as unavailable, otherwise the copy would sit on
  // "confirming" forever.
  if (!canDecide) return "pending";
  return confirmed ? "none" : "pending";
}

/**
 * When `resolveLibraryResearchRoute` returns `none`, the "unavailable" copy shown in the UI is split
 * by reason: backend master switch off, provider on the research denylist, or the model itself
 * unsupported. The three leave the user with completely different options - merging "pick another
 * model" and "wait for the operator to restore it" into one "unavailable" leaves them unable to tell
 * what to do.
 *
 * `noConnection` is not routed here: that case uses the existing `connectRequired` copy, a separate
 * empty state that never goes through this research hint, so it needs no reason of its own.
 *
 * The branches deliberately mirror resolveLibraryResearchRoute rather than deriving the reason from
 * its return value: that return value has already folded pending and none into a boolean for the
 * caller, so working backwards would depend on the caller having handled pending correctly first.
 * Mirroring the branches lets this function stand on its own whenever it is called.
 */
export function resolveLibraryResearchUnavailableReason(
  provider: Provider | undefined,
  model: AIModel | undefined,
  config: LibraryRuntimeConfig,
  hasActiveConnection: boolean,
  metadataCanDecide?: boolean,
  snapshotConfirmed?: boolean,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
): "serverDisabled" | "providerDenied" | "modelUnsupported" | undefined {
  const confirmed = snapshotConfirmed ?? isMetadataSnapshotConfirmed();
  if (!isLibraryFeatureEnabled()) {
    // Turning it off at build time is a locally certain fact; an unconfirmed backend enabled=false
    // actually routes to pending, so no "serverDisabled" verdict is drawn here either.
    return isLibraryBuildEnabled() && !confirmed ? undefined : "serverDisabled";
  }
  if (!hasActiveConnection) return undefined;
  if (!provider || !model) return undefined; // pending
  const canDecide = metadataCanDecide ?? metadataCanDecideRoute(provider, model);
  if (!canDecide) {
    return undefined; // pending
  }
  if (isLibraryAgentSupported(provider, model, config, relayIdentity)) return undefined;
  if (isServerResearchAvailable(config, provider?.kind, hasActiveConnection)) {
    return undefined;
  }
  // The denylist is a static fact about the provider, so the verdict does not wait for a
  // confirmed snapshot the way modelUnsupported does.
  if (provider && isDeniedLibraryResearchProvider(provider.kind, config)) {
    return "providerDenied";
  }
  if (!canDecide) return undefined; // pending
  return confirmed ? "modelUnsupported" : undefined; // pending
}

function isDeniedLibraryResearchProvider(
  providerKind: string | undefined,
  config: LibraryRuntimeConfig,
): boolean {
  if (!providerKind) return false;
  const denylist =
    config.serverResearchProviderDenylist ??
    DEFAULT_SERVER_RESEARCH_PROVIDER_DENYLIST;
  return denylist.includes(providerKind);
}

/** Convenience entry point for the send path: the config is read from metadata on the spot, so callers cannot cache inconsistent snapshots of their own. */
export function resolveLibraryResearchRouteNow(
  provider: Provider | undefined,
  model: AIModel | undefined,
  hasActiveConnection: boolean,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
): LibraryResearchRoute {
  return resolveLibraryResearchRoute(
    provider,
    model,
    getLibraryRuntimeConfig(),
    hasActiveConnection,
    undefined,
    undefined,
    relayIdentity,
  );
}

/** ChatView also needs the relay runtime config to judge web search capability; this re-export keeps the import surface narrow. */
export { getRelayRuntimeConfig };
