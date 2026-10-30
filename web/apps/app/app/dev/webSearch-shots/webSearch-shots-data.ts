/**
 * Sample data for the web search page family: values always come from the shared manifest `test-fixtures/shots/webSearch.v1.json` (read by the entry and passed in as an argument),
 * the catalog uses the built-in snapshot (core catalog-snapshot), and row state / display names / grouping / test presentation are all computed by production functions.
 * Everything stays in memory: no IndexedDB writes, no key reads, no /api/search/* calls, no test searches. Loaded only via dynamic import in the dev branch.
 */
import { SEARCH_CATALOG_SNAPSHOT_VIEW } from '@oriveo/core/search/catalog-snapshot';
import { validateCatalogEntry, type CatalogEntry } from '@oriveo/core/search/search-catalog';
import type { CustomProtocol } from '@oriveo/core/search/search-transport';
import {
  resolveDefaultSearchService,
  searchAddSheetSections,
  searchTestPresentation,
  type SearchTestOutcome,
} from '@oriveo/core/search/search-settings';
import type { StoredSearchService } from '../../../lib/search/search-service-store';
import {
  buildSearchServiceView,
  type SearchConnectionOption,
  type SearchServiceView,
  type SettingsCatalog,
} from '../../../lib/search/search-settings-data';
import type { AddSheetInitial } from '../../settings/web-search/AddSearchServiceSheet';
import { checkCustomForm, emptyCustomForm, type CustomFormValues } from '../../settings/web-search/custom-form-model';
import type { TestGateState } from '../../settings/web-search/use-test-gate';
import type { WebSearchPageSource } from '../../settings/web-search/WebSearchPage';
import type { WebSearchShotPage } from './webSearch-shots-pages';
import type { AIModel, Provider } from '@oriveo/shared';
import type { NativeWebState, ToolCallSupport, WebRouteForm } from '@oriveo/core/search/search-route';
import {
  applySearchEvent,
  finishSearchReply,
  startSearchReply,
  type SearchEvent,
  type SearchReplyFinish,
  type SearchService,
  type StartSearchReplyInput,
} from '@oriveo/core/search/search-turn';
import type { CapabilityControlPresentation } from '../../../lib/core/chat/capability-control-presentation';
import type { ExternalSearchData } from '../../../lib/search/external-search-context';

export interface WebSearchShotsManifestService {
  id: string;
  kind: 'preset' | 'custom';
  serviceId?: string;
  regionId?: string;
  boundHost?: string;
  keySource: 'connection' | 'own' | 'none';
  connectionRef?: string;
  hasKey?: boolean;
  keyLast4?: string;
  name?: string;
  resultCount?: number;
  address?: string;
  protocol?: CustomProtocol;
}

export type WebSearchShotOpen =
  | 'settingsHome' | 'main' | 'addSheet' | 'connect' | 'detail' | 'customForm' | 'customConsent'
  /** Boards 6-10: chat "Model options" and its "Search method" sheet. */
  | 'modelOptions' | 'sourcePicker'
  /** Boards 11-13: one user message + one assistant reply; the reply state is computed by the production search-turn chain. */
  | 'chat';

export interface WebSearchShotsManifestPage {
  name: string;
  services: 'all' | 'none';
  preset: {
    open: WebSearchShotOpen;
    badge?: boolean;
    serviceId?: string;
    via?: 'reuse' | 'paste';
    connectionRef?: string;
    test?: SearchTestOutcome;
    becameDefault?: boolean;
    service?: string;
    draft?: { name: string; address: string; protocol: CustomProtocol };
    model?: { name: string; connection: string; form: WebRouteForm; nativeWeb: NativeWebState; toolCall: ToolCallSupport };
    webOn?: boolean;
    connections?: 'none';
    stored?: unknown;
    userText?: string;
    /** replyCases[].caseId from the shared search-contracts/search-turn.v1.json */
    replyCase?: string;
    phase?: 'searching' | 'done';
    answer?: string;
    sourcesExpanded?: boolean;
  };
}

