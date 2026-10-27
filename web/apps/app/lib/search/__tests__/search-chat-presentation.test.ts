// @vitest-environment node
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';
import { ERROR_CLASSES, searchErrorCard } from '@oriveo/core/search/search-transport';
import { applySearchEvent, finishSearchReply, startSearchReply, type SearchEvent, type StartSearchReplyInput } from '@oriveo/core/search/search-turn';
import { externalSearchMessagePatch } from '../../core/chat/external-search-turn';
import { nextExternalSearchActivityView } from '../../core/chat/external-search-activity';
import {
  offersRegenerateWithSearch,
  searchActivityPresentation,
  searchChipLabel,
  searchErrorCardPresentation,
  searchErrorHeadlineKey,
  searchNoticeKey,
  searchSourceRows,
  searchSourcesHeader,
  searchSourcesRecord,
  webSearchSettingsHref,
  type SearchErrorLocalFacts,
} from '../search-chat-presentation';

// Chat presentation mapping for external web search: the source card / error card inputs come from the production startSearchReply -> applySearchEvent ->
// finishSearchReply -> externalSearchMessagePatch chain (search-turn.v1.json replyCases), never hand-written state.

const REPO_ROOT = join(process.cwd(), '../../..');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (relative: string): any => JSON.parse(readFileSync(join(REPO_ROOT, relative), 'utf8'));
const searchTurn = load('shared/search-contracts/search-turn.v1.json') as {
  replyCases: Array<{ caseId: string; input: { start: StartSearchReplyInput; events: SearchEvent[] } }>;
};
const en = load('web/apps/app/messages/en.json').webSearch as Record<string, Record<string, string>>;
const has = (key: string) => {
  const [group, name] = key.split('.');
  return typeof en[group]?.[name] === 'string';
};

function persisted(caseId: string): Partial<ChatMessage> {
  const replyCase = searchTurn.replyCases.find((c) => c.caseId === caseId);
  if (!replyCase) throw new Error(`no replyCase ${caseId}`);
  let state = startSearchReply(replyCase.input.start);
  for (const event of replyCase.input.events) state = applySearchEvent(state, event).state;
  return externalSearchMessagePatch(finishSearchReply(state), replyCase.input.start.service);
}

const FACTS: SearchErrorLocalFacts = {
  serviceExists: true,
  pricingHref: 'https://example.com/pricing',
  switchToExists: true,
  setupGuideHref: 'https://docs.example/setup',
};
const CARD = {
  errorClass: 'insufficient_balance',
  headline: 'insufficient_balance',
  primaryAction: 'top_up',
  serviceId: 'svc-ds',
  serviceName: 'DeepSeek',
  switchTo: { id: 'svc-tv', name: 'Tavily' },
};

describe('source card title (persisted facts = sourcesLine)', () => {
  it('one search with three sources: searched 1 time · service name · 3 sources, expandable, rows by number', () => {
    const message = persisted('reply.tool_one_search_three_sources');
    const record = searchSourcesRecord(message);
    expect(record).not.toBeNull();
    const header = searchSourcesHeader(record!);
    expect(header).toEqual({
      lead: { key: 'chat.searchedTimes', count: 1 },
      serviceName: 'DeepSeek',
      custom: false,
      count: { key: 'chat.sourcesCount', count: 3 },
      expandable: true,
    });
    expect(searchSourceRows(message.citations).map((c) => c.index)).toEqual([1, 2, 3]);
    expect(has(header.lead.key) && has(header.count.key)).toBe(true);
    expect(offersRegenerateWithSearch(message)).toBe(true);
  });

  it('resend reuse: the first segment becomes "reusing the previous search"', () => {
    const header = searchSourcesHeader(searchSourcesRecord(persisted('reply.reuse_from_persisted_citations'))!);
    expect(header.lead).toEqual({ key: 'chat.reusedSearch' });
  });

  it('0 sources: noSources, no expand arrow; a custom service carries a label', () => {
    const header = searchSourcesHeader({
      owner: 'web', state: 'observed', source: 'external_search', revision: 'r', searchCount: 2, sourceCount: 0, serviceName: 'My SearXNG', custom: true,
    });
    expect(header).toMatchObject({ lead: { key: 'chat.searchedTimes', count: 2 }, count: { key: 'chat.noSources' }, expandable: false, custom: true });
  });

  it('all failed / not searched: no source card', () => {
    expect(searchSourcesRecord(persisted('reply.balance_error_card_switch_to_default_other'))).toBeNull();
    expect(searchSourcesRecord({ capabilityResults: undefined })).toBeNull();
  });
});

