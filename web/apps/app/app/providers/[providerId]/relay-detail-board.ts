import type { AIModel, LastUsedModelRef, LocalEngineKind, Provider, RelayKind, RelayRequestedConfig } from '@oriveo/shared';
import { inferRelayKind } from '@oriveo/shared';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { relayProviderRequiresCredential } from '../../../lib/core/providers/relay-runtime-support';
import { resolveRelayFallbackModel } from '../../../lib/core/providers/provider-selection-snapshot';
import { relayModelKey } from '../../../lib/core/providers/relay-model-identity';
import { relayKeyRows, relayShowsKeyUI } from '@oriveo/shared/relay/relay-keys';
import { relayAvatarName, resolveRelayAvatar, type RelayAvatar } from '../../../components/relay-avatar';
import {
  relayKeyCatalogText,
  relayKeyStatusKey,
  relayKeyStatusMark,
  relayKeyTitle,
  type RelayKeyStatusMark,
} from './relay-keys-board';
import {
  localChannelDisplayName,
  localEngineDisplayName,
  localThinkingValueKey,
  relayFamilyTransportLabel,
  setupProtocolForTransport,
  type LocalChannel,
  type SetupProtocol,
} from '../relay/new/setup-board';

/**
 * View state of the detail page boards (RelayDetail / LocalDetail). The component renders only from what is produced here;
 * the structure tests (BOARD-DETAIL-01 to 06) assert against this too: row order, copy keys, values and row actions.
 * Copy keys always carry a namespace and are resolved by the root translator.
 */

export const RELAY_DETAIL_TEXT = {
  endpoint: 'pages.relayDetail.endpoint',
  apiKey: 'pages.providerDetail.apiKey',
  modelLibrary: 'pages.relayDetail.modelLibrary',
  thinking: 'pages.relaySetup.localTileThinking',
  auto: 'pages.relayDetail.protocolAuto',
  /** The auto value of the default protocol row on the detail page; Edit Connection and elsewhere still use `auto`. */
  autoPerModel: 'pages.relayDetail.protocolAutoPerModel',
  modelCount: 'pages.relayDetail.modelsCount',
  keysTitle: 'pages.relayDetail.keysTitle',
  keysCount: 'pages.relayDetail.keysCount',
  keysMore: 'pages.relayDetail.keysMore',
  keysAddMoreHint: 'pages.relayDetail.keysAddMoreHint',
  checkedAt: 'pages.relayDetail.checkedAt',
} as const;

export type DetailText = { key: string; values?: Record<string, string | number> } | { literal: string };
export type DetailRowAction = 'openKeys' | 'editConnection' | 'openLibrary' | 'openWebSearch' | 'openParameters' | null;
export type DetailRowID =
  | 'endpoint'
  | 'apiKey'
  | 'defaultProtocol'
  | 'basePaths'
  | 'engineAddress'
  | 'engine'
  | 'channel'
  | 'modelLibrary'
  | 'webSearch'
  | 'thinking'
  | 'parameters';

/**
 * Color token (CSS variable name) of the leading icon on a detail row: colored per row, with the color values only in the token file.
 * Web search / thinking reuse the capability colors; the root URL row has no icon and returns null. The large header icon does not go through here (it keeps the connection's identity color).
 */
export function relayDetailRowIconColorToken(id: DetailRowID): string | null {
  switch (id) {
    case 'modelLibrary':
      return '--o-row-teal';
    case 'endpoint':
    case 'engineAddress':
      return '--o-row-cyan';
    case 'defaultProtocol':
    case 'channel':
      return '--o-row-indigo';
    case 'apiKey':
      return '--o-row-orange';
    case 'engine':
    case 'parameters':
      return '--o-row-rose';
    case 'webSearch':
      return '--o-cap-web-search';
    case 'thinking':
      return '--o-cap-reasoning';
    case 'basePaths':
      return null;
  }
}

export interface DetailBasePath {
  protocol: SetupProtocol;
  path: string;
}

/** One inline key on the keys row (the first 3 when there are >=2): name or mask / mask / catalog count or — / status word. */
export interface DetailKeyInline {
  id: string;
  title: string;
  preview: string;
  catalog: DetailText;
  /** null when never detected: neither a status word nor a mark is drawn. */
  statusKey: string | null;
  /** Same key-row component as the keys page: primary badge and status mark. */
  primaryBadge: boolean;
  statusMark: RelayKeyStatusMark | null;
}

export interface DetailRow {
  id: DetailRowID;
  titleKey: string;
  value?: DetailText;
  /** Trailing status (read-only / web search configuration status) or the "can add multiple" hint on the keys row. */
  trailingKey?: string;
  action: DetailRowAction;
  basePaths?: DetailBasePath[];
  keys?: DetailKeyInline[];
  /** "N more" when there are more than 3 keys. */
  keysMore?: number;
}

