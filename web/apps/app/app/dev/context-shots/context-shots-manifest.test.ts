import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { fileURLToPath } from 'node:url';

const mocks = vi.hoisted(() => ({
  notFound: vi.fn(() => {
    throw new Error('NEXT_HTTP_ERROR_FALLBACK;404');
  }),
  /** When non-null, the manifest text read by the entry is replaced with it (the test's own file reads are unaffected). */
  manifestText: null as string | null,
}));

vi.mock('next/navigation', () => ({ notFound: mocks.notFound }));
vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>();
  const readFileSync = ((path: Parameters<typeof actual.readFileSync>[0], ...rest: unknown[]) => {
    if (mocks.manifestText !== null && String(path).endsWith('context.v1.json')) return mocks.manifestText;
    return (actual.readFileSync as (...args: unknown[]) => unknown)(path, ...rest);
  }) as typeof actual.readFileSync;
  return { ...actual, default: { ...actual, readFileSync }, readFileSync };
});

function manifestPath(): string {
  let dir = resolve(import.meta.dirname);
  for (;;) {
    const candidate = join(dir, 'shared', 'test-fixtures', 'shots', 'context.v1.json');
    try {
      readFileSync(candidate, 'utf8');
      return candidate;
    } catch {
      const parent = dirname(dir);
      if (parent === dir) throw new Error('context.v1.json not found');
      dir = parent;
    }
  }
}

/** Hands out a fresh copy each time, so changing it does not affect other cases. */
function loadManifest() {
  return JSON.parse(readFileSync(manifestPath(), 'utf8'));
}

/** An in-memory store just sufficient for applyContextShotPlan. */
function memoryStore() {
  const state: Record<string, unknown> = { preferences: {}, conversations: [], providers: [] };
  return {
    state,
    store: {
      getState: () => state,
      setState: (patch: Record<string, unknown>) => Object.assign(state, patch),
    } as never,
  };
}

