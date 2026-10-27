/**
 * Presentation mapping for external web search in chat (contract section 15).
 *
 * Each UI state reads from a single source: the activity row reads the streaming activity `external_search` + the activity display context; the source card reads the persisted
 * capability result (the same facts as finishSearchReply.sourcesLine); the error card reads the persisted searchErrorCard;
 * the rejected-reroute hint reads searchNotice. This file only maps "facts -> copy key / button / behavior"; it reads no storage and touches no UI.
 * Copy keys are all relative to the next-intl namespace `webSearch`.
 */
import type { ChatMessage, Citation } from '@oriveo/shared';
import type { StreamActivity } from '@oriveo/core/providers/types';
import { ERROR_CLASSES } from '@oriveo/core/search/search-transport';
import type { ExternalSearchActivityView } from '../core/chat/external-search-activity';

type ExternalSearchErrorCard = NonNullable<ChatMessage['searchErrorCard']>;

// ── Activity row ────────────────────────────────────────────────────

export const SEARCH_CHIP_MAX = 3;
export const SEARCH_CHIP_MAX_CHARS = 40;

/** Search-term capsule text: take the first non-empty line, truncate beyond 40 characters with an ellipsis (counted in graphemes, never splitting emoji / combining characters). */
export function searchChipLabel(query: string): string {
  const firstLine = query.split(/\r?\n/).map((line) => line.trim()).find((line) => line !== '') ?? '';
  const graphemes = typeof Intl !== 'undefined' && 'Segmenter' in Intl
    ? Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(firstLine), (s) => s.segment)
    : Array.from(firstLine);
  return graphemes.length > SEARCH_CHIP_MAX_CHARS ? `${graphemes.slice(0, SEARCH_CHIP_MAX_CHARS).join('')}…` : firstLine;
}

export type SearchActivityPresentation =
  | { kind: 'searching'; serviceName: string; chips: Array<{ label: string; searching: boolean }> }
  | { kind: 'answering'; chips: Array<{ label: string; searching: boolean }> }
  | null;

/**
 * Activity row: streaming activity is `external_search` -> "Searching with {name}..." + capsule; after all deliveries until the first character ->
 * `chat.answeringFromResults` (the capsule stays but stops spinning; it also collapses once thinking content streams in); otherwise = null (hand back to the generic waiting feedback).
 * Capsules are appended per call in order, showing at most the latest 3 (the one currently searching is always on screen).
 */
export function searchActivityPresentation(input: {
  isGenerating: boolean;
  hasBodyText: boolean;
  /** Thinking content has already streamed in this turn: "Answering from the search results..." likewise collapses. */
  hasReasoningText?: boolean;
  activity: StreamActivity | null;
  view: ExternalSearchActivityView | null;
}): SearchActivityPresentation {
  if (!input.isGenerating || !input.view || input.view.chips.length === 0) return null;
  const chips = input.view.chips.slice(-SEARCH_CHIP_MAX).map((chip) => ({ label: searchChipLabel(chip.query), searching: chip.searching }));
  if (input.activity === 'external_search') return { kind: 'searching', serviceName: input.view.serviceName, chips };
  if (input.activity === null && !input.hasBodyText && !input.hasReasoningText && input.view.chips.every((chip) => !chip.searching)) {
    return { kind: 'answering', chips };
  }
  return null;
}

// ── Source card ────────────────────────────────────────────────────

type CapabilityResult = NonNullable<ChatMessage['capabilityResults']>[number];

export interface SearchSourcesHeader {
  lead: { key: 'chat.reusedSearch' } | { key: 'chat.searchedTimes'; count: number };
  serviceName: string;
  custom: boolean;
  count: { key: 'chat.sourcesCount'; count: number } | { key: 'chat.noSources' };
  /** With 0 sources there is no expand arrow. */
  expandable: boolean;
}

/** Persisted external search facts (same condition as finishSearchReply.sourcesLine: searched and not all failed). */
export function searchSourcesRecord(message: Pick<ChatMessage, 'capabilityResults'>): CapabilityResult | null {
  const record = message.capabilityResults?.find((r) => r.source === 'external_search');
  if (!record || record.state === 'failed' || !(record.searchCount && record.searchCount > 0)) return null;
  return record;
}

export function searchSourcesHeader(record: CapabilityResult): SearchSourcesHeader {
  const sourceCount = record.sourceCount ?? 0;
  return {
    lead: record.reused ? { key: 'chat.reusedSearch' } : { key: 'chat.searchedTimes', count: record.searchCount ?? 0 },
    serviceName: record.serviceName ?? '',
    custom: record.custom === true,
    count: sourceCount > 0 ? { key: 'chat.sourcesCount', count: sourceCount } : { key: 'chat.noSources' },
    expandable: sourceCount > 0,
  };
}

/** Source card rows: this message's external search sources, ordered by number. */
export function searchSourceRows(citations: readonly Citation[] | null | undefined): Citation[] {
  return (citations ?? [])
    .filter((c) => c.source === 'external_search')
    .slice()
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
}

// ── Error card ────────────────────────────────────────────────────

const KNOWN_HEADLINES: ReadonlySet<string> = new Set(Object.values(ERROR_CLASSES).map((def) => def.card.headline));