/** Connection-level generation parameters row (same as iOS): enabled rows in the model library no longer each carry a tuning button; the entry moves to this row. */
const PARAMETERS_ROW: DetailRow = { id: 'parameters', titleKey: 'common.generationParameters', action: 'openParameters' };

export interface RelayDetailBoard {
  form: 'relay' | 'local';
  /** Relay avatar (unified resolver); null for local connections, which do not use it. */
  avatar: RelayAvatar | null;
  /** Enabled ∪ catalog, de-duplicated. */
  modelCount: number;
  checkedAt?: string;
  connectionRows: DetailRow[];
  modelRows: DetailRow[];
  detectButtonKey: string;
  deleteButtonKey: string;
  footnoteKey: string;
}

/** Read-time kind: a connection protocol of auto is always treated as fully custom and is not written back to storage; otherwise the stored kind is used. */
export function relayDetailKind(
  provider: Pick<Provider, 'relayKind' | 'relayRequested'> & { baseURLText?: string | null },
): RelayKind {
  if (provider.relayRequested?.transport === 'auto') return 'custom';
  return provider.relayKind ?? inferRelayKind(provider.relayRequested);
}

const PROTOCOL_ORDER: readonly SetupProtocol[] = ['Chat', 'Responses', 'Messages', 'Gemini'];
const CONCRETE_TRANSPORTS = new Set([
  'openai_chat_completions',
  'openai_responses',
  'anthropic_messages',
  'gemini_generate_content',
]);

function rootPath(root: string): string {
  try {
    return new URL(root).pathname.replace(/\/+$/, '') || '/';
  } catch {
    return root;
  }
}

/**
 * Root URL rows: entries from the protocol URL table first in key order, then the legacy single-value root filled in by the connection's actual default protocol (auto => Chat),
 * with the same-protocol table taking precedence (same order as iOS / Android); returns empty if there are none.
 */
export function relayDetailBasePaths(requested: RelayRequestedConfig | null | undefined): DetailBasePath[] {
  const roots = new Map<SetupProtocol, string>();
  const add = (transport: string | undefined, root: string | undefined) => {
    if (!transport || !CONCRETE_TRANSPORTS.has(transport) || !root?.trim()) return;
    const protocol = setupProtocolForTransport(transport);
    if (!roots.has(protocol)) roots.set(protocol, rootPath(root.trim()));
  };
  for (const [transport, root] of Object.entries(requested?.resolvedAPIBaseURLs ?? {})) add(transport, root);
  const connectionDefault = requested?.transport === 'auto' ? 'openai_chat_completions' : requested?.transport;
  add(connectionDefault, requested?.resolvedAPIBaseURL);
  return PROTOCOL_ORDER
    .filter((protocol) => roots.has(protocol))
    .map((protocol) => ({ protocol, path: roots.get(protocol)! }));
}

const INLINE_KEY_LIMIT = 3;

/**
 * Keys row: with >=2 keys it is the title row "API Keys · N keys" + the first 3 inline + "N more".
 * Otherwise it stays a single row: tappable iff credentials are required || a Key is stored. With a Key (exactly one) it shows the mask, and when credentials are required the row end adds a "can add multiple" hint
 * (the mask already shows one is stored, so the row end no longer says saved); when credentials are required but there is no Key (S1) it shows
 * the tap-to-set prompt; otherwise (S0) it shows N7 and is not tappable. Tappable always opens the keys page (previously the change-Key dialog).
 */
function apiKeyRow(provider: Provider): DetailRow {
  if (relayShowsKeyUI(provider)) {
    const rows = relayKeyRows(provider);
    return {
      id: 'apiKey',
      titleKey: RELAY_DETAIL_TEXT.keysTitle,
      value: { key: RELAY_DETAIL_TEXT.keysCount, values: { count: rows.length } },
      action: 'openKeys',
      keys: rows.slice(0, INLINE_KEY_LIMIT).map((row) => ({
        id: row.id,
        title: relayKeyTitle(row),
        preview: row.preview,
        catalog: relayKeyCatalogText(row.catalogCount),
        statusKey: relayKeyStatusKey(row.status),
        primaryBadge: row.isPrimary,
        statusMark: relayKeyStatusMark(row.status),
      })),
      ...(rows.length > INLINE_KEY_LIMIT ? { keysMore: rows.length - INLINE_KEY_LIMIT } : {}),
    };
  }
  const hasKey = (resolveProviderAPIKey(provider) ?? '').trim().length > 0;
  const requiresCredential = relayProviderRequiresCredential(provider);
  return {
    id: 'apiKey',
    titleKey: RELAY_DETAIL_TEXT.apiKey,
    value: hasKey
      ? { literal: provider.apiKeyPreview }
      : { key: requiresCredential ? 'pages.providerDetail.hero.tapToSet' : 'pages.relayDetail.noKey' },
    // No auth required but a Key is stored: keep only the mask, no hint at the row end (such connections should not be nudged to add more Keys).
    ...(hasKey && requiresCredential ? { trailingKey: RELAY_DETAIL_TEXT.keysAddMoreHint } : {}),
    action: requiresCredential || hasKey ? 'openKeys' : null,
  };
}