describe('context shots shared sample manifest', () => {
  let uninstall: (() => void) | null = null;
  let restoreMetadata: (() => void) | null = null;

  beforeAll(async () => {
    const fence = await import('../relay-shots/relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./context-shots-data');
    restoreMetadata = await data.loadContextShotsMetadata(loadManifest());
  });

  afterAll(() => {
    restoreMetadata?.();
    uninstall?.();
    mocks.manifestText = null;
    vi.restoreAllMocks();
  });

  it('shotsManifestPagesMatchImplemented', async () => {
    const { CONTEXT_SHOT_PAGES } = await import('./context-shots-pages');
    const names = (loadManifest().pages as Array<{ name: string }>).map((page) => page.name);
    expect(new Set(names)).toEqual(new Set(CONTEXT_SHOT_PAGES));
    expect(names).toHaveLength(CONTEXT_SHOT_PAGES.length);
  });

  it('shotsManifestModelsDecodedByProductionMetadata', async () => {
    const data = await import('./context-shots-data');
    const { resolveCatalogModel } = await import('../../../lib/core/metadata/metadata-client');
    const manifest = loadManifest();
    expect(data.isCompleteContextShotsManifest(manifest)).toBe(true);
    for (const model of manifest.models as Array<{ provider: string; entry: { id: string; contextLength?: number; maxOutputTokens?: number; pricing?: { longContext?: { thresholdTokens: number } } } }>) {
      const resolved = resolveCatalogModel(model.entry.id, data.contextShotProviderKind(model.provider));
      expect(resolved?.contextLength).toBe(model.entry.contextLength);
      expect(resolved?.maxOutputTokens).toBe(model.entry.maxOutputTokens);
      expect(resolved?.pricing?.longContext?.thresholdTokens).toBe(model.entry.pricing?.longContext?.thresholdTokens);
    }
    // The display name reads the Server-delivered key displayName (fixture b69a1901dc), with no fallback to name.
    const picker = data.contextShotPlan('contextCapPicker', manifest);
    expect(picker.model?.name).toBe('Grok 4.7');
  });

  it('shotsManifestRingLabelsFromProductionUsage', async () => {
    const data = await import('./context-shots-data');
    const { readContextUsageState, currentUsageBudgetOf } = await import('../../../lib/core/chat/context-visibility/use-context-usage');
    const { usageRingOf } = await import('../../../lib/core/chat/context-visibility/usage-summary');
    const { separatorHistoryOf } = await import('../../../lib/core/chat/context-compaction/use-compaction-separator');
    const { displayRhoHiOf } = await import('../../../lib/core/chat/context-pipeline/chat-context');
    const manifest = loadManifest();
    const labels: Record<string, string | null> = {};
    for (const page of ['contextRingNormal', 'contextRingHigh', 'contextRingOver'] as const) {
      const plan = data.contextShotPlan(page, manifest);
      const { store } = memoryStore();
      await data.applyContextShotPlan(plan, store);
      const conversation = plan.conversation!;
      const currentB = currentUsageBudgetOf(plan.provider!, plan.model!.id, conversation.id, conversation.contextCap ?? 'auto');
      const rhoHi = await displayRhoHiOf(plan.provider!, plan.model!.id);
      const usage = await readContextUsageState(conversation.id, separatorHistoryOf(conversation.messages), rhoHi, currentB);
      labels[page] = usageRingOf(usage.summary)?.label ?? null;
    }
    expect(labels).toEqual({ contextRingNormal: '38', contextRingHigh: '76', contextRingOver: '!' });
    // New empty conversation: no session is opened and there is no ring.
    expect(data.contextShotPlan('contextRingHidden', manifest).conversationId).toBeNull();
  });

  it('shotsPlanSuppressesNoteCaptureHint', async () => {
    const data = await import('./context-shots-data');
    const { CONTEXT_SHOT_PAGES } = await import('./context-shots-pages');
    const manifest = loadManifest();
    for (const page of CONTEXT_SHOT_PAGES) {
      expect(data.contextShotPlan(page, manifest).preferences.hasSeenNoteCaptureHint, page).toBe(true);
    }
    // The preference written into the store is exactly the one MessageBubble reads (apply only one page without a prompt, to avoid polluting other cases).
    const { state, store } = memoryStore();
    await data.applyContextShotPlan(data.contextShotPlan('contextRingNormal', manifest), store);
    expect((state.preferences as { hasSeenNoteCaptureHint?: boolean }).hasSeenNoteCaptureHint).toBe(true);
  });

  it('shotsManifestCheckpointsAndHintThroughProduction', async () => {
    const data = await import('./context-shots-data');
    const { ContextCompactionStore } = await import('../../../lib/core/chat/context-compaction/context-compaction-store');
    const { separatorHistoryOf } = await import('../../../lib/core/chat/context-compaction/use-compaction-separator');
    const { pendingCompactionHint } = await import('../../../lib/core/chat/context-compaction/context-compaction-actions');
    const manifest = loadManifest();

    for (const [page, kind] of [['contextDividerSummary', 'summary'], ['contextDividerVerbatim', 'fallback']] as const) {
      const plan = data.contextShotPlan(page, manifest);
      await data.applyContextShotPlan(plan, memoryStore().store);
      const row = await ContextCompactionStore.latestValid(plan.conversationId!, separatorHistoryOf(plan.conversation!.messages));
      expect(row?.kind).toBe(kind);
      expect(row?.coversTo).toBe(data.contextShotMessageId(manifest.checkpoints[kind].coversTo));
    }
    expect(pendingCompactionHint()).toBeNull();

    const hint = data.contextShotPlan('contextCompactHint', manifest);
    expect((await data.contextShotCheckpointRows(hint)).map((row) => row.coversTo)).toEqual(['a4', 'a3', 'a2'].map(data.contextShotMessageId));
    await data.applyContextShotPlan(hint, memoryStore().store);
    expect(pendingCompactionHint()).toBe(hint.conversationId);
    expect(data.contextShotPlan('contextCheckpointDetail', manifest).openDetail).toBe(true);
  });

  it('shotsManifestSuggestionsThroughProduction', async () => {
    const data = await import('./context-shots-data');
    const directiveModule = await import('../../../lib/core/chat/conversation-instructions/directive-suggestion');
    const { getPendingMemorySuggestion } = await import('../../../lib/core/chat/conversation-instructions/memory-suggestion');
    const manifest = loadManifest();
    const directivePage = manifest.pages.find((p: { name: string }) => p.name === 'contextDirectiveSuggestion');
    const directive = data.contextShotPlan('contextDirectiveSuggestion', manifest);
    await data.applyContextShotPlan(directive, memoryStore().store);
    expect(directiveModule.getPendingDirectiveSuggestion()).toEqual({
      conversationId: directive.conversationId,
      messageId: data.contextShotMessageId(directivePage.directiveSuggestion.userId),
      sentence: directivePage.directiveSuggestion.sentence,
    });

    const memory = data.contextShotPlan('contextMemorySuggestion', manifest);
    await data.applyContextShotPlan(memory, memoryStore().store);
    const suggestion = getPendingMemorySuggestion();
    expect(suggestion?.status).toBe('candidate');
    expect(suggestion?.assistantMessageId).toBe(data.contextShotMessageId('a7'));
    expect(suggestion?.status === 'candidate' ? suggestion.candidate.content : null).toBe('Is vegetarian.');
  });

  it('shotsManifestUpperLayersThroughProduction', async () => {
    const data = await import('./context-shots-data');
    const { capPresentationInputOf, capPickerOf } = await import('../../../lib/core/chat/context-visibility/cap-presentation');
    const { pendingCapConfirmationOf } = await import('../../../lib/core/chat/context-visibility/cap-confirm-gate');
    const { readContextUsageState, currentUsageBudgetOf } = await import('../../../lib/core/chat/context-visibility/use-context-usage');
    const { separatorHistoryOf } = await import('../../../lib/core/chat/context-compaction/use-compaction-separator');
    const { displayRhoHiOf } = await import('../../../lib/core/chat/context-pipeline/chat-context');
    const manifest = loadManifest();
    const capInputOf = (plan: ReturnType<typeof data.contextShotPlan>) =>
      capPresentationInputOf({ conversation: plan.conversation, preferences: plan.preferences, provider: plan.provider, model: plan.model });

    // Confirm dialog: the production send gate decides from the manifest confirm input + metadata and suspends.
    const kinds: Record<string, string | null> = {};
    for (const page of ['contextConfirmOverCap', 'contextConfirmPriceLine'] as const) {
      const plan = data.contextShotPlan(page, manifest);
      expect(plan.open).toBe('confirm');
      const { state, store } = memoryStore();
      state.contextCapConfirmations = {};
      state.setContextCapConfirmation = (key: string, request: unknown) => {
        state.contextCapConfirmations = { ...(state.contextCapConfirmations as object), [key]: request };
      };
      await data.applyContextShotPlan(plan, store);
      const abort = new AbortController();
      const raised = data.raiseContextShotConfirm(plan, store, abort.signal);
      kinds[page] = pendingCapConfirmationOf(state as never, plan.conversationId)?.decision.kind ?? null;
      abort.abort();
      await raised;
    }
    expect(kinds).toEqual({ contextConfirmOverCap: 'overCap', contextConfirmPriceLine: 'priceLine' });

    // Picker page: tick positions from production capPickerOf.
    const slider = (['contextCapPicker', 'contextCapPickerLarge'] as const).map((page) => {
      const plan = data.contextShotPlan(page, manifest);
      expect(plan.open).toBe('picker');
      return capPickerOf(capInputOf(plan)!).sliderIndex;
    });
    expect(slider).toEqual([3, 3]);
    // Custom picker page: conversation cap 128K, production capPickerOf selects "Custom" (slider and input visible).
    const custom = data.contextShotPlan('contextCapPickerCustom', manifest);
    expect(custom.open).toBe('picker');
    expect(custom.conversation?.contextCap).toBe(128000);
    expect(capPickerOf(capInputOf(custom)!).selected).toBe('custom');

    // Panel with unknown window: no window, so usage shows no percentage.
    const unknown = data.contextShotPlan('contextPanelUnknown', manifest);
    expect(unknown.open).toBe('panel');
    expect(capInputOf(unknown)?.W).toBeNull();
    await data.applyContextShotPlan(unknown, memoryStore().store);
    const conversation = unknown.conversation!;
    const usage = await readContextUsageState(
      conversation.id,
      separatorHistoryOf(conversation.messages),
      await displayRhoHiOf(unknown.provider!, unknown.model!.id),
      currentUsageBudgetOf(unknown.provider!, unknown.model!.id, conversation.id, conversation.contextCap ?? 'auto'),
    );
    expect(usage.summary?.percent ?? null).toBeNull();

    expect(data.contextShotPlan('contextSettings', manifest).target).toBe('settings');
    expect(data.contextShotPlan('contextConversationSettings', manifest).open).toBe('conversationSettings');
  });

  it('shotsManifestLedgerBudgetsMatchProduction', async () => {
    const data = await import('./context-shots-data');
    const { currentUsageBudgetOf } = await import('../../../lib/core/chat/context-visibility/use-context-usage');
    const { resolveContextDefaultCap } = await import('../../../lib/core/context-cap-preferences');
    const manifest = loadManifest();
    const seen: Record<string, number | null> = {};
    const mismatched: Record<string, { production: number | null; fixture: number | null }> = {};
    for (const page of manifest.pages as Array<{ name: string; manifest?: string }>) {
      if (page.manifest === undefined) continue;
      const plan = data.contextShotPlan(page.name as never, manifest);
      const conversation = plan.conversation!;
      const cap = conversation.contextCap ?? resolveContextDefaultCap(plan.preferences);
      const B = currentUsageBudgetOf(plan.provider!, plan.model!.id, conversation.id, cap) ?? null;
      seen[page.name] = B;
      if (B !== manifest.manifests[page.manifest].B) mismatched[page.name] = { production: B, fixture: manifest.manifests[page.manifest].B };
    }
    expect(mismatched).toEqual({});
    expect(seen.contextPanelPriceLine).toBe(900000);
  });

  it('shotsManifestMessageTimesFromFixture', async () => {
    const data = await import('./context-shots-data');
    const manifest = loadManifest();
    const plan = data.contextShotPlan('contextMemorySuggestion', manifest);
    const id = data.contextShotMessageId;
    const times = Object.fromEntries(plan.conversation!.messages.map((m) => [m.id, m.createdAt]));
    expect(times[id('u1')]).toBe(manifest.conversation.messages[0].createdAt);
    expect(times[id('u7')]).toBe('2026-10-12T09:40:00Z');
    expect(times[id('a7')]).toBe('2026-10-12T09:40:30.000Z');
    const footer = data.contextShotPlan('contextIncompleteFooter', manifest).conversation!.messages;
    expect(footer.find((m) => m.id === id('a6'))?.stopReason).toBe('length');
    const rows = await data.contextShotCheckpointRows(data.contextShotPlan('contextCompactHint', manifest));
    expect(new Set(rows.map((row) => row.createdAt))).toEqual(new Set([Date.parse(manifest.checkpoints.summary.createdAt)]));
    expect(rows.map((row) => `${row.coversFrom}..${row.coversTo}`)).toEqual(
      ['a4', 'a3', 'a2'].map((to) => `${id('u1')}..${id(to)}`),
    );
    // The checkpoint is built from production B + the default rho-Hi (the fence has no calibration).
    const hint = data.contextShotPlan('contextCompactHint', manifest);
    const { displayRhoHiOf } = await import('../../../lib/core/chat/context-pipeline/chat-context');
    const { RhoCalibration } = await import('@oriveo/core/context/calibration');
    expect(await displayRhoHiOf(hint.provider!, hint.model!.id)).toBe(RhoCalibration.initial().rhoHi);
  });

  it('shotsMessageIdsAreStableUuids', async () => {
    const data = await import('./context-shots-data');
    const { CONTEXT_SHOT_PAGES } = await import('./context-shots-pages');
    const manifest = loadManifest();
    // Same formula as Android / iOS: the manifest id's UTF-8 bytes in hex, left-padded with 0 to 12 digits.
    expect(data.contextShotMessageId('u1')).toBe('c0de0000-0000-4000-8000-000000007531');
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/;
    const seen = new Map<string, string>();
    for (const page of CONTEXT_SHOT_PAGES) {
      const plan = data.contextShotPlan(page, manifest);
      for (const message of plan.conversation?.messages ?? []) {
        expect(message.id, page).toHaveLength(36);
        expect(message.id, page).toMatch(uuid);
      }
      for (const fixture of manifest.conversation.messages as Array<{ id: string }>) {
        const mapped = plan.conversation?.messages.find((m) => m.createdAt === (fixture as { createdAt?: string }).createdAt)?.id;
        if (mapped === undefined) continue;
        expect(seen.get(fixture.id) ?? mapped, `${page} ${fixture.id}`).toBe(mapped);
        seen.set(fixture.id, mapped);
      }
    }
    expect(seen.size).toBe(manifest.conversation.messages.length);
    expect(new Set(seen.values()).size).toBe(seen.size);
  });

  it('shotsDividerSummaryTokensFromProductionSeparator', async () => {
    const data = await import('./context-shots-data');
    const { compactionSeparatorOf } = await import('../../../lib/core/chat/context-compaction/context-compaction-presentation');
    const { displayRhoHiOf } = await import('../../../lib/core/chat/context-pipeline/chat-context');
    const plan = data.contextShotPlan('contextDividerSummary', loadManifest());
    const [row] = await data.contextShotCheckpointRows(plan);
    const rhoHi = await displayRhoHiOf(plan.provider!, plan.model!.id);
    const separator = compactionSeparatorOf(row ?? null, plan.conversation!.messages, rhoHi);
    // Same as iOS: the checkpoint original text carries the UUID id of the retained message.
    expect({ before: separator?.before, after: separator?.after }).toEqual({ before: 259, after: 599 });
  });

  it('shotsManifestUnreadableRefuses', async () => {
    const { default: ContextShotsPage } = await import('./[page]/page');
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const open = () => ContextShotsPage({ params: Promise.resolve({ page: 'contextRingNormal' }) });
    const withoutPages = loadManifest();
    delete withoutPages.pages;
    const withoutPage = loadManifest();
    withoutPage.pages = withoutPage.pages.filter((page: { name: string }) => page.name !== 'contextRingNormal');

    for (const text of ['{ not json', JSON.stringify(withoutPages), JSON.stringify(withoutPage)]) {
      errors.mockClear();
      mocks.manifestText = text;
      await expect(open()).rejects.toThrow('NEXT_HTTP_ERROR_FALLBACK;404');
      expect(errors.mock.calls.some((call) => String(call[0]).includes('shots manifest'))).toBe(true);
    }
    mocks.manifestText = null;
    errors.mockRestore();
  }, 30_000);
});

describe('server entry does not pull in client hooks', () => {
  // Under next dev, a Server Component pulling in use-context-usage (useEffect) makes the whole page return 500; the unit-test environment does not distinguish server from client, so only the import graph can be locked.
  it('page.tsx imports only the manifest module, and the manifest module has only type imports', () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const page = readFileSync(join(here, '[page]', 'page.tsx'), 'utf8');
    expect(page).not.toMatch(/context-shots-data/);
    const manifest = readFileSync(join(here, 'context-shots-manifest.ts'), 'utf8');
    const valueImports = manifest.split('\n').filter((line) => /^import\s/.test(line) && !/^import type\s/.test(line));
    expect(valueImports).toEqual([]);
  });
});
