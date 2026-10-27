import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

function manifestPath(): string {
  let dir = resolve(import.meta.dirname);
  for (;;) {
    const candidate = join(dir, 'shared', 'test-fixtures', 'shots', 'webSearch.v1.json');
    try {
      readFileSync(candidate, 'utf8');
      return candidate;
    } catch {
      const parent = dirname(dir);
      if (parent === dir) throw new Error('webSearch.v1.json not found');
      dir = parent;
    }
  }
}

function loadManifest() {
  return JSON.parse(readFileSync(manifestPath(), 'utf8'));
}

/** The original search-turn fixture under the same repo root as the manifest (used by the chat shots to run the production state machine). */
function loadSearchTurn() {
  return JSON.parse(readFileSync(join(dirname(manifestPath()), '..', '..', 'search-contracts', 'search-turn.v1.json'), 'utf8'));
}

describe('webSearch shots shared manifest', () => {
  it('shotsManifestPagesMatchImplemented', async () => {
    const { WEB_SEARCH_SHOT_PAGES } = await import('./webSearch-shots-pages');
    const names = (loadManifest().pages as Array<{ name: string }>).map((page) => page.name);
    expect(names).toEqual([...WEB_SEARCH_SHOT_PAGES]);
  });

  it('shotsPathInstallsIsolationFence', async () => {
    const { isShotsPath } = await import('../../../lib/dev/relay-shots-mode');
    expect(isShotsPath('/dev/webSearch-shots/webSearchMain')).toBe(true);
  });

  it('shotsManifestBuildsEveryPageThroughProduction', async () => {
    const data = await import('./webSearch-shots-data');
    const { WEB_SEARCH_SHOT_PAGES } = await import('./webSearch-shots-pages');
    const manifest = loadManifest();
    const searchTurn = loadSearchTurn();
    expect(data.isCompleteWebSearchShotsManifest(manifest)).toBe(true);
    for (const page of WEB_SEARCH_SHOT_PAGES) {
      const plan = data.webSearchShotPlan(page, manifest, searchTurn);
      const entry = manifest.pages.find((p: { name: string }) => p.name === page);
      expect(plan.open, page).toBe(entry.preset.open);
      expect(plan.source.snapshot.services.length, page).toBe(entry.services === 'all' ? manifest.services.length : 0);
    }

    const main = data.webSearchShotPlan('webSearchMain', manifest);
    // Production row state: DeepSeek reuses a connection, Tavily has its own key, custom has no key filled in
    expect(main.source.snapshot.services.map((v) => [v.record.id, v.name, v.row.status, v.row.keySource, v.row.connectionName])).toEqual([
      ['s-deepseek', 'DeepSeek', 'ready', 'connection', 'DeepSeek'],
      ['s-tavily', 'Tavily', 'ready', 'own', null],
      ['s-custom', 'My search', 'ready', 'none', null],
    ]);
    expect(main.source.snapshot.defaultId).toBe('s-deepseek');
    expect(data.webSearchShotPlan('webSearchHome', manifest).defaultName).toBe('DeepSeek');
    expect(data.webSearchShotPlan('webSearchEmpty', manifest).defaultName).toBeNull();

    const reuse = data.webSearchShotPlan('webSearchConnectReuse', manifest).source.addSheet;
    expect(reuse).toMatchObject({ step: 'connect', mode: 'connection', row: { serviceId: 'kimi', regionId: 'cn', connectionRef: 'c-kimi' } });
    expect(data.webSearchShotPlan('webSearchConnectPaste', manifest).source.addSheet).toMatchObject({ step: 'connect', mode: 'paste', row: { serviceId: 'zhipu' } });
    expect(data.webSearchShotPlan('webSearchConnectPassed', manifest).source.addSheet).toMatchObject({
      step: 'connect', gate: { phase: 'passed', presentation: { state: 'passed', count: 5, latencyTenths: 8 } },
    });
    expect(data.webSearchShotPlan('webSearchDetail', manifest).source.detail).toMatchObject({ id: 's-deepseek', test: { phase: 'passed' } });
    expect(data.webSearchShotPlan('webSearchCustomManual', manifest).source.addSheet).toMatchObject({ step: 'custom', values: { protocol: 'manual' } });
    expect(data.webSearchShotPlan('webSearchCustomConsentFailed', manifest).source.addSheet).toMatchObject({
      step: 'customConsent',
      check: { host: 'search.example.com', feedback: { blocking: false } },
      gate: { phase: 'failed', presentation: { headline: 'format_mismatch', action: 'check_settings' } },
    });
  });

  it('shotsModelOptionsPagesComeFromProductionRoute', async () => {
    const data = await import('./webSearch-shots-data');
    const { externalSearchFacts, externalSearchModelKey } = await import('../../../lib/search/external-search-context');
    const { resolveModelOptionCapabilityShape, webSearchRouteForm } = await import('../../../lib/core/chat/model-option-capability-shape');
    const { resolveModelControlStatus } = await import('../../../lib/core/chat/model-control-capability-layout');
    const manifest = loadManifest();
    const webRow = (page: string) => {
      const shot = data.webSearchShotPlan(page as never, manifest).modelOptions!;
      const { input } = externalSearchFacts({
        data: shot.externalSearchSource.data,
        stored: shot.externalSearchSource.stored,
        modelKey: externalSearchModelKey(shot.provider.id, shot.model.id),
        form: webSearchRouteForm(shot.provider),
        currentProviderKind: shot.provider.kind,
        toolCall: shot.externalSearchSource.toolCall,
        panelWritable: shot.externalSearchSource.panelWritable,
      });
      return resolveModelOptionCapabilityShape({
        capability: 'web', status: resolveModelControlStatus(shot.webControl), availableIntents: shot.webControl.availableIntents,
        selectedIntent: shot.webPreference, connection: 'official', isWritable: true, protocolUndecided: false, rejectedIntents: [],
        chatTemplateThinkingIsOn: false, supportsChatTemplate: false, externalSearch: input,
      });
    };
    // Manifest stored is already in the new shape: external is enabled for this session × this model → on, "Search with DeepSeek".
    expect(webRow('webSearchOptExternal')).toMatchObject({ kind: 'toggleWithSource', isOn: true, path: 'external_tool', nativeFieldsSuppressed: true, controls: 'external', serviceId: 's-deepseek', card: { status: { key: 'card.useService', args: { name: 'DeepSeek' } }, link: { key: 'card.changeService' } } });
    expect(webRow('webSearchOptPresearch')).toMatchObject({ kind: 'toggleWithSource', isOn: true, path: 'external_presearch', card: { notes: [{ key: 'card.presearchNotice' }] } });
    // Session web search is on but external is not enabled for this model → off + not-enabled explanation.
    expect(webRow('webSearchOptNotArmed')).toMatchObject({ kind: 'toggleWithSource', isOn: false, card: { status: { key: 'card.offUseService', args: { name: 'DeepSeek' } }, notes: [{ key: 'card.armHint', args: { name: 'DeepSeek' } }] } });
    const reuse = webRow('webSearchOptReuse');
    expect(reuse).toMatchObject({ kind: 'disclosure', searchCard: { status: { key: 'card.reuseStatus', args: { name: 'DeepSeek' } }, cta: { action: 'one_tap_enable' } } });
    expect(reuse).not.toHaveProperty('link');
    expect(webRow('webSearchOptNone')).toMatchObject({ kind: 'disclosure', searchCard: { status: { key: 'card.cannotSearch' }, cta: { action: 'add_search_service' }, secondary: { action: 'open_supported_models' } } });
    expect(webRow('webSearchOptNative')).toMatchObject({ kind: 'toggleWithSource', isOn: true, path: 'native', controls: 'conversation_web', native: { kind: 'toggle' }, card: { link: { key: 'card.sourceLineNative' } } });
    // The service chosen by the session was deleted: external turns off, falls back to the model's built-in, and notifies once.
    expect(webRow('webSearchOptFallback')).toMatchObject({ kind: 'toggleWithSource', isOn: true, path: 'native', nativeFieldsSuppressed: false, card: { link: { key: 'card.sourceLineNative' }, notes: [{ key: 'card.fallbackNotice', args: { from: 'Exa' } }] } });
    expect(data.webSearchShotPlan('webSearchSourcePicker', manifest).modelOptions?.initialPane).toBe('searchSource');
  });

  it('shotsChatPagesComeFromProductionReply', async () => {
    const data = await import('./webSearch-shots-data');
    const { webSearchChatMessages } = await import('./WebSearchChatHost');
    const manifest = loadManifest();
    const searchTurn = loadSearchTurn();
    const chat = (page: string) => data.webSearchShotPlan(page as never, manifest, searchTurn).chat!;
    // Board 11: stopped at the first request: the activity row is service name + query, not finished yet
    const searching = chat('webSearchChatSearching');
    expect(searching).toMatchObject({ phase: 'searching', activity: { serviceName: 'DeepSeek', query: 'DeepSeek 搜索 API 价格' }, finish: null });
    expect(webSearchChatMessages(searching)[1]).toMatchObject({ role: 'assistant', state: 'generating', text: '' });
    // Board 12: one search with three sources, numbered 1-3 into the message sources
    const answer = chat('webSearchChatAnswer');
    expect(answer.finish).toMatchObject({ facts: { state: 'observed', searchCount: 1, sourceCount: 3 }, sourcesLine: { reused: false }, errorCard: null });
    expect(webSearchChatMessages(answer)[1].citations?.map((c) => [c.index, c.source])).toEqual([[1, 'external_search'], [2, 'external_search'], [3, 'external_search']]);
    // Board 13: insufficient balance: primary action tops up, secondary action switches to the other default
    expect(chat('webSearchChatError').finish).toMatchObject({
      facts: { state: 'failed' }, sourcesLine: null,
      errorCard: { headline: 'insufficient_balance', primaryAction: 'top_up', secondaryAction: 'switch_to_other_service', switchTo: { id: 'tavily', name: 'Tavily' } },
    });
    // Board 13: other error card layouts: each kind has a different primary action
    expect(chat('webSearchChatErrorRateLimited').finish?.errorCard).toMatchObject({ headline: 'rate_limited', primaryAction: 'retry_later', switchTo: null });
    expect(chat('webSearchChatErrorFormat').finish?.errorCard).toMatchObject({ headline: 'format_mismatch', primaryAction: 'check_settings', secondaryAction: 'switch_to_other_service' });
    expect(chat('webSearchChatErrorHostChanged').finish?.errorCard).toMatchObject({ headline: 'host_changed', primaryAction: 'reconfirm', switchTo: null });
    expect(chat('webSearchChatErrorWithdrawn').finish?.errorCard).toMatchObject({ headline: 'service_withdrawn', primaryAction: 'switch_service', switchTo: null });
    expect(chat('webSearchChatErrorNetwork').finish?.errorCard).toMatchObject({ headline: 'no_response', primaryAction: 'retry', switchTo: null });
    // Regenerate reuses the previous search: source row is reused
    expect(chat('webSearchChatReused').finish).toMatchObject({ sourcesLine: { reused: true }, errorCard: null });
    expect(() => data.webSearchShotPlan('webSearchChatAnswer', manifest)).toThrow(/search-turn/);
  });
});
