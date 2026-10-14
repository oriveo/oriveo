import type { Provider } from '@oriveo/shared';
import {
  RELAY_WEB_FRAGMENT_TEMPLATES,
  RELAY_WEB_TRANSPORTS,
  isRelayWebTransport,
  validateRelayWebFragment,
  type RelayWebFragmentError,
  type RelayWebFragments,
  type RelayWebTransport,
} from '@oriveo/shared/relay/web-fragments';
import { effectiveRelayWebFragmentsForProvider, relayWebFragmentForTransport } from '../../../lib/core/chat/relay-web-fragments';
import { currentRelayWebProbeRecord } from '../../../lib/core/chat/relay-web-probe-records';
import { relayWebProbeTransport } from '../../../lib/core/relay-web-probe-ops';
import { setupProtocolForTransport } from '../relay/new/setup-board';
import { relayDetailBasePaths } from './relay-detail-board';
import { RELAY_EDIT_TEXT } from './relay-edit-board';

const TEXT = 'pages.relayDetail.webSearch';

/** Web search settings page copy; the unsaved-changes hint is the same set as Edit Connection. */
export const RELAY_WEB_SEARCH_TEXT = {
  title: 'common.capabilityControlWebSearch',
  intro: `${TEXT}.intro`,
  chatNote: `${TEXT}.chatNote`,
  footer: 'pages.relayDetail.advanced.localOnly',
  save: 'common.save',
  otherProtocols: `${TEXT}.otherProtocols`,
  probeDisclosure: `${TEXT}.probeDisclosure`,
  rejectedTitle: `${TEXT}.rejectedTitle`,
  retest: `${TEXT}.retest`,
  setCount: RELAY_EDIT_TEXT.setCount,
  useTemplate: `${TEXT}.useTemplate`,
  clear: `${TEXT}.clear`,
  templateReplaceTitle: `${TEXT}.templateReplaceTitle`,
  templateReplaceMessage: `${TEXT}.templateReplaceMessage`,
  templateReplace: `${TEXT}.templateReplace`,
  cancel: 'common.cancel',
  discardTitle: RELAY_EDIT_TEXT.discardTitle,
  unsavedMessage: RELAY_EDIT_TEXT.unsavedMessage,
  keepEditing: RELAY_EDIT_TEXT.keepEditing,
  discard: RELAY_EDIT_TEXT.discard,
} as const;

const ERROR_KEYS: Readonly<Record<RelayWebFragmentError, string>> = {
  not_json: `${TEXT}.errorNotObject`,
  not_object: `${TEXT}.errorNotObject`,
  empty: `${TEXT}.errorNotObject`,
  forbidden_key: `${TEXT}.errorForbiddenKey`,
  invalid_tools: `${TEXT}.errorInvalidTools`,
  function_tool: `${TEXT}.errorFunctionTool`,
  too_large: `${TEXT}.errorTooLarge`,
};

export type RelayWebDrafts = Record<RelayWebTransport, string>;

export interface RelayWebSection {
  transport: RelayWebTransport;
  raw: string;
  /** Error copy when a value is filled in wrongly; empty / whitespace-only is not validated. */
  error: { key: string; values?: Record<string, string> } | null;
  showsChatNote: boolean;
}

export interface RelayWebOtherGroup {
  sections: RelayWebSection[];
  expanded: boolean;
  /** The group has a wrongly filled segment: stay expanded (collapsing would hide the error while the save button is greyed out). */
  forcedOpen: boolean;
  /** Filled count (0 is not written). */
  trailing: { key: string; values: { count: number } } | null;
}

export interface RelayWebSearchBoard {
  mainSections: RelayWebSection[];
  /** null = all four segments expanded, no collapsible group. */
  otherGroup: RelayWebOtherGroup | null;
  /** Differs from the page-entry baseline after normalization. */
  hasChanges: boolean;
  hasError: boolean;
  canSave: boolean;
}

// Saved segments enter the draft as compact single-line JSON, the same format as the template (relayWebTemplateText) and iOS.
function compact(value: unknown): string {
  return JSON.stringify(value);
}

/** Page-entry content: the segments in storage; with no storage but a legacy-field mapping, shows the mapping result (the mapping content is the baseline and does not count as a change). */
export function relayWebDraftsFromProvider(provider: Provider): RelayWebDrafts {
  const effective = effectiveRelayWebFragmentsForProvider(provider);
  return Object.fromEntries(RELAY_WEB_TRANSPORTS.map((transport) => [
    transport,
    effective[transport] ? compact(effective[transport]) : '',
  ])) as RelayWebDrafts;
}

/** Normalization: whitespace only = empty; valid JSON is compared by its parsed result (whitespace-only changes do not count); anything else is compared as the original text with leading/trailing whitespace trimmed. */
function normalized(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return '';
  const validation = validateRelayWebFragment(trimmed);
  return validation.ok ? JSON.stringify(validation.fragment) : trimmed;
}