/** The part of search-turn.v1.json the shots read: replyCases start + events (expect is not read). */
export interface SearchTurnShotFixture {
  replyCases: Array<{ caseId: string; input: { start: StartSearchReplyInput; events: SearchEvent[] } }>;
}

/** Chat shot: user message + assistant reply; the reply state is the output of production startSearchReply → applySearchEvent → finishSearchReply. */
export interface WebSearchChatShot {
  userText: string;
  providerKind: string;
  providerName: string;
  modelName: string;
  phase: 'searching' | 'done';
  /** searching: the activity stopped at the first send effect (service name + query) */
  activity: { serviceName: string; query: string } | null;
  /** done: reply finish (facts, source row, error card, sources) */
  finish: SearchReplyFinish | null;
  answer: string;
  sourcesExpanded: boolean;
  /** Source service of this reply (replyCase start.service; the id is a catalog id). */
  service: SearchService;
  /** Local search services (the error card checks whether the service still exists, and the pricing page; ids are local record ids). */
  local: { services: SearchServiceView[]; catalog: SettingsCatalog };
}

/** Model options shot: inputs to the production ModelOptionsPopover (model connection and control state built from the manifest model; the web-search card still goes through the production resolution chain). */
export interface WebSearchModelOptionsShot {
  provider: Provider;
  model: AIModel;
  webControl: CapabilityControlPresentation;
  webPreference: 'off' | 'automatic';
  /** The thinking card takes the same input as the iOS / Android hosts: auto-enable allowed, levels off / balanced, balanced selected. */
  reasoningControl: CapabilityControlPresentation;
  reasoningIntent: 'balanced';
  externalSearchSource: { data: ExternalSearchData; stored: unknown; toolCall: ToolCallSupport; panelWritable: boolean };
  initialPane?: 'searchSource';
}

export interface WebSearchShotsManifest {
  schema: 'oriveo.shots.web-search/v1';
  connections: Array<{ id: string; name: string; providerKind: string; baseUrl: string }>;
  services: WebSearchShotsManifestService[];
  defaultServiceId: string | null;
  pages: WebSearchShotsManifestPage[];
}

/** Whether the manifest is complete (the entry refuses to open an incomplete manifest). */
export function isCompleteWebSearchShotsManifest(value: unknown): value is WebSearchShotsManifest {
  if (typeof value !== 'object' || value === null) return false;
  const m = value as Partial<WebSearchShotsManifest>;
  return m.schema === 'oriveo.shots.web-search/v1'
    && Array.isArray(m.connections) && Array.isArray(m.services) && Array.isArray(m.pages)
    && (typeof m.defaultServiceId === 'string' || m.defaultServiceId === null);
}

/** Entries in the built-in snapshot that pass validation and are not withdrawn (same validation as production adoption). */
export function shotsCatalog(): SettingsCatalog {
  const view = SEARCH_CATALOG_SNAPSHOT_VIEW as { data?: { services?: unknown[] } };
  const entries = (view.data?.services ?? []).filter((e) => validateCatalogEntry(e) === null && !(e as CatalogEntry).tombstone) as CatalogEntry[];
  return { available: true, entries, withdrawn: [] };
}

function storedRecord(service: WebSearchShotsManifestService, index: number): StoredSearchService {
  const at = index + 1;
  if (service.kind === 'preset') {
    return {
      id: service.id,
      kind: 'preset',
      serviceId: service.serviceId ?? '',
      name: service.name,
      regionId: service.regionId ?? '',
      boundHost: service.boundHost ?? '',
      connectionRef: service.keySource === 'connection' ? service.connectionRef ?? null : null,
      resultCount: service.resultCount,
      createdAt: at,
      updatedAt: at,
    };
  }
  return {
    id: service.id,
    kind: 'custom',
    name: service.name ?? '',
    protocol: service.protocol ?? 'searxng',
    address: service.address ?? '',
    mapping: null,
    resultCount: service.resultCount,
    createdAt: at,
    updatedAt: at,
  };
}

