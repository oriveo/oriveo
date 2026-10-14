// @vitest-environment jsdom
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { cleanup, render } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ChatMessage, Provider } from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import * as relayAvatar from './relay-avatar';
import {
  RELAY_AVATAR_BRANDS,
  RELAY_AVATAR_BRAND_LOGO_KIND,
  RELAY_AVATAR_EXCLUDE_KEYWORDS,
  relayAvatarMarker,
  relayIconSource,
  resolveRelayAvatar,
  resolveRelayConnectionAvatar,
  type RelayAvatar,
} from './relay-avatar';
import { OFFICIAL_PROVIDER_LOGOS } from './provider-logo-assets';
import { ProviderIcon } from './ProviderIcon';
import { NoteSourceBadge } from './notes/NoteSourceBadge';
import { ModelTrigger } from './chat/ModelTrigger';
import { ProviderSectionRow } from './chat/ModelSwitcher/ProviderSectionRow';
import { ProviderListCard } from './providers/ProviderListCard';
import { MessageBubble } from './chat/MessageBubble';
import { ManualEntryView } from './chat/ModelSwitcher/ManualEntryView';
import { RelayDetailBoard } from '../app/providers/[providerId]/components/RelayDetailBoard';
import { relayDetailBoard } from '../app/providers/[providerId]/relay-detail-board';

/**
 * Relay avatar: the rules and cases of fixture relay-avatar.v1.json share the name
 * RD3-AVATAR-<caseId> on all platforms (base layer); BOARD-AVATAR-01 asserts that all five places use the same resolver for the same relay connection and get the same result.
 * With the default avatar icon layer (relay-avatar-icon.v1.json), a relay that has a connection id no longer falls back to an initial / generic:
 * all five places go through resolveRelayConnectionAvatar (on-device choice and default icon on top of the base layer), so the assertions below expect icons.
 */

vi.mock('./relay-avatar', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./relay-avatar')>();
  return {
    ...actual,
    resolveRelayAvatar: vi.fn(actual.resolveRelayAvatar),
    resolveRelayConnectionAvatar: vi.fn(actual.resolveRelayConnectionAvatar),
  };
});

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(), back: vi.fn() }),
}));

const storeState = {
  streamingTexts: {} as Record<string, string>,
  streamingReasoningTexts: {} as Record<string, string>,
  streamingReasoningActive: {} as Record<string, boolean>,
  streamingMessageIds: {} as Record<string, string>,
  streamingConversationIds: [] as string[],
  account: null,
  preferences: {},
  setPreferences: vi.fn(),
  providers: [],
  notes: [],
  conversations: [] as unknown[],
  folders: [],
  catalogSkills: [],
  userSkills: [],
};

vi.mock('../providers/StoreProvider', () => ({
  useAppStore: (selector: (s: unknown) => unknown) => selector(storeState),
  getVanillaStore: () => ({ getState: () => storeState, setState: vi.fn() }),
}));

// The message bubble looks only at the avatar: the body / actions / attachments subtrees are given empty shells.
vi.mock('./chat/MarkdownRenderer', () => ({ MarkdownRenderer: () => null }));
vi.mock('./chat/MessageActions', () => ({ MessageActions: () => null }));
vi.mock('./chat/TypingIndicator', () => ({ TypingIndicator: () => null }));
vi.mock('./chat/MessageRecoveryCard', () => ({ MessageRecoveryCard: () => null }));
vi.mock('./chat/MessageMeta', () => ({ MessageMeta: () => null }));
vi.mock('./chat/CitationsBlock', () => ({ CitationsBlock: () => null }));
vi.mock('./chat/ResearchProgressBlock', () => ({ ResearchProgressBlock: () => null }));
vi.mock('./chat/CrosscheckSheet', () => ({ CrosscheckSheet: () => null }));
vi.mock('./chat/SavedNoteRefs', () => ({ SavedNoteRefs: () => null }));
vi.mock('./chat/QuoteContextChip', () => ({ QuoteContextChip: () => null }));
vi.mock('./chat/MessageAttachments', () => ({
  UserImageAttachments: () => null,
  UserFileChips: () => null,
  GeneratedImages: () => null,
}));
vi.mock('./ContextMenu', () => ({
  ContextMenu: () => null,
  useContextMenu: () => ({ menu: null, handleContextMenu: vi.fn(), closeMenu: vi.fn() }),
}));
vi.mock('./common/UserAvatar', () => ({ UserAvatar: () => null }));
vi.mock('./Toast', () => ({ showToast: vi.fn() }));
vi.mock('./notes/note-toast', () => ({ showSavedNoteToast: vi.fn() }));
vi.mock('../lib/core/library/feature-flag', () => ({ isLibraryFeatureEnabled: () => false }));

