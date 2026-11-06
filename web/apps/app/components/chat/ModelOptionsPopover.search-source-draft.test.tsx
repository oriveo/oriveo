import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';

/**
 * A new conversation passes its draft id as `conversationId` (generation parameters fall back to it),
 * but the external search source must land in the in-memory draft table so the first send adopts it.
 * Only a real conversation id may write the persisted per-conversation source.
 */
vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string, values?: Record<string, unknown>) => (
    values ? `${namespace}.${key}:${Object.values(values).join(',')}` : `${namespace}.${key}`
  ),
  useLocale: () => 'en',
}));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: <T,>(selector: (state: { providers: never[] }) => T) => selector({ providers: [] }),
  tryGetVanillaStore: () => null,
}));
vi.mock('../../lib/core/telemetry', () => ({ trackEvent: vi.fn() }));

const shotData = vi.hoisted(() => ({ current: null as unknown }));
const shotToolCall = vi.hoisted(() => ({ current: undefined as unknown }));
const persisted = vi.hoisted(() => ({ writes: [] as Array<{ conversationId: string; value: unknown }> }));

vi.mock('../../lib/search/search-service-store', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/search/search-service-store')>(),
  getConversationSearchSource: async () => null,
  setConversationSearchSource: async (_uid: string, conversationId: string, value: unknown) => {
    persisted.writes.push({ conversationId, value });
  },
}));
vi.mock('../../lib/search/external-search-context', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/search/external-search-context')>(),
  loadExternalSearchData: async () => shotData.current,
}));
vi.mock('../../lib/core/chat/capability-evidence', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/core/chat/capability-evidence')>(),
  resolveModelCapabilityEvidence: () => ({ support: shotToolCall.current }),
}));
vi.mock('../../lib/core/chat/composer-web-preference', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/core/chat/composer-web-preference')>(),
  composerWebPreferenceWritable: () => true,
}));

function loadManifest() {
  for (let dir = resolve(import.meta.dirname); ; dir = dirname(dir)) {
    try {
      return JSON.parse(readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'webSearch.v1.json'), 'utf8'));
    } catch (error) {
      if (dirname(dir) === dir) throw error;
    }
  }
}

const DRAFT_ID = 'draft-session-search-1';
const CONVERSATION_ID = 'C0000000-0000-0000-0000-000000000001';

describe('ModelOptionsPopover external search source scope', () => {
  beforeAll(async () => {
    await import('../../app/dev/webSearch-shots/webSearch-shots-data');
    await import('./ModelOptionsPopover');
  }, 60_000);
  afterEach(() => {
    cleanup();
    persisted.writes.length = 0;
  });

  async function openArmable(props: Record<string, unknown>) {
    const data = await import('../../app/dev/webSearch-shots/webSearch-shots-data');
    const { ModelOptionsPopover } = await import('./ModelOptionsPopover');
    const shot = data.webSearchShotPlan('webSearchOptNotArmed' as never, loadManifest()).modelOptions!;
    shotData.current = shot.externalSearchSource.data;
    shotToolCall.current = shot.externalSearchSource.toolCall;
    render(
      <ModelOptionsPopover
        provider={shot.provider} model={shot.model} webControl={shot.webControl} webPreference={shot.webPreference}
        onWebPreferenceChange={() => {}} transportIdentity="shots" onOpenSearchServiceSheet={() => {}} onClose={() => {}}
        {...props}
      />,
    );
    const toggle = await screen.findByText('undefined.webSearch.card.offUseService:DeepSeek');
    expect(toggle).toBeTruthy();
    fireEvent.click(screen.getByRole('switch', { name: /capabilityControlWebSearch/ }));
    await screen.findByText('undefined.webSearch.card.useService:DeepSeek');
  }

  it('new_conversation_popover_writes_draft_source', async () => {
    const { readDraftSearchSource } = await import('../../lib/search/external-search-context');
    // Generation parameters still key on the draft id; the search source must not.
    await openArmable({ conversationId: DRAFT_ID, searchDraftSessionId: DRAFT_ID });

    await waitFor(() => expect(readDraftSearchSource(DRAFT_ID)).not.toBeNull());
    expect(persisted.writes.map((write) => write.conversationId)).not.toContain(DRAFT_ID);
  });

  it('existing_conversation_popover_writes_conversation_source', async () => {
    const { readDraftSearchSource } = await import('../../lib/search/external-search-context');
    await openArmable({ conversationId: CONVERSATION_ID, searchConversationId: CONVERSATION_ID, searchDraftSessionId: 'draft-unused' });

    await waitFor(() => expect(persisted.writes.map((write) => write.conversationId)).toContain(CONVERSATION_ID));
    expect(persisted.writes.find((write) => write.conversationId === CONVERSATION_ID)?.value).not.toBeNull();
    expect(readDraftSearchSource('draft-unused')).toBeNull();
  });
});