function gateOf(outcome: SearchTestOutcome | undefined): TestGateState | undefined {
  if (!outcome) return undefined;
  const presentation = searchTestPresentation({ outcome });
  return presentation.state === 'passed' ? { phase: 'passed', presentation } : { phase: 'failed', presentation };
}

export interface WebSearchShotPlan {
  open: WebSearchShotOpen;
  source: WebSearchPageSource;
  /** Home cell value: display name of the default service; no service = null ("Not set") */
  defaultName: string | null;
  modelOptions?: WebSearchModelOptionsShot;
  chat?: WebSearchChatShot;
}

/** Run the production search state machine per the manifest phase: searching stops at the first request, done runs all events and then finishes. */
export function webSearchChatReply(
  fixture: SearchTurnShotFixture,
  caseId: string,
  phase: 'searching' | 'done',
): Pick<WebSearchChatShot, 'activity' | 'finish' | 'service'> {
  const replyCase = fixture.replyCases.find((c) => c.caseId === caseId);
  if (!replyCase) throw new Error(`webSearch shots: search-turn.v1.json has no replyCase ${caseId}`);
  let state = startSearchReply(replyCase.input.start);
  for (const event of replyCase.input.events) {
    const step = applySearchEvent(state, event);
    state = step.state;
    if (phase === 'searching' && step.effect.kind === 'send') {
      return { activity: { serviceName: step.effect.activity.serviceName, query: step.effect.activity.query }, finish: null, service: replyCase.input.start.service };
    }
  }
  if (phase === 'searching') throw new Error(`webSearch shots: replyCase ${caseId} never sends a search`);
  return { activity: null, finish: finishSearchReply(state), service: replyCase.input.start.service };
}

/** Manifest nativeWeb → production control state (available = recipe can auto-enable; unavailable = the model cannot browse; anything else = not listed). */
function shotWebControl(nativeWeb: NativeWebState): CapabilityControlPresentation {
  if (nativeWeb === 'available') return { state: 'auto_available', availableIntents: ['automatic'], viaLegacyProfile: false };
  if (nativeWeb === 'unavailable') return { state: 'unavailable', availableIntents: [], viaLegacyProfile: false };
  return { state: 'unknown', availableIntents: [], viaLegacyProfile: false };
}