afterEach(() => {
  cleanup();
});

interface AvatarFixture {
  brands: Array<{ id: string; keywords: string[] }>;
  excludeKeywords: string[];
  cases: Array<{
    id: string;
    name: string;
    url: string;
    models?: string[];
    expected: RelayAvatar;
  }>;
}

function readFixture<T>(...segments: string[]): T {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, ...segments);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    dir = path.dirname(dir);
  }
  throw new Error(`${segments.join('/')} not found`);
}

const fixture = readFixture<AvatarFixture>('shared', 'test-fixtures', 'relay', 'relay-avatar.v1.json');

describe('RD3-AVATAR fixture relay-avatar.v1.json', () => {
  it.each(fixture.cases.map((item) => [item.id, item] as const))('RD3-AVATAR-%s', (_id, item) => {
    // The model id never takes part: it is not even an input of the resolver.
    expect(resolveRelayAvatar({ name: item.name, baseURL: item.url })).toEqual(item.expected);
  });

  it('RD3-AVATAR the built-in brand table and exclusion words match the fixture verbatim, and every brand has an existing official asset', () => {
    expect(RELAY_AVATAR_BRANDS).toEqual(fixture.brands);
    expect(RELAY_AVATAR_EXCLUDE_KEYWORDS).toEqual(fixture.excludeKeywords);
    for (const brand of fixture.brands) {
      const kind = RELAY_AVATAR_BRAND_LOGO_KIND[brand.id as keyof typeof RELAY_AVATAR_BRAND_LOGO_KIND];
      expect(OFFICIAL_PROVIDER_LOGOS[kind]).toBeTruthy();
    }
  });
});

const KEY = 'sk-relay-secret-0123456789';

function relayProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: KEY,
    apiKeyPreview: formatApiKeyPreview(KEY),
    baseURLText: 'https://api.myrelay.dev',
    // Both protocol type and model id point to Anthropic: the old inference would draw Anthropic, the new rule never looks at them.
    relayKind: 'anthropic_compatible',
    relayRequested: { transport: 'anthropic_messages', authMode: 'bearer' },
    ...overrides,
  };
}

function markersIn(container: HTMLElement): string[] {
  return [...container.querySelectorAll('[data-relay-avatar]')].map((element) => element.getAttribute('data-relay-avatar')!);
}