/** headline (snake_case) -> `chatError.<camelCase>`; an unrecognized headline falls back to `chatError.serviceError`. */
export function searchErrorHeadlineKey(headline: string): string {
  if (!KNOWN_HEADLINES.has(headline)) return 'chatError.serviceError';
  return `chatError.${headline.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase())}`;
}

/** What a button does when pressed (the UI executes by kind). */
export type SearchErrorBehavior =
  | { kind: 'open_service'; serviceId: string; focus?: 'key' | 'edit' | 'reconfirm' }
  | { kind: 'open_settings' }
  | { kind: 'external'; href: string }
  | { kind: 'regenerate' }
  | { kind: 'open_search_source_picker' }
  | { kind: 'answer_with'; serviceId: string; serviceName: string };

export interface SearchErrorButton {
  labelKey: string;
  labelValues?: Record<string, string>;
  behavior: SearchErrorBehavior;
  /** External-link buttons carry an external-link icon. */
  external: boolean;
}

export interface SearchErrorCardPresentation {
  titleKey: string;
  titleValues: { name: string };
  detailKey: 'chat.errorDetail';
  primary: SearchErrorButton | null;
  secondary: SearchErrorButton | null;
}

export interface SearchErrorLocalFacts {
  /** The failing service still exists on this device. */
  serviceExists: boolean;
  /** The pricing page for that service and site (regionLinks(entry, regionId).pricing); unavailable = null. */
  pricingHref: string | null;
  /** The replacement service still exists on this device. */
  switchToExists: boolean;
  /** The same configuration guide link as the connect page. */
  setupGuideHref: string;
}

/**
 * Error card: title / subline / primary button (per primaryAction) / secondary button (when switchTo is set, "Answer again with {name}").
 * Buttons that regenerate (retry, answer again with another service) appear only on the last answer; older messages keep only navigation buttons;
 * when the service no longer exists on this device, navigation buttons instead open the "Web search" settings page.
 */
export function searchErrorCardPresentation(
  card: ExternalSearchErrorCard,
  options: { isLastMessage: boolean } & SearchErrorLocalFacts,
): SearchErrorCardPresentation {
  const toService = (focus?: 'key' | 'edit' | 'reconfirm'): SearchErrorBehavior => (options.serviceExists
    ? { kind: 'open_service', serviceId: card.serviceId, ...(focus ? { focus } : {}) }
    : { kind: 'open_settings' });
  const button = (labelKey: string, behavior: SearchErrorBehavior): SearchErrorButton => ({
    labelKey,
    behavior,
    external: behavior.kind === 'external',
  });
  let primary: SearchErrorButton | null = null;
  switch (card.primaryAction) {
    case 'update_key':
      primary = button('action.updateKey', toService('key'));
      break;
    case 'top_up':
      primary = button('action.topUp', options.serviceExists && options.pricingHref
        ? { kind: 'external', href: options.pricingHref }
        : { kind: 'open_settings' });
      break;
    case 'retry':
    case 'retry_later':
      primary = options.isLastMessage ? button('action.retry', { kind: 'regenerate' }) : null;
      break;
    case 'switch_service':
      primary = button('action.switchService', { kind: 'open_search_source_picker' });
      break;
    case 'check_settings':
      primary = button('action.checkSettings', toService('edit'));
      break;
    case 'view_setup_guide':
      primary = button('action.viewSetupGuide', { kind: 'external', href: options.setupGuideHref });
      break;
    case 'reconfirm':
      primary = button('action.reconfirm', toService('reconfirm'));
      break;
    default:
      primary = null;
  }
  const secondary: SearchErrorButton | null = card.switchTo && options.isLastMessage && options.switchToExists
    ? {
      labelKey: 'action.answerWith',
      labelValues: { name: card.switchTo.name },
      behavior: { kind: 'answer_with', serviceId: card.switchTo.id, serviceName: card.switchTo.name },
      external: false,
    }
    : null;
  return {
    titleKey: searchErrorHeadlineKey(card.headline),
    titleValues: { name: card.serviceName },
    detailKey: 'chat.errorDetail',
    primary,
    secondary,
  };
}

// ── Rejected-reroute hint / regenerate menu ──────────────────────────────────────────

/** A persisted searchNotice of tools_rejected -> the reply hint-row copy key; others are not shown. */
export function searchNoticeKey(message: Pick<ChatMessage, 'searchNotice'>): 'chat.toolsRejectedNotice' | null {
  return message.searchNotice === 'tools_rejected' ? 'chat.toolsRejectedNotice' : null;
}

/** When the message has external_search sources, the regenerate menu gains an item "Regenerate and search again". */
export function offersRegenerateWithSearch(message: Pick<ChatMessage, 'citations'>): boolean {
  return (message.citations ?? []).some((c) => c.source === 'external_search');
}

/** Address of the "Web search" settings page: opens the details with the service id, focus pointing at the block to handle. */
export function webSearchSettingsHref(behavior: Extract<SearchErrorBehavior, { kind: 'open_service' | 'open_settings' }>): string {
  if (behavior.kind === 'open_settings') return '/settings/web-search';
  const params = new URLSearchParams({ service: behavior.serviceId });
  if (behavior.focus) params.set('focus', behavior.focus);
  return `/settings/web-search?${params.toString()}`;
}

/** Error card "switch service": the input bar opens the "Search method" page of model options (InputComposer listens). */
export const OPEN_SEARCH_SOURCE_PICKER_EVENT = 'oriveo:open-search-source-picker';