describe('error card', () => {
  it('every error class headline maps to an existing chatError.* copy key', () => {
    for (const def of Object.values(ERROR_CLASSES)) {
      const key = searchErrorHeadlineKey(def.card.headline);
      expect(key.startsWith('chatError.')).toBe(true);
      expect(has(key), key).toBe(true);
    }
    expect(searchErrorHeadlineKey('searxng_json_disabled')).toBe('chatError.searxngJsonDisabled');
    // An unrecognized headline falls back to "service returned an error"
    expect(searchErrorHeadlineKey('brand_new_headline')).toBe('chatError.serviceError');
  });

  it('production-chain balance error card: title / subline / top-up external link + answer again with Tavily', () => {
    const card = persisted('reply.balance_error_card_switch_to_default_other').searchErrorCard!;
    const p = searchErrorCardPresentation(card, { isLastMessage: true, ...FACTS });
    expect(p.titleKey).toBe('chatError.insufficientBalance');
    expect(p.titleValues).toEqual({ name: 'DeepSeek' });
    expect(p.detailKey).toBe('chat.errorDetail');
    expect(p.primary).toEqual({ labelKey: 'action.topUp', behavior: { kind: 'external', href: FACTS.pricingHref }, external: true });
    expect(p.secondary).toMatchObject({ labelKey: 'action.answerWith', labelValues: { name: card.switchTo!.name }, behavior: { kind: 'answer_with', serviceId: card.switchTo!.id } });
  });

  it.each([
    ['update_key', 'action.updateKey', { kind: 'open_service', serviceId: 'svc-ds', focus: 'key' }],
    ['retry', 'action.retry', { kind: 'regenerate' }],
    ['retry_later', 'action.retry', { kind: 'regenerate' }],
    ['switch_service', 'action.switchService', { kind: 'open_search_source_picker' }],
    ['check_settings', 'action.checkSettings', { kind: 'open_service', serviceId: 'svc-ds', focus: 'edit' }],
    ['view_setup_guide', 'action.viewSetupGuide', { kind: 'external', href: FACTS.setupGuideHref }],
    ['reconfirm', 'action.reconfirm', { kind: 'open_service', serviceId: 'svc-ds', focus: 'reconfirm' }],
  ])('primaryAction %s → %s', (action, labelKey, behavior) => {
    const p = searchErrorCardPresentation({ ...CARD, primaryAction: action }, { isLastMessage: true, ...FACTS });
    expect(p.primary).toMatchObject({ labelKey, behavior });
    expect(has(labelKey)).toBe(true);
  });

  it('old messages keep only navigation buttons: retry and "answer again with X" do not appear', () => {
    const retry = searchErrorCardPresentation({ ...CARD, primaryAction: 'retry' }, { isLastMessage: false, ...FACTS });
    expect(retry.primary).toBeNull();
    expect(retry.secondary).toBeNull();
    const topUp = searchErrorCardPresentation(CARD, { isLastMessage: false, ...FACTS });
    expect(topUp.primary?.behavior.kind).toBe('external');
    expect(topUp.secondary).toBeNull();
  });

  it('switchTo empty / replacement service no longer on this device: no secondary button', () => {
    expect(searchErrorCardPresentation({ ...CARD, switchTo: null }, { isLastMessage: true, ...FACTS }).secondary).toBeNull();
    expect(searchErrorCardPresentation(CARD, { isLastMessage: true, ...FACTS, switchToExists: false }).secondary).toBeNull();
    // A network failure offers no replacement: the production searchErrorCard emits no secondary action, so switchTo is empty when persisted
    expect(searchErrorCard('network', { otherServices: 2 }).secondaryAction).toBeUndefined();
  });

  it('service no longer exists on this device: navigation buttons instead open the "Web search" settings page', () => {
    const gone = { ...FACTS, serviceExists: false, pricingHref: null };
    for (const action of ['update_key', 'check_settings', 'reconfirm', 'top_up']) {
      const p = searchErrorCardPresentation({ ...CARD, primaryAction: action }, { isLastMessage: true, ...gone });
      expect(p.primary?.behavior, action).toEqual({ kind: 'open_settings' });
    }
    expect(webSearchSettingsHref({ kind: 'open_settings' })).toBe('/settings/web-search');
    expect(webSearchSettingsHref({ kind: 'open_service', serviceId: 'svc ds', focus: 'key' })).toBe('/settings/web-search?service=svc+ds&focus=key');
  });
});