function libraryCounts(provider: Provider): { enabled: number; available: number } {
  const enabledIDs = new Set(provider.models.map((model) => relayModelKey(model.id)));
  const available = provider.catalogModels.filter((model) => !enabledIDs.has(relayModelKey(model.id))).length;
  return { enabled: provider.models.length, available };
}

/** Local facts the detail page cannot read, computed by the page and passed in. */
export interface RelayDetailBoardFacts {
  /** The connection-level web search segments (including the read-time mapping of legacy fields) have at least one segment. */
  webSearchConfigured?: boolean;
}

export function relayDetailBoard(
  provider: Provider,
  lastUsedModelRef: LastUsedModelRef | null = null,
  facts: RelayDetailBoardFacts = {},
): RelayDetailBoard {
  const requested = provider.relayRequested;
  const engine = requested?.engineProfile as LocalEngineKind | undefined;
  const modelIDs = new Set([...provider.models, ...provider.catalogModels].map((model) => model.id));
  const counts = libraryCounts(provider);
  const base = {
    modelCount: modelIDs.size,
    ...(provider.lastCheckedAt ? { checkedAt: provider.lastCheckedAt } : {}),
    detectButtonKey: 'pages.relayDetail.detectAgain',
  };
  // Two footnote states: only when the default protocol is auto does re-detect re-probe each model's protocol; a selected protocol and local channels only refresh the catalog.
  const footnoteSelected = 'pages.relayDetail.detectFootnoteSelected';

  if (engine) {
    const channel: LocalChannel = requested?.transport === 'llamacpp_native' ? 'native' : 'chat';
    // A relay has no default model: the thinking row looks at the engine declaration of the fallback model (lastUsed -> first enabled).
    const fallbackModel = resolveRelayFallbackModel(provider.id, provider.models, lastUsedModelRef);
    const declared = [...provider.models, ...provider.catalogModels]
      .find((model: AIModel) => model.id === fallbackModel?.id)?.engineDeclaration?.thinking;
    const thinkingValue: DetailText = {
      localThinkingTemplate: { key: 'pages.relayDetail.thinkingTemplate' },
      localThinkingModel: { key: 'pages.relayDetail.thinkingModel' },
      // Display name of the fallback model for the unsupported placeholder; no longer writes "default model".
      localValueUnsupported: {
        key: 'pages.relayDetail.thinkingUnsupportedModel',
        values: { model: fallbackModel?.name || fallbackModel?.id || '' },
      },
    }[localThinkingValueKey(engine, channel, declared)];
    return {
      ...base,
      form: 'local',
      avatar: null,
      footnoteKey: footnoteSelected,
      connectionRows: [
        // The address row is always tappable and opens Edit Connection (provisional); the engine can only be re-detected and is not tappable.
        { id: 'engineAddress', titleKey: 'pages.relayDetail.engineAddress', value: { literal: provider.baseURLText ?? '' }, action: 'editConnection' },
        { id: 'engine', titleKey: 'pages.relayDetail.engineDetected', value: { literal: localEngineDisplayName(engine) }, action: null },
        {
          id: 'channel',
          titleKey: 'pages.relayDetail.channelRow',
          value: { literal: localChannelDisplayName(channel) },
          // Only llama.cpp has two selectable channels; for other engines the channel is read-only.
          action: engine === 'llamacpp' ? 'editConnection' : null,
        },
        apiKeyRow(provider),
      ],
      modelRows: [
        {
          id: 'modelLibrary',
          titleKey: RELAY_DETAIL_TEXT.modelLibrary,
          value: { key: 'pages.relayDetail.librarySummaryLocal', values: counts },
          action: 'openLibrary',
        },
        {
          id: 'thinking',
          titleKey: RELAY_DETAIL_TEXT.thinking,
          value: thinkingValue,
          trailingKey: 'pages.relayDetail.readOnly',
          action: null,
        },
        PARAMETERS_ROW,
      ],
      deleteButtonKey: 'pages.relayDetail.deleteConnection',
    };
  }

  const transport = requested?.transport;
  const isAuto = transport === 'auto' || !transport;
  const basePaths = relayDetailBasePaths(requested);
  return {
    ...base,
    form: 'relay',
    avatar: resolveRelayAvatar({ name: relayAvatarName(provider), baseURL: provider.baseURLText }),
    footnoteKey: isAuto ? 'pages.relayDetail.detectFootnote' : footnoteSelected,
    connectionRows: [
      // The request URL row and the default protocol row share the same destination (provisional).
      { id: 'endpoint', titleKey: RELAY_DETAIL_TEXT.endpoint, value: { literal: provider.baseURLText ?? '' }, action: 'editConnection' },
      apiKeyRow(provider),
      {
        id: 'defaultProtocol',
        titleKey: 'pages.relayDetail.defaultProtocolRow',
        value: isAuto
          ? { key: RELAY_DETAIL_TEXT.autoPerModel }
          : { literal: relayFamilyTransportLabel(transport) ?? transport },
        action: 'editConnection',
      },
      ...(basePaths.length > 0
        ? [{ id: 'basePaths' as const, titleKey: 'pages.relayDetail.basePaths', action: null, basePaths }]
        : []),
    ],
    modelRows: [
      {
        id: 'modelLibrary',
        titleKey: RELAY_DETAIL_TEXT.modelLibrary,
        value: { key: 'pages.relayDetail.librarySummary', values: counts },
        action: 'openLibrary',
      },
      // Only relays have the web search row (local engine connections have none); it opens the web search settings page.
      {
        id: 'webSearch',
        titleKey: 'common.capabilityControlWebSearch',
        value: { key: 'pages.relayDetail.webSearch.rowSubtitle' },
        trailingKey: facts.webSearchConfigured
          ? 'pages.relayDetail.webSearch.statusSet'
          : 'pages.relayDetail.webSearch.statusNotSet',
        action: 'openWebSearch',
      },
      PARAMETERS_ROW,
    ],
    deleteButtonKey: 'pages.relayDetail.deleteCustomRelay',
  };
}

