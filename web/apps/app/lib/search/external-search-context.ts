/**
 * Data for the web card to connect to local external search services (external search service contract section 4a): selectable services, this conversation's source, one-tap enable target.
 *
 * All decisions go through the same-named core functions (searchServiceSelectable / resolveSearchSource / oneTapReuseTarget); this file only
 * fetches facts from the partition store, the adopted catalog and model connections, and persists source reads/writes to the same partition store (nothing is written when `changed` is false).
 * - A new conversation has no id yet: the source stays in memory (keyed by this page's draft conversation id), written once under the real id when the first message creates the conversation, and never persisted under the draft id.
 */
import {
  oneTapReuseTarget,
  resolveSearchSource,
  searchServiceSelectable,
  updateSearchSource,
  type OneTapTarget,
  type ResolvedSearchSource,
  type SearchSourceEvent,
  type StoredSearchSource,
  type ToolCallSupport,
  type WebRouteForm,
} from '@oriveo/core/search/search-route';
import { searchServiceDisplayName } from '@oriveo/core/search/search-settings';
import type { ModelOptionExternalSearch } from '../core/chat/model-option-capability-shape';
import { getActiveUID } from '../infra/storage/partition';
import { getConversationSearchSource, listSearchServices, setConversationSearchSource } from './search-service-store';
import {
  cachedSettingsCatalog,
  loadSearchServicesSnapshot,
  loadSettingsCatalog,
  type SearchConnectionOption,
  type SearchServicesSnapshot,
  type SettingsCatalog,
} from './search-settings-data';

/** Broadcast after the service list is added / removed / edited (connect page save, settings page edits) or the conversation source is written by a user action; model options and the chip recompute on it. A one-shot event, no polling. */
export const SEARCH_SERVICES_CHANGED_EVENT = 'oriveo:search-services-changed';

export function notifySearchServicesChanged(): void {
  if (typeof window !== 'undefined') window.dispatchEvent(new Event(SEARCH_SERVICES_CHANGED_EVENT));
}

/** Model selection identifier used for local comparison: `<connection id>:<model id>` (stored per section 4a). */
export function externalSearchModelKey(providerId: string, modelId: string): string {
  return `${providerId}:${modelId}`;
}

export interface ExternalSearchData {
  uid: string;
  catalog: SettingsCatalog;
  connections: SearchConnectionOption[];
  snapshot: SearchServicesSnapshot;
}

export interface ExternalSearchFacts {
  oneTapTarget: OneTapTarget | null;
  /** External search input for the shape resolver (local facts as-is; the decision is in resolveWebSearchState). */
  input: ModelOptionExternalSearch;
}

/** Assemble the web card input from already-fetched local facts (pure function, used by both tests and sample renders). */
export function externalSearchFacts({
  data,
  stored,
  modelKey,
  form,
  currentProviderKind,
  toolCall,
  nativeRejected = false,
  panelWritable,
}: {
  data: Pick<ExternalSearchData, 'catalog' | 'connections' | 'snapshot'>;
  stored: unknown;
  modelKey: string;
  form: WebRouteForm;
  currentProviderKind: string | null;
  toolCall: ToolCallSupport;
  nativeRejected?: boolean;
  panelWritable: boolean;
}): ExternalSearchFacts {
  const oneTapTarget = oneTapReuseTarget({
    catalogAvailable: data.catalog.available,
    entries: data.catalog.entries,
    connections: data.connections,
    currentProviderKind,
  });
  const oneTapName = oneTapTarget
    ? searchServiceDisplayName({
      kind: 'preset',
      serviceId: oneTapTarget.serviceId,
      catalogDisplayName: data.catalog.entries.find((entry) => entry.id === oneTapTarget.serviceId)?.displayName ?? null,
    })
    : null;
  return {
    oneTapTarget,
    input: {
      form,
      modelKey,
      currentProviderKind,
      // view.name has already passed searchServiceDisplayName (serviceDisplayName).
      services: data.snapshot.services.map((view) => ({ id: view.record.id, name: view.name, status: view.row.status })),
      defaultServiceId: data.snapshot.defaultId,
      stored,
      oneTap: oneTapTarget && oneTapName ? { target: oneTapTarget, serviceName: oneTapName } : null,
      toolCall,
      ...(nativeRejected ? { nativeRejected } : {}),
      panelWritable,
    },
  };
}

/** For the model options panel: the current partition's service list, the adopted catalog (same one as the settings page, may issue a network request) and connections. */
export async function loadExternalSearchData(connections: SearchConnectionOption[]): Promise<ExternalSearchData> {
  const [uid, catalog] = await Promise.all([getActiveUID(), loadSettingsCatalog()]);
  const snapshot = await loadSearchServicesSnapshot(uid, catalog, connections);
  return { uid, catalog, connections, snapshot };
}