describe('BOARD-AVATAR-01 the same function, the same result in five places', () => {
  it('BOARD-AVATAR-01 the model picker group header, chat top bar, message header, detail header and provider list get the same avatar for the same relay', () => {
    const provider = relayProvider({
      models: [{
        id: 'claude-sonnet-4-5',
        name: 'claude-sonnet-4-5',
        capabilities: ['text'],
        reasoningModeAvailable: false,
        isAvailable: true,
        isDefault: false,
        priceTier: '',
      }],
    });
    const resolveSpy = vi.mocked(relayAvatar.resolveRelayConnectionAvatar);
    resolveSpy.mockClear();
    const expected = relayAvatarMarker(relayAvatar.resolveRelayConnectionAvatar({
      providerId: 'relay-1',
      name: 'myrelay.dev',
      baseURL: 'https://api.myrelay.dev',
    }));
    // Fixture default_relay_1: relay-1 -> relay-bell.
    expect(expected).toBe('icon:relay-bell');
    resolveSpy.mockClear();

    const surfaces: Array<[string, HTMLElement]> = [];
    surfaces.push(['modelSwitcher', render(
      <ProviderSectionRow
        section={{ provider, providerName: 'myrelay.dev', models: [], canAddModels: false }}
        selectedProviderId={undefined}
        selectedModelId={undefined}
        normalizedQuery=""
        hasFilters={false}
        expandedProviderIds={new Set()}
        setExpandedProviderIds={vi.fn()}
        openAddView={vi.fn()}
        onSelect={vi.fn()}
        capabilityProjector={vi.fn() as never}
      />,
    ).container]);
    surfaces.push(['topBar', render(
      <ModelTrigger modelName="claude-sonnet-4-5" providerKind="relay" relayProvider={provider} />,
    ).container]);
    const message = {
      id: 'm1',
      role: 'assistant',
      text: 'hi',
      timestamp: '2026-10-12T00:00:00.000Z',
      providerKind: 'relay',
      modelID: 'claude-sonnet-4-5',
    } as unknown as ChatMessage;
    surfaces.push(['messageHeader', render(
      <MessageBubble message={message} provider={provider} />,
    ).container]);
    surfaces.push(['detailHeader', render(
      <RelayDetailBoard
        board={relayDetailBoard(provider)}
        nameSlot={<span>myrelay.dev</span>}
        apiKeyRowLabel="editKey"
        onAction={vi.fn()}
        onDetectAgain={vi.fn()}
        isDetecting={false}
        onDelete={vi.fn()}
        disabled={false}
      />,
    ).container]);
    surfaces.push(['providerList', render(
      <ProviderListCard provider={provider} monthlyCost={0} onClick={vi.fn()} />,
    ).container]);

    for (const [surface, container] of surfaces) {
      expect([surface, markersIn(container)]).toEqual([surface, [expected]]);
    }
    // All five places call the same resolver, whose only inputs are the connection id, name, address and on-device choice (none here).
    expect(resolveSpy).toHaveBeenCalled();
    for (const call of resolveSpy.mock.calls) {
      expect(call[0]).toEqual({ providerId: 'relay-1', name: 'myrelay.dev', baseURL: 'https://api.myrelay.dev' });
    }
  });

  it('BOARD-AVATAR-01 name source = the name the user gave: an unnamed relay passes an empty name and its initial comes from the host (empty_name_uses_host is reachable on a real connection)', () => {
    const provider = relayProvider({ customName: undefined });
    const resolveSpy = vi.mocked(relayAvatar.resolveRelayConnectionAvatar);
    resolveSpy.mockClear();
    // No on-device choice -> default icon; picking the letter still reaches the host initial through the initial rule.
    expect(relayDetailBoard(provider).avatar).toEqual({ kind: 'icon', icon: 'relay-bell' });
    expect(resolveRelayConnectionAvatar({ providerId: provider.id, name: '', baseURL: provider.baseURLText, choice: 'letter' }))
      .toEqual({ kind: 'initial', text: 'M' });
    resolveSpy.mockClear();
    const { container } = render(<ProviderListCard provider={provider} monthlyCost={0} onClick={vi.fn()} />);
    expect(markersIn(container)).toEqual(['icon:relay-bell']);
    const trigger = render(<ModelTrigger modelName="m" providerKind="relay" relayProvider={provider} />);
    expect(markersIn(trigger.container)).toEqual(['icon:relay-bell']);
    expect(resolveSpy).toHaveBeenCalled();
    for (const call of resolveSpy.mock.calls) {
      expect(call[0]).toEqual({ providerId: 'relay-1', name: '', baseURL: 'https://api.myrelay.dev' });
    }
  });

  it('BOARD-AVATAR-01 local connections do not use this function: still the original icon path', () => {
    const resolveSpy = vi.mocked(relayAvatar.resolveRelayAvatar);
    resolveSpy.mockClear();
    const { container } = render(
      <ProviderIcon kind="relay" size={22} bare providerName="Mac mini" baseURLText="http://192.168.1.20:8080" localEngine />,
    );
    expect(markersIn(container)).toEqual([]);
    expect(resolveSpy).not.toHaveBeenCalled();
  });
});

/** Connection avatar decision: cases 01 to 04 share names across platforms. */
describe('RL2-AVATAR-COVER connection avatar decision', () => {
  function markersFor(provider: Provider | null, kind: Provider['kind'] = 'relay'): string[] {
    const { container } = render(<ProviderIcon kind={kind} size={22} bare {...relayIconSource(provider)} />);
    return markersIn(container);
  }

  it('RL2-AVATAR-COVER-01 relay name contains an aggregator brand -> brand image', () => {
    expect(markersFor(relayProvider({ customName: 'OpenRouter \u5907\u7528', baseURLText: 'https://proxy.example.com/v1' }))).toEqual([
      'brand:openrouter',
    ]);
  });

  it('RL2-AVATAR-COVER-02 relay with no brand -> default icon by connection id, not drawn by protocol type', () => {
    expect(markersFor(relayProvider({ customName: 'Moon Relay', baseURLText: 'https://api.myrelay.dev/v1' }))).toEqual([
      'icon:relay-bell',
    ]);
  });

  it('RL2-AVATAR-COVER-03 connection no longer exists -> generic; connection exists but name and address are both empty -> default icon', () => {
    expect(markersFor(null)).toEqual(['generic']);
    expect(markersFor(relayProvider({ customName: '', baseURLText: '' }))).toEqual(['icon:relay-bell']);
  });

  it('RL2-AVATAR-COVER-06 note source does not record the connection: relay sources are always generic and are not inferred from the name', () => {
    const { container } = render(<NoteSourceBadge providerKind="relay" providerName="OpenRouter" modelName="gpt-4o" />);
    expect(markersIn(container)).toEqual(['generic']);
    cleanup();
    const official = render(<NoteSourceBadge providerKind="anthropic" providerName="Anthropic" />);
    expect(markersIn(official.container)).toEqual([]);
  });

  it('RL2-AVATAR-COVER-04 local engines and official providers still use the original icon path', () => {
    const local = relayProvider({
      customName: 'Moon Relay',
      baseURLText: 'http://localhost:11434/v1',
      relayRequested: { engineProfile: 'ollama' } as Provider['relayRequested'],
    });
    expect(markersFor(local)).toEqual([]);
    expect(markersFor({ ...relayProvider(), kind: 'anthropic' } as Provider, 'anthropic')).toEqual([]);
  });
});