export type RelayRecoveryActionID = 'editConnection' | 'apiKeys' | 'reverify';

export interface RelayRecoveryAction {
  id: RelayRecoveryActionID;
  titleKey: string;
  /** Destination of the opened page; null for re-verify, which runs in place. */
  destination: 'editConnection' | 'openKeys' | null;
  running: boolean;
  disabled: boolean;
}

export interface RelayRecoveryCard {
  titleKey: string;
  titleIcon: 'key' | 'warning';
  /** When the Key is missing the title row is tappable, with the same destination as apiKeys. */
  titleAction: 'openKeys' | null;
  /** Reason recorded on the connection (original text after trim, localized by the view); null when the Key is missing or it is overridden by a one-time notice. */
  reason: string | null;
  actions: RelayRecoveryAction[];
}

/**
 * Connection-issue recovery card for relay / local (BOARD-DETAIL-12): shown for a connection issue, or when credentials are required but no Key is stored locally;
 * official providers still use ProviderConnectionRecoveryCard, not this.
 * `omitsDetail`: when the one-time notice on the detail page is "saved without verification", the reason was already given in the notice, so the card does not repeat it.
 */
export function relayDetailRecoveryCard(
  provider: Provider,
  isReverifying: boolean,
  omitsDetail: boolean,
): RelayRecoveryCard | null {
  const requiresCredential = relayProviderRequiresCredential(provider);
  const needsKey = requiresCredential && (resolveProviderAPIKey(provider) ?? '').trim().length === 0;
  if (!needsKey && provider.status.kind !== 'issue') return null;
  const reason = needsKey || omitsDetail ? null : (provider.lastError?.trim() || null);
  const action = (
    id: RelayRecoveryActionID,
    titleKey: string,
    destination: RelayRecoveryAction['destination'],
  ): RelayRecoveryAction => {
    const running = id === 'reverify' && isReverifying;
    return { id, titleKey, destination, running, disabled: running };
  };
  return {
    titleKey: needsKey ? 'pages.providerDetail.recoveryCard.needsKeyHeadline' : 'pages.relayDetail.recoveryIssueTitle',
    titleIcon: needsKey ? 'key' : 'warning',
    titleAction: needsKey ? 'openKeys' : null,
    reason,
    actions: [
      action('editConnection', 'pages.relayDetail.editConnection', 'editConnection'),
      ...(requiresCredential ? [action('apiKeys', RELAY_DETAIL_TEXT.keysTitle, 'openKeys')] : []),
      action('reverify', 'pages.relayDetail.verifyAgain', null),
    ],
  };
}