export function webSearchShotPlan(page: WebSearchShotPage, manifest: WebSearchShotsManifest, searchTurn?: SearchTurnShotFixture): WebSearchShotPlan {
  const entry = manifest.pages.find((p) => p.name === page);
  if (!entry) throw new Error(`webSearch shots manifest has no page ${page}`);
  const catalog = shotsCatalog();
  const connections: SearchConnectionOption[] = manifest.connections.map((c) => ({ ...c, apiKey: '' }));
  const picked = entry.services === 'all' ? manifest.services : [];
  const views = picked.map((service, index) => buildSearchServiceView(
    storedRecord(service, index),
    { hasKey: service.hasKey === true, keyTail: service.keyLast4 ?? null },
    catalog,
    connections,
  ));
  const defaultId = resolveDefaultSearchService({ serviceIds: views.map((v) => v.record.id), storedDefault: manifest.defaultServiceId });
  const source: WebSearchPageSource = { uid: 'shots', catalog, snapshot: { services: views, defaultId }, connections };
  const preset = entry.preset;

  if (preset.open === 'addSheet') source.addSheet = { step: 'pick' };
  if (preset.open === 'connect') {
    const sheet = searchAddSheetSections({
      catalogAvailable: true,
      entries: catalog.entries,
      connections,
      services: views.map((v) => (v.record.kind === 'preset'
        ? { id: v.record.id, kind: 'preset' as const, serviceId: v.record.serviceId }
        : { id: v.record.id, kind: 'custom' as const })),
    });
    const row = sheet.sections.flatMap((s) => s.rows).find((r) => r.serviceId === preset.serviceId);
    if (!row) throw new Error(`webSearch shots: ${preset.serviceId} is not in the add sheet`);
    if (preset.via === 'reuse' && row.connectionRef !== preset.connectionRef) {
      throw new Error(`webSearch shots: ${preset.serviceId} does not reuse ${preset.connectionRef}`);
    }
    source.addSheet = { step: 'connect', row, mode: preset.via === 'paste' ? 'paste' : 'connection', gate: gateOf(preset.test) };
  }
  if (preset.open === 'customForm' || preset.open === 'customConsent') {
    const values: CustomFormValues = { ...emptyCustomForm(), ...preset.draft };
    source.addSheet = preset.open === 'customForm'
      ? { step: 'custom', values }
      : { step: 'customConsent', values, check: checkCustomForm(values, catalog), gate: gateOf(preset.test) } satisfies AddSheetInitial;
  }
  if (preset.open === 'detail' && preset.service) source.detail = { id: preset.service, test: gateOf(preset.test) };
  if ((preset.open === 'modelOptions' || preset.open === 'sourcePicker') && preset.model) {
    const spec = preset.model;
    const connection = manifest.connections.find((c) => c.id === spec.connection);
    if (!connection) throw new Error(`webSearch shots: no connection ${spec.connection}`);
    const pageConnections = preset.connections === 'none' ? [] : connections;
    const model = { id: spec.name, name: spec.name, capabilities: [], isAvailable: true, isDefault: true, priceTier: '' } as unknown as AIModel;
    const provider = {
      id: connection.id, kind: connection.providerKind, customName: connection.name, authMode: 'apiKey', apiKey: '',
      models: [model], status: { kind: 'connected' },
    } as unknown as Provider;
    return {
      open: preset.open,
      source,
      defaultName: views.find((v) => v.record.id === defaultId)?.name ?? null,
      modelOptions: {
        provider,
        model,
        webControl: shotWebControl(spec.nativeWeb),
        webPreference: preset.webOn ? 'automatic' : 'off',
        reasoningControl: { state: 'auto_available', availableIntents: ['off', 'balanced'], viaLegacyProfile: false },
        reasoningIntent: 'balanced',
        externalSearchSource: {
          data: { uid: 'shots', catalog, connections: pageConnections, snapshot: { services: views, defaultId } },
          stored: preset.stored ?? null,
          toolCall: spec.toolCall,
          // The connection built for the shot has no runtime identity (metadata is not read); it depicts the normal state where this session can write session-level preferences.
          panelWritable: true,
        },
        ...(preset.open === 'sourcePicker' ? { initialPane: 'searchSource' as const } : {}),
      },
    };
  }

  if (preset.open === 'chat' && preset.model) {
    const spec = preset.model;
    const connection = manifest.connections.find((c) => c.id === spec.connection);
    if (!connection) throw new Error(`webSearch shots: no connection ${spec.connection}`);
    if (!searchTurn || !preset.replyCase) throw new Error(`webSearch shots: ${page} needs search-turn.v1.json replyCases`);
    const phase = preset.phase ?? 'done';
    return {
      open: preset.open,
      source,
      defaultName: views.find((v) => v.record.id === defaultId)?.name ?? null,
      chat: {
        userText: preset.userText ?? '',
        providerKind: connection.providerKind,
        providerName: connection.name,
        modelName: spec.name,
        phase,
        ...webSearchChatReply(searchTurn, preset.replyCase, phase),
        answer: preset.answer ?? '',
        sourcesExpanded: preset.sourcesExpanded === true,
        local: { services: views, catalog },
      },
    };
  }

  return { open: preset.open, source, defaultName: views.find((v) => v.record.id === defaultId)?.name ?? null };
}