describe('activity row and hints', () => {
  it('capsule: appended per call, retries not repeated, no longer spinning after deliver; at most the latest 3 shown', () => {
    let view = nextExternalSearchActivityView(null, { serviceName: 'DeepSeek', query: 'q1' });
    view = nextExternalSearchActivityView(view, { serviceName: 'DeepSeek', query: 'q1' });
    expect(view?.chips).toEqual([{ query: 'q1', searching: true }]);
    view = nextExternalSearchActivityView(view, null);
    for (const q of ['q2', 'q3', 'q4']) {
      view = nextExternalSearchActivityView(view, { serviceName: 'DeepSeek', query: q });
      view = nextExternalSearchActivityView(view, q === 'q4' ? { serviceName: 'DeepSeek', query: q } : null);
    }
    const searching = searchActivityPresentation({ isGenerating: true, hasBodyText: false, activity: 'external_search', view });
    expect(searching).toEqual({
      kind: 'searching',
      serviceName: 'DeepSeek',
      chips: [{ label: 'q2', searching: false }, { label: 'q3', searching: false }, { label: 'q4', searching: true }],
    });
    view = nextExternalSearchActivityView(view, null);
    expect(searchActivityPresentation({ isGenerating: true, hasBodyText: false, activity: null, view })?.kind).toBe('answering');
    expect(searchActivityPresentation({ isGenerating: true, hasBodyText: true, activity: null, view })).toBeNull();
    // Thinking content starts streaming in: collapse likewise
    expect(searchActivityPresentation({ isGenerating: true, hasBodyText: false, hasReasoningText: true, activity: null, view })).toBeNull();
    expect(searchActivityPresentation({ isGenerating: false, hasBodyText: false, activity: null, view })).toBeNull();
    expect(has('chat.searching') && has('chat.answeringFromResults')).toBe(true);
  });

  it('capsule text takes the first line, truncated beyond 40 characters with an ellipsis', () => {
    expect(searchChipLabel('first line\nsecond')).toBe('first line');
    expect(searchChipLabel('\n  \nreal query\nmore')).toBe('real query');
    expect(searchChipLabel('a'.repeat(41))).toBe(`${'a'.repeat(40)}…`);
    expect(searchChipLabel('b'.repeat(40))).toBe('b'.repeat(40));
  });

  it('rejected reroute hint recognizes only tools_rejected; without external sources there is no "Regenerate and search again"', () => {
    expect(searchNoticeKey({ searchNotice: 'tools_rejected' })).toBe('chat.toolsRejectedNotice');
    expect(searchNoticeKey({ searchNotice: 'no_tool_continuation' })).toBeNull();
    expect(has('chat.toolsRejectedNotice') && has('chat.regenerateWithSearch') && has('chat.mcpOnceOnly')).toBe(true);
    expect(offersRegenerateWithSearch({ citations: [{ url: 'https://a.example/', source: 'library' }] })).toBe(false);
  });
});