/**
 * Avatar coverage gate: every <ProviderIcon .../> in production tsx must satisfy one of the following -
 * carries `{...relayIconSource(...)}`; an explicit `localEngine` (note sources store only kind + a name snapshot and cannot get the connection record);
 * or `kind="<non-relay literal>"`. Call sites that draw only an official kind are registered by file count; any unregistered extra call is red.
 */
const OFFICIAL_ONLY_ICON_SITES: Record<string, number> = {
  'app/providers/new/ProviderCard.tsx': 1,
  'app/providers/new/ProviderSetup.tsx': 1,
  // The providerKind !== 'relay' branch; the relay branch has another site carrying relayIconSource.
  'components/chat/ModelTrigger.tsx': 1,
};

function productionTsxFiles(root: string, dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(path.join(root, dir))) {
    const rel = path.posix.join(dir, name);
    const abs = path.join(root, rel);
    if (statSync(abs).isDirectory()) {
      if (name === 'node_modules' || name === '__tests__') continue;
      out.push(...productionTsxFiles(root, rel));
    } else if (name.endsWith('.tsx') && !/\.test\.tsx$/.test(name)) {
      out.push(rel);
    }
  }
  return out;
}

function providerIconElements(source: string): string[] {
  const elements: string[] = [];
  let index = source.indexOf('<ProviderIcon');
  while (index >= 0) {
    const end = source.indexOf('/>', index);
    elements.push(source.slice(index, end + 2));
    index = source.indexOf('<ProviderIcon', end);
  }
  return elements;
}

describe('RL2-AVATAR-COVER-05 relay connection avatars do not bypass relayIconSource', () => {
  it('RL2-AVATAR-COVER-05 every ProviderIcon in production tsx carries relayIconSource / an explicit localEngine / a non-relay literal kind', () => {
    const root = process.cwd();
    const bypass: string[] = [];
    const officialCounts: Record<string, number> = {};
    for (const file of [...productionTsxFiles(root, 'app'), ...productionTsxFiles(root, 'components')]) {
      if (file === 'components/ProviderIcon.tsx') continue;
      for (const element of providerIconElements(readFileSync(path.join(root, file), 'utf8'))) {
        const ok = /\{\.\.\.relayIconSource\(/.test(element)
          || /\blocalEngine\b/.test(element)
          || /\bkind="(?!relay")[^"]+"/.test(element);
        if (ok) continue;
        if (file in OFFICIAL_ONLY_ICON_SITES) {
          officialCounts[file] = (officialCounts[file] ?? 0) + 1;
          continue;
        }
        bypass.push(`${file}: ${element.replace(/\s+/g, ' ')}`);
      }
    }
    expect(bypass).toEqual([]);
    expect(officialCounts).toEqual(OFFICIAL_ONLY_ICON_SITES);
  });

  it('RL2-AVATAR-COVER-05 manual add model page header: a relay connection gets the unified avatar, a local connection does not go through the resolver', () => {
    const provider = relayProvider();
    const data = {
      manualInputRef: { current: null },
      setView: vi.fn(),
      manualModelId: '',
      setManualModelId: vi.fn(),
      existingManualModel: undefined,
      handleManualSubmit: vi.fn(),
    } as never;
    const relay = render(<ManualEntryView data={data} activeProvider={provider} onClose={vi.fn()} />);
    expect(markersIn(relay.container)).toEqual([
      relayAvatarMarker(resolveRelayConnectionAvatar({ providerId: 'relay-1', name: 'myrelay.dev', baseURL: 'https://api.myrelay.dev' })),
    ]);
    relay.unmount();

    const local = relayProvider({
      relayRequested: { transport: 'openai_chat_completions', authMode: 'none', securityMode: 'local_http', engineProfile: 'ollama' },
    });
    const view = render(<ManualEntryView data={data} activeProvider={local} onClose={vi.fn()} />);
    expect(markersIn(view.container)).toEqual([]);
  });
});
