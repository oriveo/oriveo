/**
 * Web search state before sending and for the input box's web chip preview (external search service contract section 4a "wiring").
 *
 * Computed fresh each time: read the local source and service list, use only the already-cached catalog (none = catalog unavailable, no network request), normalize facts via `webSearchFacts`
 * (the same place as the model options panel), then hand them to the combined entry `resolveWebSearchState`. Rejected facts share a source with the chat page's rejection copy (`webSearchNativeRejected`).
 * Native / relay web fields are suppressed only when `nativeFieldsSuppressed` is true; when false, outbound requests are exactly as before. Executing external search happens elsewhere.
 */
import type { AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import { decidedTransport } from '@oriveo/core/providers/relay-effective';
import { resolveWebSearchState, type WebSearchState } from '@oriveo/core/search/search-route';
import { providerFormOf } from '../capability/truth/provider-form';
import { presentCapabilityControl } from './capability-control-presentation';
import { resolveModelCapabilityEvidence } from './capability-evidence';
import { resolveModelControlStatus } from './model-control-capability-layout';
import { webSearchFacts, webSearchNativeRejected, webSearchRouteForm } from './model-option-capability-shape';
import { relayWebModelOptionFacts } from './relay-web-probe-records';
import { composerWebPreferenceWritable } from './composer-web-preference';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from './stream-options';
import type { SearchConnectionOption } from '../../search/search-settings-data';
import {
  externalSearchFacts,
  externalSearchModelKey,
  loadExternalSearchDataForSend,
  readConversationSearchSource,
  type ExternalSearchData,
} from '../../search/external-search-context';

/** Pure part: given local facts, this turn's web search state. Relay with missing facts = null (no external search). */
export function externalSearchSendState({
  provider,
  model,
  data,
  stored,
  nativeRejected,
  webOn,
}: {
  provider: Provider;
  model: AIModel;
  data: Pick<ExternalSearchData, 'snapshot' | 'catalog' | 'connections'>;
  stored: unknown;
  nativeRejected: boolean;
  webOn: boolean;
}): WebSearchState | null {
  const relayWeb = providerFormOf(provider) === 'relay' ? relayWebModelOptionFacts(provider, model) : undefined;
  const facts = webSearchFacts({
    form: webSearchRouteForm(provider),
    status: resolveModelControlStatus(presentCapabilityControl(provider, model, 'web')),
    ...(relayWeb ? { relayWeb } : {}),
    protocolUndecided: provider.kind === 'relay' && !decidedTransport(provider, model),
    nativeRejected,
    toolCall: resolveModelCapabilityEvidence({ key: 'tool_call', provider, model }).support,
  });
  if (!facts) return null;
  // The one-tap enable target uses the same facts as the panel (cached catalog + local connection); it only affects the card form and chip when no service exists.
  const { input: external } = externalSearchFacts({
    data,
    stored,
    modelKey: externalSearchModelKey(provider.id, model.id),
    form: facts.form,
    currentProviderKind: provider.kind,
    toolCall: facts.toolCall ?? 'unknown',
    panelWritable: composerWebPreferenceWritable(provider, model),
  });
  return resolveWebSearchState({
    facts,
    // Same definition as the panel: whether a session-level preference can be written for this conversation (contract section 4a).
    panelWritable: external.panelWritable,
    webOn,
    modelKey: external.modelKey,
    currentProviderKind: external.currentProviderKind,
    services: external.services,
    defaultServiceId: external.defaultServiceId,
    stored,
    oneTapTarget: external.oneTap?.target ?? null,
    oneTapServiceName: external.oneTap?.serviceName ?? null,
  });
}

/** This turn's web search state + the local facts used to compute it (send wiring takes state for planning and data to find the current source service and execute). */
export interface ExternalSearchSendContext {
  state: WebSearchState;
  data: ExternalSearchData;
}

/**
 * Read local facts, then compute this turn's web search state (before sending, input chip preview). No local service / search partition unreadable (incognito, test env) = null (behavior as before).
 * Reads only, never writes the source (write-back is left to the model options panel and model switching).
 */
export async function loadExternalSearchSendContext({
  provider,
  model,
  conversationId,
  draftSessionId,
  reasoningMode,
  webOn,
  connections = [],
}: {
  provider: Provider;
  model: AIModel;
  conversationId: string | undefined;
  draftSessionId?: string;
  reasoningMode: ReasoningMode | undefined;
  webOn: boolean;
  /** Local model connection (one-tap enable target). */
  connections?: SearchConnectionOption[];
}): Promise<ExternalSearchSendContext | null> {
  let data: ExternalSearchData | null;
  let stored: unknown;
  try {
    data = await loadExternalSearchDataForSend(connections);
    if (!data) return null;
    stored = (await readConversationSearchSource({
      data, conversationId, ...(draftSessionId ? { draftSessionId } : {}), modelKey: externalSearchModelKey(provider.id, model.id), persist: false,
    })).stored;
  } catch {
    return null;
  }
  const identity = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, reasoningMode, false), model)?.capabilityRecoveryIdentity;
  const state = externalSearchSendState({ provider, model, data, stored, nativeRejected: webSearchNativeRejected(identity), webOn });
  return state ? { state, data } : null;
}

/** Only this turn's web search state (input chip preview). */
export async function loadExternalSearchSendState(input: Parameters<typeof loadExternalSearchSendContext>[0]): Promise<WebSearchState | null> {
  return (await loadExternalSearchSendContext(input))?.state ?? null;
}

/** Whether this turn's request must suppress native / relay web fields (computed fresh on every send, independent of the panel / chip preview). */
export async function externalSearchSuppressesNativeWebFields(input: {
  provider: Provider;
  model: AIModel;
  conversationId: string | undefined;
  reasoningMode: ReasoningMode | undefined;
  webOn: boolean;
  connections?: SearchConnectionOption[];
}): Promise<boolean> {
  return (await loadExternalSearchSendState(input))?.nativeFieldsSuppressed === true;
}