const CATALOG_UNAVAILABLE: SettingsCatalog = { available: false, entries: [], withdrawn: [] };

/**
 * For pre-send and chip preview: uses only the already-cached catalog and sends no network request; no cache = catalog unavailable. Connections come from the existing store (one-tap enable target).
 */
export async function loadExternalSearchDataForSend(connections: SearchConnectionOption[] = []): Promise<ExternalSearchData | null> {
  const uid = await getActiveUID();
  const catalog = cachedSettingsCatalog() ?? CATALOG_UNAVAILABLE;
  // When the device has no service at all and no one-tap enable target either, the combined entry is necessarily in its pre-change shape: do not read the source.
  if ((await listSearchServices(uid)).every((record) => record.pendingAdd) && !catalog.available) return null;
  const snapshot = await loadSearchServicesSnapshot(uid, catalog, connections);
  return { uid, catalog, connections, snapshot };
}

// ── New conversation (no id): source in memory only ─────────────────────────────────────

const draftSources = new Map<string, StoredSearchSource | null>();
/** The write made under the real id when the first message creates the conversation: pre-send source reads wait for it to be persisted first (not a cache, deleted once written). */
const adoptions = new Map<string, Promise<void>>();

export function readDraftSearchSource(draftSessionId: string): StoredSearchSource | null {
  return draftSources.get(draftSessionId) ?? null;
}

export function writeDraftSearchSource(draftSessionId: string, value: StoredSearchSource | null): void {
  if (value === null) draftSources.delete(draftSessionId);
  else draftSources.set(draftSessionId, value);
  notifySearchServicesChanged();
}

/** New conversation created: if the draft source is non-empty, write it once under the real id and drop the in-memory copy; empty = write nothing. */
export function adoptDraftSearchSource({ draftSessionId, conversationId }: { draftSessionId: string; conversationId: string }): void {
  const value = draftSources.get(draftSessionId) ?? null;
  draftSources.delete(draftSessionId);
  if (value === null) return;
  const write = (async () => {
    try {
      await setConversationSearchSource(await getActiveUID(), conversationId, value);
    } catch {
      // Partition store unavailable (incognito etc.): the source is only a local preference, so a loss falls back to the default.
    } finally {
      adoptions.delete(conversationId);
    }
  })();
  adoptions.set(conversationId, write);
}

async function storedSourceOf(uid: string, conversationId: string): Promise<unknown> {
  await adoptions.get(conversationId);
  return getConversationSearchSource(uid, conversationId);
}

/**
 * Read this conversation's source. `nextStored` is written back (persist, only when `changed` is true) only when the model options panel is open; sending and chip preview read without writing.
 * Draft conversations read from memory.
 */
export async function readConversationSearchSource({
  data,
  conversationId,
  draftSessionId,
  modelKey,
  persist = true,
}: {
  data: Pick<ExternalSearchData, 'uid' | 'snapshot' | 'catalog'>;
  conversationId: string | undefined;
  draftSessionId?: string;
  modelKey: string;
  persist?: boolean;
}): Promise<{ stored: unknown; resolved: ResolvedSearchSource }> {
  const stored = conversationId
    ? await storedSourceOf(data.uid, conversationId)
    : draftSessionId ? readDraftSearchSource(draftSessionId) : null;
  const selectable = data.snapshot.services
    .filter((view) => searchServiceSelectable(view.row.status))
    .map((view) => ({ id: view.record.id, status: view.row.status }));
  const resolved = resolveSearchSource({ stored, modelKey, selectable, defaultServiceId: data.snapshot.defaultId });
  const write = persist && resolved.changed;
  if (write && conversationId) {
    await setConversationSearchSource(data.uid, conversationId, resolved.nextStored);
    notifySearchServicesChanged();
  } else if (write && draftSessionId) writeDraftSearchSource(draftSessionId, resolved.nextStored);
  return { stored: write ? resolved.nextStored : stored, resolved };
}

/** Write path for user actions (picking a source in the sheet, confirming the hint when model options close); with no conversation id it writes to the in-memory draft. Returns the value written. */
export async function writeConversationSearchSource({
  uid,
  conversationId,
  draftSessionId,
  stored,
  modelKey,
  event,
}: {
  uid: string;
  conversationId: string | undefined;
  draftSessionId?: string;
  stored: unknown;
  modelKey: string;
  event: SearchSourceEvent;
}): Promise<StoredSearchSource | null> {
  const next = updateSearchSource({ stored, modelKey, event });
  if (conversationId) {
    await setConversationSearchSource(uid, conversationId, next);
    notifySearchServicesChanged();
  } else if (draftSessionId) writeDraftSearchSource(draftSessionId, next);
  return next;
}