function sectionOf(transport: RelayWebTransport, raw: string): RelayWebSection {
  const validation = raw.trim() ? validateRelayWebFragment(raw) : null;
  const error = validation && !validation.ok
    ? { key: ERROR_KEYS[validation.error], ...(validation.key ? { values: { key: validation.key } } : {}) }
    : null;
  return { transport, raw, error, showsChatNote: transport === 'openai_chat_completions' };
}

/**
 * Expanded set = protocols listed in the detail page "root URL" rows ∪ the connection's selected protocol; null when the connection protocol is auto and there is no root URL yet (all four segments expanded).
 */
function expandedTransports(provider: Provider): ReadonlySet<RelayWebTransport> | null {
  const requested = provider.relayRequested;
  const selected = requested?.transport && requested.transport !== 'auto' ? requested.transport : null;
  const protocols = new Set<string>(relayDetailBasePaths(requested).map((path) => path.protocol));
  if (!selected && protocols.size === 0) return null;
  return new Set(RELAY_WEB_TRANSPORTS.filter((transport) => (
    protocols.has(setupProtocolForTransport(transport)) || (isRelayWebTransport(selected) && selected === transport)
  )));
}

export function relayWebSearchBoard(input: {
  provider: Provider;
  drafts: RelayWebDrafts;
  /** Content at page entry (re-entering after a save gives the new baseline). */
  baseline: RelayWebDrafts;
  /** Expanded state recorded when the user taps a collapsible group header; undefined if never tapped. */
  otherChoice?: boolean;
}): RelayWebSearchBoard {
  const { provider, drafts, baseline } = input;
  const sections = RELAY_WEB_TRANSPORTS.map((transport) => sectionOf(transport, drafts[transport]));
  const expanded = expandedTransports(provider);
  const mainSections = expanded ? sections.filter((section) => expanded.has(section.transport)) : sections;
  const otherSections = expanded ? sections.filter((section) => !expanded.has(section.transport)) : [];
  let otherGroup: RelayWebOtherGroup | null = null;
  if (otherSections.length > 0) {
    const forcedOpen = otherSections.some((section) => section.error);
    const count = otherSections.filter((section) => section.raw.trim().length > 0).length;
    otherGroup = {
      sections: otherSections,
      expanded: forcedOpen || input.otherChoice === true,
      forcedOpen,
      trailing: count > 0 ? { key: RELAY_WEB_SEARCH_TEXT.setCount, values: { count } } : null,
    };
  }
  const hasChanges = RELAY_WEB_TRANSPORTS.some((transport) => normalized(drafts[transport]) !== normalized(baseline[transport]));
  const hasError = sections.some((section) => section.error);
  return { mainSections, otherGroup, hasChanges, hasError, canSave: hasChanges && !hasError };
}

export interface RelayWebRejectedModel {
  modelId: string;
  name: string;
}

/**
 * "Models that reject these settings": enabled models in enabled order whose first-launch protocol (same resolution as probing and records) has a saved segment
 * and whose record that is valid for that saved segment is rejected; uses the saved segment, ignoring the in-page draft.
 */
export function relayWebRejectedModels(provider: Provider): RelayWebRejectedModel[] {
  return provider.models.flatMap((model) => {
    const transport = relayWebProbeTransport(provider, model);
    const fragment = transport ? relayWebFragmentForTransport(provider, transport) : undefined;
    if (!transport || !fragment) return [];
    const record = currentRelayWebProbeRecord({ connectionId: provider.id, modelId: model.id, transport }, fragment);
    return record?.result === 'rejected' ? [{ modelId: model.id, name: model.name || model.id }] : [];
  });
}

/** Tapping a collapsible group header: when expanded by a wrong entry only record it as expanded (so it does not collapse in the user's face after being fixed), otherwise toggle. */
export function relayWebNextOtherChoice(group: Pick<RelayWebOtherGroup, 'expanded' | 'forcedOpen'>): boolean {
  return group.forcedOpen ? true : !group.expanded;
}

// The template inserts compact single-line JSON, the same string on all three platforms.
export function relayWebTemplateText(transport: RelayWebTransport): string {
  return JSON.stringify(RELAY_WEB_FRAGMENT_TEMPLATES[transport]);
}

/** "Fill in template": empty / whitespace only / content already equal to the template -> fill directly; other content asks for confirmation first. */
export function relayWebTemplateNeedsConfirm(transport: RelayWebTransport, raw: string): boolean {
  const current = normalized(raw);
  return current !== '' && current !== normalized(relayWebTemplateText(transport));
}

/** The segments to save (empty segment = delete that segment); returns null when a segment is wrongly filled. */
export function relayWebFragmentsToSave(drafts: RelayWebDrafts): RelayWebFragments | null {
  const fragments: RelayWebFragments = {};
  for (const transport of RELAY_WEB_TRANSPORTS) {
    const raw = drafts[transport];
    if (!raw.trim()) continue;
    const validation = validateRelayWebFragment(raw);
    if (!validation.ok) return null;
    fragments[transport] = validation.fragment;
  }
  return fragments;
}
