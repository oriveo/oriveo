import type { ReactNode } from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ChatView } from './ChatView';
import { showToast } from '../Toast';
import { capabilityRuntimeIdentity, resolveCapabilityPreferences } from '../../lib/core/chat/capability-preference-settings';

const routerPush = vi.fn();
const routerReplace = vi.fn();
let mockSearchParams = new URLSearchParams();
let mockLocale = 'en';

const { mockCreateProviderSelectionSnapshot } = vi.hoisted(() => ({
  mockCreateProviderSelectionSnapshot: vi.fn(),
}));

const { mockGetConversationById } = vi.hoisted(() => ({
  mockGetConversationById: vi.fn(async () => undefined),
}));

const { mockUpdateConversation, mockAddConversation } = vi.hoisted(() => ({
  mockUpdateConversation: vi.fn(),
  mockAddConversation: vi.fn(),
}));

const { mockPinNoteToConversation, mockUnpinNoteFromConversation } = vi.hoisted(() => ({
  mockPinNoteToConversation: vi.fn(),
  mockUnpinNoteFromConversation: vi.fn(),
}));

const { mockUpdateNoteBody } = vi.hoisted(() => ({
  mockUpdateNoteBody: vi.fn(),
}));

const {
  mockGetCachedManagedProvider,
  mockRefreshManagedProvider,
  mockSubscribeManagedProvider,
  mockAcknowledgeManagedPrivacy,
  mockFetchManagedBalance,
} = vi.hoisted(() => ({
  mockGetCachedManagedProvider: vi.fn(),
  mockRefreshManagedProvider: vi.fn(),
  mockSubscribeManagedProvider: vi.fn(),
  mockAcknowledgeManagedPrivacy: vi.fn(),
  mockFetchManagedBalance: vi.fn(),
}));

const { mockUseStreamChat } = vi.hoisted(() => ({
  mockUseStreamChat: vi.fn(),
}));

const libraryFeatureFlagMock = vi.hoisted(() => ({ enabled: true }));

const { mockHasCatalogModel, mockRefreshMetadata, mockResolveCatalogModel } = vi.hoisted(() => ({
  mockHasCatalogModel: vi.fn(),
  mockRefreshMetadata: vi.fn(),
  mockResolveCatalogModel: vi.fn(),
}));
const mockCapabilityRuntime = vi.hoisted(() => ({ current: undefined as undefined | { revision: string } }));

vi.mock('../../lib/core/library/feature-flag', () => ({
  isLibraryFeatureEnabled: () => libraryFeatureFlagMock.enabled,
  // This mock stands in for the build-time kill switch being off. That is a local, certain
  // fact, so routing settles straight to none without the negative-conclusion confirmation
  // gate (otherwise the entry point flashes in and then disappears).
  isLibraryBuildEnabled: () => libraryFeatureFlagMock.enabled,
}));

const { mockFetchUsageSummary, mockFetchUsageBudget } = vi.hoisted(() => ({
  mockFetchUsageSummary: vi.fn(),
  mockFetchUsageBudget: vi.fn(),
}));

const { mockGetSyncAdapter, mockLoadSyncCore } = vi.hoisted(() => ({
  mockGetSyncAdapter: vi.fn(),
  mockLoadSyncCore: vi.fn(),
}));

const {
  mockGetSkillById,
  mockStartConversationWithSkill,
} = vi.hoisted(() => ({
  mockGetSkillById: vi.fn(),
  mockStartConversationWithSkill: vi.fn(),
}));

type MockState = {
  providers: any[];
  account: { email: string } | null;
  activeConversationId: string | null;
  streamingTexts: Record<string, string>;
  streamingMessageIds: Record<string, string>;
  streamingConversationIds: string[];
  lastUsedModelRef: { providerID: string; modelID: string } | null;
  syncState: string;
  setLastUsedModelRef: ReturnType<typeof vi.fn>;
  sidebarOpen: boolean;
  setSidebarOpen: ReturnType<typeof vi.fn>;
  preferences: { memoryText: string; sendShortcut: 'enter' };
  conversations: any[];
  notes: any[];
  catalogSkills: any[];
  userSkills: any[];
  libraryConnections: any[];
  libraryQuota: any;
  libraryLoadState: 'idle' | 'loading' | 'ready' | 'error';
  libraryErrorCode: string | null;
  libraryResearchEnabled: boolean;
  setLibraryResearchEnabled: ReturnType<typeof vi.fn>;
  setLibraryQuota: ReturnType<typeof vi.fn>;
  setLibraryResearchSteps: ReturnType<typeof vi.fn>;
  setLibraryConfirmation: ReturnType<typeof vi.fn>;
  clearStreamingForConversation: ReturnType<typeof vi.fn>;
};

let mockState: MockState;

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: routerPush,
    replace: routerReplace,
  }),
  useSearchParams: () => mockSearchParams,
}));

vi.mock('next-intl', () => ({
  useLocale: () => mockLocale,
  useTranslations: (namespace: string) => (key: string, values?: Record<string, string | number>) => {
    const messages: Record<string, string> = {
      'pages.chat.providerHasIssue': `${values?.name ?? 'Provider'} has an issue`,
      'pages.chat.fixNow': 'Fix Now',
      'pages.chat.useOtherModel': 'Use other model',
      'pages.chat.noProviderHint': 'Add a provider to start chatting.',
      'pages.chat.addProvider': 'Add Provider',
      'skills.needProvider': 'Need provider',
      'skills.providerRequiredTitle': 'Add provider to use this Skill',
      'skills.providerRequiredMessage': 'This Skill needs an available AI provider before it can start a conversation.',
      'skills.providerRequiredAction': 'Add Provider',
      'skills.promptCancel': 'Not now',
      'errors.keyExpired': 'Key expired',
    };

    return messages[`${namespace}.${key}`] ?? key;
  },
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick }: { children: ReactNode; onClick?: () => void }) => (
    <button type="button" onClick={onClick}>
      {children}
    </button>
  ),
  Dialog: ({ open, children }: { open: boolean; children: ReactNode }) => (
    open ? <div role="dialog">{children}</div> : null
  ),
}));

vi.mock('@oriveo/config', () => ({
  getProviderDisplayName: (_kind: string) => 'OpenAI',
}));

vi.mock('../../lib/core/providers/provider-selection-snapshot', () => ({
  createProviderSelectionSnapshot: mockCreateProviderSelectionSnapshot,
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
  getVanillaStore: () => ({
    getState: () => ({
      ...mockState,
      updateConversation: mockUpdateConversation,
      addConversation: mockAddConversation,
    }),
  }),
  tryGetVanillaStore: () => ({
    getState: () => ({
      ...mockState,
      updateConversation: mockUpdateConversation,
      addConversation: mockAddConversation,
    }),
  }),
}));

vi.mock('../../lib/infra/storage/idb', () => ({
  getConversationById: mockGetConversationById,
}));

vi.mock('../../lib/hooks/useNotifications', () => ({
  useNotifications: vi.fn(),
}));

vi.mock('../../lib/hooks/useMediaQuery', () => ({
  useMediaQuery: () => false,
}));

vi.mock('../../lib/hooks/useAttachmentDragDrop', () => ({
  useAttachmentDragDrop: () => ({
    dragActive: false,
    dragHandlers: {},
  }),
}));

vi.mock('../../lib/hooks/useStreamChat', () => ({
  useStreamChat: (...args: unknown[]) => mockUseStreamChat(...args),
}));

vi.mock('../../lib/core/sync-lazy', () => ({
  loadSyncCore: (...args: unknown[]) => mockLoadSyncCore(...args),
}));

vi.mock('../../lib/core/conversation-ops', () => ({
  pinNoteToConversation: (...args: unknown[]) => mockPinNoteToConversation(...args),
  unpinNoteFromConversation: (...args: unknown[]) => mockUnpinNoteFromConversation(...args),
  updateConversationModel: vi.fn(),
}));

vi.mock('../../lib/core/note-ops', () => ({
  updateNoteBody: (...args: unknown[]) => mockUpdateNoteBody(...args),
}));

vi.mock('../../lib/core/chat/operations', () => ({
  deleteMessage: vi.fn(),
}));

vi.mock('../../lib/core/providers/provider-sync', () => ({
  resyncProviderInStore: vi.fn(),
  shouldAutoRefreshProvider: () => false,
}));

vi.mock('../../lib/core/provider-model-ops', () => ({
  addManualProviderModels: () => [],
  enableProviderModel: vi.fn(),
  findModelInProvider: (provider: any, modelId: string) =>
    provider?.models?.find((model: { id: string }) => model.id === modelId),
}));

vi.mock('./TopBar', () => ({
  TopBar: ({
    modelName,
    providerKind,
    onModelClick,
  }: {
    modelName?: string;
    providerKind?: string;
    onModelClick?: () => void;
  }) => (
    <div
      data-testid="top-bar"
      data-model-name={modelName ?? ''}
      data-provider-kind={providerKind ?? ''}
    >
      <button type="button" onClick={onModelClick}>open model switcher</button>
    </div>
  ),
}));

vi.mock('./MessageList', () => ({
  MessageList: ({
    emptyState,
    replaceCurrentNoteId,
    savedNoteRefsByMessageId,
    onAskSelection,
  }: {
    emptyState?: ReactNode;
    replaceCurrentNoteId?: string | null;
    savedNoteRefsByMessageId?: Record<string, Array<{ id: string; title: string }>>;
    onAskSelection?: (quoteContext: any) => void;
  }) => (
    <div
      data-testid="message-list"
      data-replace-current-note-id={replaceCurrentNoteId ?? ''}
      data-saved-note-refs={JSON.stringify(savedNoteRefsByMessageId ?? {})}
    >
      {emptyState}
      <button type="button" onClick={() => onAskSelection?.({
        schemaVersion: 1,
        sourceMessageId: 'source-1',
        sourceRole: 'assistant',
        contentKind: 'prose',
        leadingText: 'before ',
        selectedText: 'first selection',
        trailingText: ' after',
        contextTruncated: false,
      })}>ask first selection</button>
      <button type="button" onClick={() => onAskSelection?.({
        schemaVersion: 1,
        sourceMessageId: 'source-2',
        sourceRole: 'user',
        contentKind: 'code',
        leadingText: 'const ',
        selectedText: 'secondSelection',
        trailingText: ' = true',
        contextTruncated: false,
      })}>ask second selection</button>
    </div>
  ),
}));

vi.mock('./InputComposer', () => ({
  InputComposer: ({
    disabled,
    presentation = 'docked',
    value,
    onChange,
    onSend,
    attachments = [],
    onAttachmentsChange,
    relatedNotes = [],
    onAttachRelatedNote,
    attachedNotes = [],
    onDetachNote,
    placeholderOverride,
    webControl,
    webPreference,
    webOutboundActive,
    webRuntimeRejected,
    onWebPreferenceChange,
    reasoningIntent,
    reasoningOutboundActive,
    reasoningRuntimeRejected,
    onReasoningIntentChange,
    libraryResearchEnabled,
    onLibraryResearchToggle,
    libraryContextDocuments = [],
    onAddLibraryContext,
    quoteContext,
    onRemoveQuote,
  }: {
    disabled?: boolean;
    presentation?: 'docked' | 'home';
    value?: string;
    onChange?: (value: string) => void;
    onSend?: () => void;
    attachments?: Array<{ id: string; kind: string; fileName: string; mimeType: string }>;
    onAttachmentsChange?: (attachments: Array<{ id: string; kind: string; fileName: string; mimeType: string }>) => void;
    relatedNotes?: Array<{ id: string; title: string; score: number; sourceLabel?: string }>;
    onAttachRelatedNote?: (noteId: string) => void;
    attachedNotes?: Array<{ id: string; title: string }>;
    onDetachNote?: (noteId: string) => void;
    placeholderOverride?: string;
    webControl?: { state: string };
    webPreference?: string;
    webOutboundActive?: boolean;
    webRuntimeRejected?: boolean;
    onWebPreferenceChange?: (next: 'off' | 'automatic' | 'force') => void;
    reasoningIntent?: string;
    reasoningOutboundActive?: boolean;
    reasoningRuntimeRejected?: boolean;
    onReasoningIntentChange?: (intent: string | undefined) => void;
    libraryResearchEnabled?: boolean;
    onLibraryResearchToggle?: (next: boolean) => void;
    libraryContextDocuments?: Array<{ docId: string; source: 'notion' | 'google'; title: string }>;
    onAddLibraryContext?: () => void;
    quoteContext?: { selectedText: string };
    onRemoveQuote?: () => void;
  }) => (
    <div
      data-testid="input-composer"
      data-disabled={disabled ? 'true' : 'false'}
      data-presentation={presentation}
      data-value={value ?? ''}
      data-web-control-state={webControl?.state ?? ''}
      data-web-preference={webPreference ?? ''}
      data-web-search-enabled={webPreference && webPreference !== 'off' ? 'true' : 'false'}
      data-web-outbound-active={webOutboundActive ? 'true' : 'false'}
      data-web-runtime-rejected={webRuntimeRejected ? 'true' : 'false'}
      data-reasoning-intent={reasoningIntent ?? ''}
      data-reasoning-outbound-active={reasoningOutboundActive ? 'true' : 'false'}
      data-reasoning-runtime-rejected={reasoningRuntimeRejected ? 'true' : 'false'}
      data-library-context-count={libraryContextDocuments.length}
      data-attachment-count={attachments.length}
      data-related-note-count={relatedNotes.length}
      data-attached-note-count={attachedNotes.length}
      data-attached-note-titles={attachedNotes.map((note) => note.title).join('|')}
      data-placeholder-override={placeholderOverride ?? ''}
      data-quote-selection={quoteContext?.selectedText ?? ''}
    >
      <button type="button" onClick={() => onChange?.('vector database context')}>type draft</button>
      <button type="button" onClick={() => onChange?.('@Notion summarize this')}>type source mention</button>
      <button
        type="button"
        onClick={() => onAttachmentsChange?.([{
          id: 'attachment-1',
          kind: 'file',
          fileName: 'context.md',
          mimeType: 'text/markdown',
        }])}
      >
        attach file
      </button>
      <button type="button" onClick={() => onSend?.()}>send draft</button>
      {quoteContext ? <button type="button" onClick={onRemoveQuote}>remove quote</button> : null}
      {onLibraryResearchToggle ? (
        <button type="button" onClick={() => onLibraryResearchToggle(!libraryResearchEnabled)}>toggle library research</button>
      ) : null}
      <button type="button" onClick={() => onWebPreferenceChange?.(webPreference === 'off' ? 'automatic' : 'off')}>toggle web search</button>
      <button type="button" onClick={() => onReasoningIntentChange?.('off')}>turn reasoning off</button>
      <button type="button" onClick={() => onReasoningIntentChange?.(undefined)}>pick supplier default</button>
      <button type="button" onClick={() => onReasoningIntentChange?.('deep')}>pick deep reasoning</button>
      {onAddLibraryContext ? (
        <button type="button" onClick={onAddLibraryContext}>add library context</button>
      ) : null}
      {relatedNotes.map((note) => (
        <button key={note.id} type="button" onClick={() => onAttachRelatedNote?.(note.id)}>
          attach {note.title}
        </button>
      ))}
      {attachedNotes.map((note) => (
        <button key={note.id} type="button" onClick={() => onDetachNote?.(note.id)}>
          detach {note.title}
        </button>
      ))}
    </div>
  ),
}));

vi.mock('./LibraryContextPicker', () => ({
  LibraryContextPicker: ({
    open,
    selected,
    onChange,
    onClose,
    researchAvailable,
    researchPending,
  }: {
    open: boolean;
    selected: Array<{ docId: string; source: 'notion' | 'google'; title: string }>;
    onChange: (documents: Array<{ docId: string; source: 'notion' | 'google'; title: string }>) => void;
    onClose: () => void;
    researchAvailable?: boolean;
    researchPending?: boolean;
  }) => (
    // The route verdict (available / confirming) must be assertable even with the panel
    // closed: it decides the entry-point copy, and "pending settled early as none" only
    // shows up here.
    <div
      data-testid="library-route-state"
      data-research-available={researchAvailable ? 'true' : 'false'}
      data-research-pending={researchPending ? 'true' : 'false'}
    >
      {open ? (
        <div role="dialog" aria-label="library context picker">
          <button type="button" onClick={() => onChange([...selected, { docId: 'doc-1', source: 'notion', title: 'Roadmap' }])}>
            select Roadmap
          </button>
          <button type="button" onClick={onClose}>finish context selection</button>
        </div>
      ) : null}
    </div>
  ),
}));

vi.mock('./LibraryConfirmationDialog', () => ({
  LibraryConfirmationDialog: () => <div data-testid="library-confirmation-dialog" />,
}));

vi.mock('./SkillsLanding', () => ({
  SkillsLanding: ({
    onSkillSelect,
    layout = 'default',
  }: {
    onSkillSelect: (skill: any) => void;
    layout?: 'default' | 'compact';
  }) => (
    <button
      type="button"
      data-testid="skills-landing"
      data-layout={layout}
      onClick={() => onSkillSelect({
        id: 'skill-1',
        name: 'Skill 1',
        color: '#111111',
        icon: 'S',
        source: 'builtin',
        modelCapabilityHint: 'any',
      })}
    />
  ),
}));

vi.mock('./SkillIntro', () => ({
  SkillIntro: ({ skill }: { skill: { id: string; name: string } }) => (
    <div data-testid="skill-intro" data-skill-id={skill.id} data-skill-name={skill.name} />
  ),
}));

vi.mock('./LazyChatOverlays', () => ({
  LazyModelSwitcher: ({ onClose }: { onClose?: () => void }) => (
    <div data-testid="model-switcher">
      <button type="button" onClick={onClose}>close model switcher</button>
    </div>
  ),
  LazyExportMenu: () => <div data-testid="export-menu" />,
}));

vi.mock('../Toast', () => ({
  showToast: vi.fn(),
}));

vi.mock('../../lib/core/providers/error-i18n', () => ({
  localizeProviderError: (message: string) => message,
}));

vi.mock('../../lib/utils/format-utils', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/utils/format-utils')>();
  return {
    ...actual,
    evaluateExpensiveModelMultiplier: () => null,
  };
});

vi.mock('../../lib/core/cost/cost-summary', () => ({
  buildMonthlyCostSummary: () => ({ totalCost: 0 }),
}));

vi.mock('../../lib/core/usage/usage-api', () => ({
  fetchUsageBudget: (...args: unknown[]) => mockFetchUsageBudget(...args),
  fetchUsageSummary: (...args: unknown[]) => mockFetchUsageSummary(...args),
}));

vi.mock('../../lib/core/usage/budget-check', () => ({
  updateBudgetCache: vi.fn(),
}));

vi.mock('../../lib/core/usage/usage-overlay', () => ({
  applyPendingEventsToUsageSummary: (value: unknown) => value,
}));

vi.mock('../../lib/core/usage/usage-reporter', () => ({
  getPendingUsageEvents: vi.fn(async () => []),
}));

vi.mock('../usage/BudgetToast', () => ({
  BudgetToast: () => <div data-testid="budget-toast" />,
}));

const { mockGetCurrentUserIDToken, mockGetCurrentUserUID, mockHasAuthenticatedUser, mockInitAuthObserver } = vi.hoisted(() => ({
  mockGetCurrentUserIDToken: vi.fn(),
  mockGetCurrentUserUID: vi.fn(),
  mockHasAuthenticatedUser: vi.fn(),
  mockInitAuthObserver: vi.fn(),
}));

vi.mock('../../lib/core/skills/query', () => ({
  getSkillById: (...args: unknown[]) => mockGetSkillById(...args),
}));

vi.mock('../../lib/core/skills/start-conversation', () => ({
  startConversationWithSkill: (...args: unknown[]) => mockStartConversationWithSkill(...args),
}));

vi.mock('../../lib/core/metadata/metadata-client', () => ({
  // These fixtures carry no metadata ETag, so identity gets no revision and the negative cache fails closed.
  getMetadataRevision: () => undefined,
  // No out-of-catalog facts are simulated here; absence means unknown, and must not invent a tool_call verdict.
  getModelFacts: () => undefined,
  getModelFactsRevision: () => undefined,
  getProviderAttachmentSupport: () => ({ image: true, nativeFile: false, textFileInline: true }),
  getSupportedReasoningModes: () => ['automatic', 'fast', 'balanced', 'deep', 'max'],
  clampReasoningMode: (mode: string) => mode,
  getLibraryRuntimeConfig: () => ({ weakModelDenylist: [] }),
  // Needed by the retrieval route: when the model object carries no authoritative backend bit, look it up in the catalog
  getModelTransport: () => 'openai_chat',
  // presentCapabilityControl reads the capability runtime on demand. These fixtures have no
  // snapshot, so all three controls honestly report the "no automatic configuration"
  // unknown state, exactly what production shows when no runtime has been delivered.
  getCapabilityRuntime: () => mockCapabilityRuntime.current,
  // With no v2 runtime the code falls back to the legacy reasoning profile from the server.
  // These fixtures declare no profile, so the tier list is empty and the fallback does
  // nothing - the honest state when no capability source exists at all.
  getDeclaredReasoningLevels: () => [],
  getRelayRuntimeConfig: () => undefined,
  // ChatView builds the production generation options even when these UI
  // cases do not declare a generation profile.
  resolveGenerationProfileRef: () => undefined,
  // Whether the retrieval route can be decided now depends on catalog entries only.
  // The default null means the model is not in the catalog, so the route is pending and
  // presented as unavailable after one forced refresh; cases that need the catalog to
  // answer override this with a catalog record.
  resolveCatalogModel: (...args: unknown[]) => mockResolveCatalogModel(...args),
  // The library route recomputes on metadata version changes (the verdict differs before and after the snapshot arrives): give it a fixed version and an empty subscription.
  hasCatalogModel: (...args: unknown[]) => mockHasCatalogModel(...args),
  // Likewise, the confirmation gate for negative conclusions (no "unsupported" verdict
  // before it is confirmed) is covered in library/routing.test.ts; these cases compute as
  // if the backend had already been asked this session.
  isMetadataSnapshotConfirmed: () => true,
  getCachedMetadataVersion: () => 1,
  onVersionChange: () => () => {},
  refreshMetadata: (...args: unknown[]) => mockRefreshMetadata(...args),
}));

describe('ChatView', () => {
  async function renderChatView(props?: { conversationId?: string }) {
    let view!: ReturnType<typeof render>;

    await act(async () => {
      view = render(<ChatView {...props} />);
      await Promise.resolve();
    });

    return view;
  }





beforeEach(async () => {
    mockLocale = 'en';
    libraryFeatureFlagMock.enabled = true;
  mockSearchParams = new URLSearchParams();
  routerPush.mockReset();
  routerReplace.mockReset();
    mockState = {
      providers: [
        {
          id: 'provider-1',
          kind: 'openai',
          status: { kind: 'issue', message: 'Key expired' },
          models: [
            {
              id: 'model-1',
              name: 'GPT-4o',
              capabilities: [],
              reasoningModeAvailable: true,
              isAvailable: true,
              isDefault: true,
              priceTier: '$',
            },
          ],
          catalogModels: [],
        },
      ],
      account: null,
      activeConversationId: null,
      streamingTexts: {},
      streamingMessageIds: {},
      streamingConversationIds: [],
      lastUsedModelRef: null,
      syncState: 'disabled',
      setLastUsedModelRef: vi.fn(),
      sidebarOpen: false,
      setSidebarOpen: vi.fn(),
      preferences: { memoryText: '', sendShortcut: 'enter' },
      conversations: [],
      notes: [],
      catalogSkills: [],
      userSkills: [],
      libraryConnections: [],
      libraryQuota: null,
      libraryLoadState: 'ready',
      libraryErrorCode: null,
      libraryResearchEnabled: false,
      setLibraryResearchEnabled: vi.fn(),
      setLibraryQuota: vi.fn(),
      setLibraryResearchSteps: vi.fn(),
      setLibraryConfirmation: vi.fn(),
      clearStreamingForConversation: vi.fn(),
    };
    mockCreateProviderSelectionSnapshot.mockReset();
    mockHasCatalogModel.mockReset();
    mockHasCatalogModel.mockReturnValue(true);
    mockResolveCatalogModel.mockReset();
    mockResolveCatalogModel.mockReturnValue(null);
    mockCapabilityRuntime.current = undefined;
    mockRefreshMetadata.mockReset();
    mockRefreshMetadata.mockResolvedValue(undefined);
    mockGetConversationById.mockReset();
    mockGetCachedManagedProvider.mockReset();
    mockRefreshManagedProvider.mockReset();
    mockSubscribeManagedProvider.mockReset();
    mockAcknowledgeManagedPrivacy.mockReset();
    mockFetchManagedBalance.mockReset();
    mockUseStreamChat.mockReset();
    mockFetchUsageSummary.mockReset();
    mockFetchUsageBudget.mockReset();
    mockGetCurrentUserIDToken.mockReset();
    mockGetCurrentUserUID.mockReset();
    mockHasAuthenticatedUser.mockReset();
    mockInitAuthObserver.mockReset();
    mockGetSyncAdapter.mockReset();
    mockLoadSyncCore.mockReset();
    mockGetSkillById.mockReset();
    mockStartConversationWithSkill.mockReset();
    mockUpdateConversation.mockReset();
    mockAddConversation.mockReset();
    mockPinNoteToConversation.mockReset();
    mockUnpinNoteFromConversation.mockReset();
    mockUpdateNoteBody.mockReset();
    mockPinNoteToConversation.mockReturnValue(true);
    mockGetCurrentUserUID.mockReturnValue('user-1');
    mockGetConversationById.mockResolvedValue(undefined);
    mockGetCachedManagedProvider.mockReturnValue(null);
    mockRefreshManagedProvider.mockResolvedValue(null);
    mockSubscribeManagedProvider.mockReturnValue(() => undefined);
    mockAcknowledgeManagedPrivacy.mockResolvedValue({
      acknowledgedAt: '2026-05-12T00:00:00Z',
      clientAckVersion: 'managed-privacy-v1',
    });
    mockFetchManagedBalance.mockResolvedValue({ user_id: 'user-1', acknowledged_at: null });
    mockUseStreamChat.mockReturnValue({
      send: vi.fn(),
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });
    mockFetchUsageSummary.mockResolvedValue({
      aggregationTimezone: 'UTC',
      thisMonth: { month: '2026-06', totalCost: 0, totalMessages: 0, byProvider: [] },
      allTime: { totalCost: 0, totalMessages: 0 },
    });
    mockFetchUsageBudget.mockResolvedValue({ monthlyBudget: null, currency: 'USD' });
    mockGetCurrentUserIDToken.mockResolvedValue(null);
    mockHasAuthenticatedUser.mockReturnValue(false);
    mockInitAuthObserver.mockReturnValue(() => undefined);
    mockGetSyncAdapter.mockReturnValue(null);
    mockLoadSyncCore.mockResolvedValue({
      getSyncAdapter: mockGetSyncAdapter,
    });
    mockGetSkillById.mockReturnValue(undefined);
    mockStartConversationWithSkill.mockReturnValue({ kind: 'no-provider' });
    mockCreateProviderSelectionSnapshot.mockImplementation((provider: any) => (
      provider ? {
        provider,
        enabledModels: provider.models ?? [],
        currentModel: provider.models?.[0] ?? null,
        defaultModel: provider.models?.[0] ?? null,
      } : null
    ));
    localStorage.clear();
    sessionStorage.clear();
  });

  it('does not show provider issue chrome and keeps the composer available', async () => {
    await renderChatView();

    expect(screen.queryByText('OpenAI has an issue')).toBeNull();
    expect(screen.getByTestId('input-composer').getAttribute('data-disabled')).toBe('false');
  });

  it('replaces and removes a pending quote, and quote alone never enables sending', async () => {
    const send = vi.fn();
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });
    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'ask first selection' }));
    expect(screen.getByTestId('input-composer').getAttribute('data-quote-selection')).toBe('first selection');
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));
    expect(send).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'ask second selection' }));
    expect(screen.getByTestId('input-composer').getAttribute('data-quote-selection')).toBe('secondSelection');
    fireEvent.click(screen.getByRole('button', { name: 'remove quote' }));
    expect(screen.getByTestId('input-composer').getAttribute('data-quote-selection')).toBe('');
  });

  it('consumes a pending quote only after send accepts it', async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });
    await renderChatView();
    fireEvent.click(screen.getByRole('button', { name: 'ask first selection' }));
    fireEvent.click(screen.getByRole('button', { name: 'type draft' }));
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    await waitFor(() => expect(send).toHaveBeenCalledWith(
      'vector database context', [], undefined, [], [], [],
      expect.objectContaining({ selectedText: 'first selection' }),
    ));
    expect(screen.getByTestId('input-composer').getAttribute('data-quote-selection')).toBe('');
    expect(screen.getByTestId('input-composer').getAttribute('data-value')).toBe('');
  });

  it('clears the composer after send accepts the draft', async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });
    await renderChatView();
    fireEvent.click(screen.getByRole('button', { name: 'type draft' }));
    expect(screen.getByTestId('input-composer').getAttribute('data-value')).toBe('vector database context');
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    await waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    expect(screen.getByTestId('input-composer').getAttribute('data-value')).toBe('');
  });

  it('restores a pending quote when send fails before a request handle is accepted', async () => {
    const send = vi.fn().mockRejectedValue(new Error('module failed'));
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });
    await renderChatView();
    fireEvent.click(screen.getByRole('button', { name: 'ask first selection' }));
    fireEvent.click(screen.getByRole('button', { name: 'type draft' }));
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    await waitFor(() => {
      expect(screen.getByTestId('input-composer').getAttribute('data-quote-selection')).toBe('first selection');
    });
  });

  it('removes Library chat surfaces and sends source mentions as plain text when disabled', async () => {
    const send = vi.fn();
    libraryFeatureFlagMock.enabled = false;
    mockState.libraryResearchEnabled = true;
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });

    await renderChatView();

    expect(screen.queryByRole('button', { name: 'toggle library research' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'add library context' })).toBeNull();
    expect(screen.queryByTestId('library-confirmation-dialog')).toBeNull();
    expect(mockUseStreamChat.mock.calls.at(-1)?.[0]).toMatchObject({
      libraryResearchEnabled: false,
      onLibraryContextFailed: undefined,
    });
    await waitFor(() => {
      expect(mockState.setLibraryResearchEnabled).toHaveBeenCalledWith(false);
    });

    fireEvent.click(screen.getByRole('button', { name: 'type source mention' }));
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    expect(send).toHaveBeenCalledWith(
      '@Notion summarize this',
      [],
      undefined,
      [],
      [],
      [],
    );
    expect(routerPush).not.toHaveBeenCalled();
  });

  // The Library entry point only appears for users with a connected source: without one the
  // chip opens an empty panel. Guests therefore must not see the entry at all - this case
  // locks that down rather than leaving a gap.
  it('hides the Library entry from guests, who never have a connection', async () => {
    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'type draft' }));

    expect(screen.queryByRole('button', { name: 'add library context' })).toBeNull();
    expect(routerPush).not.toHaveBeenCalledWith(
      expect.stringContaining('/welcome?returnTo='),
    );
    expect(sessionStorage.getItem('oriveo.libraryLoginDraft.v1')).toBeNull();
  });

  // A guest typing an @source mention and pressing send used to call a toggle that is a
  // no-op for guests and then return: the button did nothing, the input was not cleared,
  // and nothing was shown - a dead end.
  it('guides a guest who mentions a source instead of silently swallowing the send', async () => {
    const send = vi.fn();
    mockState.account = null;
    mockState.libraryConnections = [];
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });

    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'type source mention' }));
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    expect(send).not.toHaveBeenCalled();
    expect(showToast).toHaveBeenCalledWith(
      'connectRequired',
      5000,
      undefined,
      'warning',
    );
  });

  // A weak model (no tool calls) never silently falls back to a different panel: there is
  // one Library entry and it always opens the same panel, with the scope option greyed out
  // and explained, so the user can switch to named documents in place.
  it('opens the single Library panel on a weak model and still supports picking documents', async () => {
    const send = vi.fn();
    mockState.account = { email: 'user@example.com' };
    mockState.libraryConnections = [{
      id: 'connection-1',
      provider: 'notion',
      status: 'active',
    }];
    mockHasAuthenticatedUser.mockReturnValue(true);
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });

    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'add library context' }));
    expect(screen.getByRole('dialog', { name: 'library context picker' })).toBeTruthy();
    expect(mockState.setLibraryResearchEnabled).not.toHaveBeenCalledWith(true);

    fireEvent.click(screen.getByRole('button', { name: 'select Roadmap' }));
    fireEvent.click(screen.getByRole('button', { name: 'finish context selection' }));
    expect(screen.getByTestId('input-composer').getAttribute('data-web-search-enabled')).toBe('false');
    expect(screen.getByTestId('input-composer').getAttribute('data-library-context-count')).toBe('1');
    expect(mockState.setLibraryResearchEnabled).toHaveBeenCalledWith(false);
    fireEvent.click(screen.getByRole('button', { name: 'type draft' }));
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    expect(send).toHaveBeenCalledWith(
      'vector database context',
      [],
      undefined,
      [],
      [],
      [{ docId: 'doc-1', source: 'notion', title: 'Roadmap' }],
    );
  });

  // Hand-entered models outside the catalog fail open under the central tool_call policy:
  // once the final transport is known a catalog miss no longer creates pending and does not
  // force a metadata refresh per model. Real lack of support is vetoed by a persisted
  // explicit false from first-party facts, and a runtime rejection recovers without tools.
  it('keeps catalog-miss models available without forced refresh when final transport is known', async () => {
    mockState.account = { email: 'user@example.com' };
    mockState.libraryConnections = [{
      id: 'connection-1',
      provider: 'notion',
      status: 'active',
    }];
    mockHasAuthenticatedUser.mockReturnValue(true);
    // Not found in the catalog means "cannot tell", not "unsupported".
    mockResolveCatalogModel.mockReturnValue(null);
    const view = await renderChatView();

    const routeState = () => screen.getByTestId('library-route-state');
    expect(mockRefreshMetadata).not.toHaveBeenCalled();
    expect(routeState().getAttribute('data-research-pending')).toBe('false');
    expect(routeState().getAttribute('data-research-available')).toBe('true');

    // The same model pair never refreshes twice.
    await act(async () => {
      view.rerender(<ChatView />);
    });
    expect(mockRefreshMetadata).not.toHaveBeenCalled();

    // Switching to another out-of-catalog model does not refresh either: it also has a definite final transport.
    mockState.providers = [{
      ...mockState.providers[0],
      models: [{
        id: 'model-2',
        name: 'GPT-4.1',
        capabilities: [],
        reasoningModeAvailable: true,
        isAvailable: true,
        isDefault: true,
        priceTier: '$',
      }],
    }];
    await act(async () => {
      view.rerender(<ChatView />);
    });

    expect(mockRefreshMetadata).not.toHaveBeenCalled();
    expect(routeState().getAttribute('data-research-pending')).toBe('false');
    expect(routeState().getAttribute('data-research-available')).toBe('true');
  });

  it('opens direct Add context for an explicit source mention on a weak model', async () => {
    const send = vi.fn();
    mockState.account = { email: 'user@example.com' };
    mockState.libraryConnections = [{
      id: 'connection-1',
      provider: 'notion',
      status: 'active',
    }];
    mockHasAuthenticatedUser.mockReturnValue(true);
    mockState.providers[0].models[0] = {
      ...mockState.providers[0].models[0],
      // On a catalog miss the first-party catalog namespace cannot be reused; once facts
      // are absent too, the central policy reads this persisted explicit false.
      toolCall: false,
    };
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });

    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'type source mention' }));
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    expect(screen.getByRole('dialog', { name: 'library context picker' })).toBeTruthy();
    expect(send).not.toHaveBeenCalled();
  });

  it('keeps Web search, Library research, and Add context mutually exclusive', async () => {
    mockState.account = { email: 'user@example.com' };
    mockState.libraryConnections = [{
      id: 'connection-1',
      provider: 'notion',
      status: 'active',
    }];
    mockState.providers[0].models[0] = {
      ...mockState.providers[0].models[0],
      toolCall: true,
      transport: 'openai_chat',
    };
    // For official providers, agentic authorization comes from the catalog capability bits
    // only: toolCall/transport on the model object can no longer authorize on their own, so
    // a catalog miss is pending and then unavailable. This case is about the three entry
    // points being mutually exclusive, which presumes retrieval really is available, hence
    // the v2 catalog hit.
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'model-1',
      transport: 'openai_chat',
      capabilityContractVersion: 2,
      libraryAgentic: true,
      toolCall: true,
    });
    mockCapabilityRuntime.current = { revision: 'mutual-exclusion-test' };
    mockHasAuthenticatedUser.mockReturnValue(true);

    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'add library context' }));
    fireEvent.click(screen.getByRole('button', { name: 'select Roadmap' }));
    fireEvent.click(screen.getByRole('button', { name: 'finish context selection' }));
    expect(screen.getByTestId('input-composer').getAttribute('data-library-context-count')).toBe('1');

    fireEvent.click(screen.getByRole('button', { name: 'toggle web search' }));
    // Catalog availability makes the local intent writable and clears mutually-exclusive
    // context, but without an official request recipe the outbound projection stays honest.
    expect(screen.getByTestId('input-composer').getAttribute('data-web-search-enabled')).toBe('true');
    expect(screen.getByTestId('input-composer').getAttribute('data-web-outbound-active')).toBe('false');
    expect(screen.getByTestId('input-composer').getAttribute('data-library-context-count')).toBe('0');

    fireEvent.click(screen.getByRole('button', { name: 'add library context' }));
    fireEvent.click(screen.getByRole('button', { name: 'select Roadmap' }));
    fireEvent.click(screen.getByRole('button', { name: 'finish context selection' }));
    fireEvent.click(screen.getByRole('button', { name: 'toggle library research' }));

    expect(screen.getByTestId('input-composer').getAttribute('data-library-context-count')).toBe('0');
    // Mutual exclusion only changes view state and is never persisted. The panel keeps
    // showing the tier the user stored - wiping it to `off` would let a temporary scope
    // choice permanently rewrite the default, and detaching the document would not bring it
    // back. Actually not searching the web this turn is enforced outbound
    // (`singleSend: { web: 'off' }`).
    expect(screen.getByTestId('input-composer').getAttribute('data-web-preference')).toBe('automatic');
    expect(screen.getByTestId('input-composer').getAttribute('data-web-outbound-active')).toBe('false');
    expect(mockState.setLibraryResearchEnabled).toHaveBeenCalledWith(true);

  });

  // The storage-level assertion: the case above only sees rendered attributes, and the lie
  // is exactly "the UI says nothing changed while storage has already been wiped".
  // This runs on an existing conversation - a draft writes to the draft slot, never reaches
  // the record table, and so cannot show this.
  it('does not persist anything when library exclusion turns web search off', async () => {
    const conversationId = 'conv-library-mutual-exclusion';
    mockState.account = { email: 'user@example.com' };
    mockState.libraryConnections = [{ id: 'connection-1', provider: 'notion', status: 'active' }];
    mockState.providers[0].models[0] = {
      ...mockState.providers[0].models[0], toolCall: true, transport: 'openai_chat',
    };
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'model-1', transport: 'openai_chat',
      capabilityContractVersion: 2, libraryAgentic: true, toolCall: true,
    });
    mockCapabilityRuntime.current = { revision: 'mutual-exclusion-persistence-test' };
    mockHasAuthenticatedUser.mockReturnValue(true);

    await renderChatView({ conversationId });

    const identity = capabilityRuntimeIdentity(mockState.providers[0], mockState.providers[0].models[0]);
    expect(identity).toBeTruthy();
    const stored = () => resolveCapabilityPreferences({ ...identity!, conversationId }).web;

    fireEvent.click(screen.getByRole('button', { name: 'toggle web search' }));
    expect(stored()).toBe('automatic');

    // Scoped research only silences this turn's outbound request; it never wipes the preference the user expressed.
    fireEvent.click(screen.getByRole('button', { name: 'toggle library research' }));
    expect(stored()).toBe('automatic');
    expect(screen.getByTestId('input-composer').getAttribute('data-web-outbound-active')).toBe('false');

    // Same for attaching a document.
    fireEvent.click(screen.getByRole('button', { name: 'add library context' }));
    fireEvent.click(screen.getByRole('button', { name: 'select Roadmap' }));
    fireEvent.click(screen.getByRole('button', { name: 'finish context selection' }));
    expect(stored()).toBe('automatic');
  });

  // Entry-point visibility no longer depends on the older webSearchProfile: every chat
  // model shows the web search entry, and missing automatic configuration only changes what
  // the panel honestly reports. This case locks the entry point in place.
  it('keeps the web search control visible when the model has no webSearchProfile', async () => {
    mockState.providers[0].kind = 'openAI';
    mockState.providers[0].models[0] = {
      ...mockState.providers[0].models[0],
      capabilities: ['text', 'web'],
      webSearchProfile: undefined,
    };

    await renderChatView();

    expect(['off', 'automatic', 'force'])
      .toContain(screen.getByTestId('input-composer').getAttribute('data-web-preference'));
  });

  it('shows the web search control when capability and webSearchProfile are both present', async () => {
    mockState.providers[0].kind = 'openAI';
    mockState.providers[0].models[0] = {
      ...mockState.providers[0].models[0],
      capabilities: ['text', 'web'],
      webSearchProfile: 'oai_responses_web',
      transport: 'openai_chat_completions',
    };

    await renderChatView();

    expect(['off', 'automatic', 'force'])
      .toContain(screen.getByTestId('input-composer').getAttribute('data-web-preference'));
  });

  it('does not emit act warnings while resolving the initial free catalog request', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});

    await renderChatView();

    const actWarnings = consoleError.mock.calls.filter(([message]) =>
      String(message).includes('not wrapped in act'),
    );
    consoleError.mockRestore();

    expect(actWarnings).toHaveLength(0);
  });

  it('uses provider selection snapshot to resolve the active model shown in the top bar', async () => {
    mockCreateProviderSelectionSnapshot.mockReturnValueOnce({
      provider: mockState.providers[0],
      enabledModels: [],
      currentModel: {
        id: 'resolved-model',
        name: 'Resolved Snapshot Model',
        capabilities: [],
        reasoningModeAvailable: true,
        isAvailable: true,
        isDefault: true,
        priceTier: '$',
      },
      defaultModel: null,
    });

    await renderChatView();

    expect(screen.getByTestId('top-bar').getAttribute('data-model-name')).toBe('Resolved Snapshot Model');
    expect(mockCreateProviderSelectionSnapshot).toHaveBeenCalled();
  });

  it('lifts the composer into the empty home workspace', async () => {
    await renderChatView();

    expect(screen.getByTestId('input-composer').getAttribute('data-presentation')).toBe('home');
  });

  it('ignores the retired compose noteId flow instead of pinning a source note as context', async () => {
    mockSearchParams = new URLSearchParams('compose=1&noteId=note-1');
    mockState.notes = [{
      id: 'note-1',
      title: 'Vector recall',
      titleSource: 'manual',
      body: 'Use tags first.',
      tags: [],
      captureKind: 'blank',
      createdAt: '2026-06-19T00:00:00.000Z',
      updatedAt: '2026-06-19T00:00:00.000Z',
    }];

    await renderChatView();

    await waitFor(() => {
      const composer = screen.getByTestId('input-composer');
      expect(composer.getAttribute('data-attached-note-count')).toBe('0');
      expect(composer.getAttribute('data-attached-note-titles')).toBe('');
      expect(composer.getAttribute('data-value')).toBe('');
      expect(composer.getAttribute('data-placeholder-override')).toBe('');
    });
    expect(mockPinNoteToConversation).not.toHaveBeenCalled();
  });

  it('does not mutate note context when legacy noteId is present', async () => {
    mockSearchParams = new URLSearchParams('compose=1&noteId=note-1');
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [
      {
        id: 'conversation-1',
        title: 'Chat',
        hasCustomTitle: false,
        providerID: 'provider-1',
        providerKind: 'openAI',
        modelID: 'model-1',
        previewText: '',
        estimatedCost: 0,
        isDraft: false,
        messages: [],
        draftText: '',
        createdAt: '2026-06-19T00:00:00.000Z',
        updatedAt: '2026-06-19T00:00:00.000Z',
      },
    ];
    mockState.notes = [{
      id: 'note-1',
      title: 'Vector recall',
      titleSource: 'manual',
      body: 'Use tags first.',
      tags: [],
      captureKind: 'blank',
      createdAt: '2026-06-19T00:00:00.000Z',
      updatedAt: '2026-06-19T00:00:00.000Z',
    }];

    await renderChatView({ conversationId: 'conversation-1' });

    await waitFor(() => {
      expect(screen.getByTestId('input-composer')).toBeTruthy();
    });
    expect(mockPinNoteToConversation).not.toHaveBeenCalled();
    expect(mockUpdateNoteBody).not.toHaveBeenCalled();
  });

  it('does not offer to append the latest assistant answer back to the source note', async () => {
    mockSearchParams = new URLSearchParams('compose=1&noteId=note-1');
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [
      {
        id: 'conversation-1',
        title: 'Chat',
        hasCustomTitle: false,
        providerID: 'provider-1',
        providerKind: 'openAI',
        modelID: 'model-1',
        previewText: '',
        estimatedCost: 0,
        isDraft: false,
        messages: [
          { id: 'u1', role: 'user', text: 'Can you refine it?', state: 'delivered' },
          { id: 'a1', role: 'assistant', text: 'Use semantic chunking.', state: 'delivered' },
        ],
        draftText: '',
        createdAt: '2026-06-19T00:00:00.000Z',
        updatedAt: '2026-06-19T00:00:00.000Z',
      },
    ];
    mockState.notes = [{
      id: 'note-1',
      title: 'Vector recall',
      titleSource: 'manual',
      body: 'Use tags first.',
      tags: [],
      captureKind: 'blank',
      createdAt: '2026-06-19T00:00:00.000Z',
      updatedAt: '2026-06-19T00:00:00.000Z',
    }];

    await renderChatView({ conversationId: 'conversation-1' });

    expect(screen.queryByRole('button', { name: 'updateNoteFromChat' })).toBeNull();
    expect(mockUpdateNoteBody).not.toHaveBeenCalled();
  });

  it('only surfaces saved-note badges for notes sourced from the active conversation', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [
      {
        id: 'conversation-1',
        title: 'Chat',
        hasCustomTitle: false,
        providerID: 'provider-1',
        providerKind: 'openAI',
        modelID: 'model-1',
        previewText: '',
        estimatedCost: 0,
        isDraft: false,
        messages: [
          { id: 'msg-1', role: 'assistant', text: 'Answer', state: 'delivered' },
        ],
        draftText: '',
        createdAt: '2026-06-19T00:00:00.000Z',
        updatedAt: '2026-06-19T00:00:00.000Z',
      },
    ];
    mockState.notes = [
      {
        id: 'note-current',
        title: 'Current note',
        titleSource: 'manual',
        body: 'Answer',
        tags: [],
        captureKind: 'fullAnswer',
        sourceConversationId: 'conversation-1',
        sourceMessageId: 'msg-1',
        createdAt: '2026-06-19T00:00:00.000Z',
        updatedAt: '2026-06-19T00:00:00.000Z',
      },
      {
        id: 'note-missing-conversation',
        title: 'Missing conversation note',
        titleSource: 'manual',
        body: 'Old malformed data',
        tags: [],
        captureKind: 'fullAnswer',
        sourceMessageId: 'msg-1',
        createdAt: '2026-06-19T00:00:00.000Z',
        updatedAt: '2026-06-19T00:00:00.000Z',
      },
      {
        id: 'note-other-conversation',
        title: 'Other conversation note',
        titleSource: 'manual',
        body: 'Other',
        tags: [],
        captureKind: 'fullAnswer',
        sourceConversationId: 'conversation-2',
        sourceMessageId: 'msg-1',
        createdAt: '2026-06-19T00:00:00.000Z',
        updatedAt: '2026-06-19T00:00:00.000Z',
      },
    ];

    await renderChatView({ conversationId: 'conversation-1' });

    const refs = JSON.parse(screen.getByTestId('message-list').getAttribute('data-saved-note-refs') ?? '{}');
    expect(refs['msg-1']).toEqual([{ id: 'note-current', title: 'Current note' }]);
  });

  it('only forwards replace-current-note context when the return note is still active', async () => {
    mockSearchParams = new URLSearchParams('fromNote=note-current');
    mockState.notes = [{
      id: 'note-current',
      title: 'Current note',
      titleSource: 'manual',
      body: 'Original body',
      tags: [],
      captureKind: 'blank',
      createdAt: '2026-06-19T00:00:00.000Z',
      updatedAt: '2026-06-19T00:00:00.000Z',
    }];

    await renderChatView();

    expect(screen.getByTestId('message-list').getAttribute('data-replace-current-note-id')).toBe('note-current');
  });

  it('does not forward replace-current-note context for a stale return note id', async () => {
    mockSearchParams = new URLSearchParams('fromNote=missing-note');
    mockState.notes = [];

    await renderChatView();

    expect(screen.getByTestId('message-list').getAttribute('data-replace-current-note-id')).toBe('');
  });

  it('keeps the composer docked once a conversation has messages', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [
      {
        id: 'conversation-1',
        providerID: 'provider-1',
        modelID: 'model-1',
        messages: [{ id: 'message-1', role: 'user', text: 'hello' }],
      },
    ];

    await renderChatView({ conversationId: 'conversation-1' });

    expect(screen.getByTestId('input-composer').getAttribute('data-presentation')).toBe('docked');
  });

  it('surfaces related notes from the draft and pins the selected note', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [
      {
        id: 'conversation-1',
        title: 'Chat',
        hasCustomTitle: false,
        providerID: 'provider-1',
        providerKind: 'openAI',
        modelID: 'model-1',
        previewText: '',
        estimatedCost: 0,
        isDraft: false,
        messages: [{ id: 'message-1', role: 'user', text: 'hello' }],
        draftText: '',
        createdAt: '2026-06-19T00:00:00.000Z',
        updatedAt: '2026-06-19T00:00:00.000Z',
      },
    ];
    mockState.notes = [{
      id: 'note-1',
      title: 'Vector recall',
      titleSource: 'manual',
      body: 'vector database context',
      tags: ['vector'],
      captureKind: 'blank',
      createdAt: '2026-06-19T00:00:00.000Z',
      updatedAt: '2026-06-19T00:00:00.000Z',
    }];

    await renderChatView({ conversationId: 'conversation-1' });

    fireEvent.click(screen.getByRole('button', { name: 'type draft' }));
    await waitFor(() => {
      expect(screen.getByTestId('input-composer').getAttribute('data-related-note-count')).toBe('1');
    });

    fireEvent.click(screen.getByRole('button', { name: 'attach Vector recall' }));

    expect(mockPinNoteToConversation).toHaveBeenCalledWith(expect.anything(), 'conversation-1', 'note-1');
  });

  it('keeps a related note pending for the first message when no conversation exists yet', async () => {
    const send = vi.fn();
    mockUseStreamChat.mockReturnValue({
      send,
      continueAnswering: vi.fn(),
      retry: vi.fn(),
      editAndResend: vi.fn(),
      stop: vi.fn(),
    });
    mockState.notes = [{
      id: 'note-1',
      title: 'Vector recall',
      titleSource: 'manual',
      body: 'vector database context',
      tags: ['vector'],
      captureKind: 'blank',
      createdAt: '2026-06-19T00:00:00.000Z',
      updatedAt: '2026-06-19T00:00:00.000Z',
    }];

    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'type draft' }));
    await waitFor(() => {
      expect(screen.getByTestId('input-composer').getAttribute('data-related-note-count')).toBe('1');
    });

    fireEvent.click(screen.getByRole('button', { name: 'attach Vector recall' }));
    fireEvent.click(screen.getByRole('button', { name: 'send draft' }));

    expect(mockPinNoteToConversation).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledWith(
      'vector database context',
      [],
      undefined,
      [],
      ['note-1'],
      [],
    );
  });

  it('falls back to another provider when the conversation provider is missing', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [
      {
        id: 'conversation-1',
        providerID: 'provider-missing',
        modelID: 'model-missing',
        messages: [{ id: 'message-1', role: 'assistant', text: 'hello' }],
      },
    ];

    await renderChatView({ conversationId: 'conversation-1' });

    expect(screen.getByTestId('top-bar').getAttribute('data-model-name')).toBe('GPT-4o');
    expect(screen.getByTestId('input-composer').getAttribute('data-disabled')).toBe('false');
    expect(mockCreateProviderSelectionSnapshot).toHaveBeenCalledWith(undefined, {
      requestedModelId: 'model-missing',
    });
  });

  it('keeps existing history visible when there are no providers left', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.providers = [];
    mockState.conversations = [
      {
        id: 'conversation-1',
        providerID: 'provider-missing',
        modelID: 'model-missing',
        messages: [{ id: 'm-1', role: 'user', text: 'hello' }],
      },
    ];

    await renderChatView({ conversationId: 'conversation-1' });

    expect(screen.queryByText('Add a provider to start chatting.')).toBeNull();
    expect(screen.getByTestId('message-list')).toBeTruthy();
    expect(screen.getByTestId('input-composer').getAttribute('data-disabled')).toBe('false');
  });

  it('disables the composer while hydrating an existing summary-only conversation', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [{
      id: 'conversation-1',
      title: 'Summary Only',
      hasCustomTitle: false,
      providerID: 'provider-1',
      modelID: 'model-1',
      previewText: 'Existing preview',
      estimatedCost: 0,
      isDraft: false,
      messages: [],
      draftText: '',
      updatedAt: new Date().toISOString(),
    }];
    mockGetConversationById.mockImplementation(() => new Promise(() => {}));

    await renderChatView({ conversationId: 'conversation-1' });

    expect(screen.getByTestId('input-composer').getAttribute('data-disabled')).toBe('true');
  });

  it('shows a conversation bootstrap state instead of skills landing while hydrating an existing conversation', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [{
      id: 'conversation-1',
      title: 'Summary Only',
      hasCustomTitle: false,
      providerID: 'provider-1',
      modelID: 'model-1',
      previewText: 'Existing preview',
      estimatedCost: 0,
      isDraft: false,
      remoteMessageCount: 8,
      messages: [],
      draftText: '',
      updatedAt: new Date().toISOString(),
    }];
    mockGetConversationById.mockImplementation(() => new Promise(() => {}));

    await renderChatView({ conversationId: 'conversation-1' });

    expect(screen.getByTestId('conversation-bootstrap-state')).toBeTruthy();
    expect(screen.queryByTestId('skills-landing')).toBeNull();
  });

  // Intentional behavior change: the earlier implementation released the skeleton after 3s
  // and fell back to an editable empty state, which - with no local body but history in the
  // cloud - let the user keep chatting in a seemingly blank conversation while context was
  // silently lost. The contract is now a 12s timeout into an explicit stalled error state
  // with a retry action, keeping the composer disabled.
  it('falls back to the stalled state when message hydration times out', async () => {
    vi.useFakeTimers();
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [{
      id: 'conversation-1',
      title: 'Summary Only',
      hasCustomTitle: false,
      providerID: 'provider-1',
      modelID: 'model-1',
      previewText: 'Existing preview',
      estimatedCost: 0,
      isDraft: false,
      remoteMessageCount: 8,
      messages: [],
      draftText: '',
      updatedAt: new Date().toISOString(),
    }];
    mockGetConversationById.mockImplementation(() => new Promise(() => {}));

    try {
      await renderChatView({ conversationId: 'conversation-1' });

      expect(screen.getByTestId('conversation-bootstrap-state')).toBeTruthy();
      expect(screen.getByTestId('input-composer').getAttribute('data-disabled')).toBe('true');

      // The old 3s threshold would have released here; at the new 12s threshold it must still be the skeleton
      await act(async () => {
        await vi.advanceTimersByTimeAsync(3500);
        await Promise.resolve();
      });
      expect(screen.getByTestId('conversation-bootstrap-state')).toBeTruthy();

      await act(async () => {
        await vi.advanceTimersByTimeAsync(9000);
        await Promise.resolve();
      });

      expect(screen.queryByTestId('conversation-bootstrap-state')).toBeNull();
      // Does not reuse the welcome screen: it settles into an explicit stalled error state and must offer a primary action
      expect(screen.getByTestId('conversation-stalled-state')).toBeTruthy();
      expect(screen.queryByTestId('skills-landing')).toBeNull();
      //   5 stalled  
      expect(screen.getByTestId('input-composer').getAttribute('data-disabled')).toBe('true');
    } finally {
      vi.useRealTimers();
    }
  });

  it('does not rehydrate a conversation from IndexedDB after it was already present and then removed locally', async () => {
    mockState.activeConversationId = 'conversation-1';
    mockState.conversations = [{
      id: 'conversation-1',
      title: 'Existing Conversation',
      hasCustomTitle: false,
      providerID: 'provider-1',
      modelID: 'model-1',
      previewText: 'Existing preview',
      estimatedCost: 0,
      isDraft: false,
      messages: [{ id: 'message-1', role: 'user', text: 'hello' }],
      draftText: '',
      updatedAt: new Date().toISOString(),
    }];

    const view = await renderChatView({ conversationId: 'conversation-1' });

    expect(mockGetConversationById).not.toHaveBeenCalled();

    mockState.conversations = [];

    await act(async () => {
      view.rerender(<ChatView conversationId="conversation-1" />);
      await Promise.resolve();
    });

    expect(mockGetConversationById).not.toHaveBeenCalled();
  });

  it('loads sync core lazily before starting the messages listener', async () => {
    const startMessagesListener = vi.fn();
    const stopMessagesListener = vi.fn();

    mockState.syncState = 'enabled';
    mockState.activeConversationId = 'conversation-1';
    mockGetSyncAdapter.mockReturnValue({
      startMessagesListener,
      stopMessagesListener,
    });

    const { unmount } = await renderChatView({ conversationId: 'conversation-1' });

    await waitFor(() => {
      // Assert only that the lazy entry point was taken, not how many times: the sync core
      // now has several lazy consumers (listener mounting, backfill checks, adapter
      // lifecycle subscriptions) and dynamic import has its own module cache, so pinning a
      // count would report every new consumer as a regression.
      expect(mockLoadSyncCore).toHaveBeenCalled();
      expect(startMessagesListener).toHaveBeenCalledWith('conversation-1');
    });

    unmount();

    expect(stopMessagesListener).toHaveBeenCalledTimes(1);
  });

  it('starts a draft conversation and navigates when selecting a skill from the landing state', async () => {
    mockStartConversationWithSkill.mockReturnValue({ kind: 'ok', conversationId: 'new-conv-id' });

    await renderChatView();

    fireEvent.click(screen.getByTestId('skills-landing'));

    await waitFor(() => {
      expect(mockStartConversationWithSkill).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ id: 'skill-1' }),
        expect.objectContaining({ title: expect.any(String) }),
      );
    });
    expect(routerReplace).toHaveBeenCalledWith('/chat/new-conv-id');
    expect(sessionStorage.getItem('pendingSkillId')).toBeNull();
  });

  it('shows an in-app provider prompt instead of routing immediately when no provider can resolve the skill', async () => {
    mockStartConversationWithSkill.mockReturnValue({ kind: 'no-provider' });

    await renderChatView();

    fireEvent.click(screen.getByTestId('skills-landing'));

    await waitFor(() => {
      expect(screen.getByRole('dialog')).toBeTruthy();
    });
    expect(screen.getByText('Add provider to use this Skill')).toBeTruthy();
    expect(routerPush).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'Add Provider' }));

    expect(routerPush).toHaveBeenCalledWith('/providers/new');
    expect(routerReplace).not.toHaveBeenCalled();
  });

  it('renders SkillIntro instead of SkillsLanding when the active conversation already has a skillId', async () => {
    mockState.activeConversationId = 'conv-with-skill';
    mockState.conversations = [{
      id: 'conv-with-skill',
      title: 'Skill 1',
      hasCustomTitle: false,
      providerID: 'provider-1',
      modelID: 'model-1',
      previewText: '',
      estimatedCost: 0,
      isDraft: true,
      messages: [],
      draftText: '',
      updatedAt: new Date().toISOString(),
      skillId: 'skill-1',
    }];
    mockGetSkillById.mockReturnValue({
      id: 'skill-1',
      name: 'Skill 1',
      color: '#111',
      icon: 'S',
      source: 'builtin',
      modelCapabilityHint: 'any',
    });

    await renderChatView({ conversationId: 'conv-with-skill' });

    expect(screen.getByTestId('skill-intro').getAttribute('data-skill-id')).toBe('skill-1');
    expect(screen.queryByTestId('skills-landing')).toBeNull();
  });


  // ── Reasoning "off" agrees across all three checks ────────────────────────────────
  //
  // Symptom: tapping off shows "provider default" on the chip while the request really
  // carries off, and tapping automatic afterwards is a permanently silent no-op. The cause
  // is driving the UI from the ReasoningMode enum, which cannot express off or low - off
  // has no slot and gets folded back into automatic, so display, early return and
  // persistence each tell a different story.
  describe('reasoning intent (off / tier / provider default)', () => {
    const conversationId = 'conv-reasoning-intent';

    beforeEach(() => {
      mockCapabilityRuntime.current = { revision: 'chat-view-test-runtime' };
      mockResolveCatalogModel.mockImplementation((modelId: string) => ({
        canonicalModelId: modelId,
        transport: 'openai_chat',
      }));
    });

    function currentPreferences() {
      const provider = mockState.providers[0];
      const model = provider.models[0];
      const identity = capabilityRuntimeIdentity(provider, model);
      if (!identity) throw new Error('test fixture must resolve the production capability identity');
      return resolveCapabilityPreferences({
        ...identity,
        conversationId,
      });
    }

    it('clears back to provider default after off instead of a silent no-op', async () => {
      await renderChatView({ conversationId });
      const composer = () => screen.getByTestId('input-composer');

      fireEvent.click(screen.getByRole('button', { name: 'turn reasoning off' }));
      expect(currentPreferences().reasoningIntent).toBe('off');

      // The enum is unchanged (off and automatic both map to 'automatic') but the intent is
      // not. With an early return that compares only the enum this step does nothing in
      // production, and this assertion is the one that goes red.
      fireEvent.click(screen.getByRole('button', { name: 'pick supplier default' }));
      expect(currentPreferences().reasoningIntent).toBeUndefined();

      // The same intent must also be the only source of truth for the chip.
      fireEvent.click(screen.getByRole('button', { name: 'turn reasoning off' }));
      expect(composer().getAttribute('data-reasoning-intent')).toBe('off');
      fireEvent.click(screen.getByRole('button', { name: 'pick supplier default' }));
      expect(composer().getAttribute('data-reasoning-intent')).toBe('');
    });

    it('routes tier selection and provider default through the same intent channel', async () => {
      await renderChatView({ conversationId });
      const composer = () => screen.getByTestId('input-composer');

      fireEvent.click(screen.getByRole('button', { name: 'pick deep reasoning' }));
      expect(composer().getAttribute('data-reasoning-intent')).toBe('deep');
      expect(currentPreferences().reasoningIntent).toBe('deep');

      fireEvent.click(screen.getByRole('button', { name: 'pick supplier default' }));
      expect(composer().getAttribute('data-reasoning-intent')).toBe('');
      expect(currentPreferences().reasoningIntent).toBeUndefined();
    });
  });

  // ── The globe chip highlight and the real outbound gate must be one check ────────────
  //
  // Without a server recipe no web configuration can be sent; the entry point stays
  // reachable, but the active state only reflects what actually goes out.
  it('keeps the web entry reachable on unknown without pretending the request went out', async () => {
    mockUseStreamChat.mockReturnValue({
      send: vi.fn(), continueAnswering: vi.fn(), retry: vi.fn(), editAndResend: vi.fn(), stop: vi.fn(),
    });
    await renderChatView();

    fireEvent.click(screen.getByRole('button', { name: 'toggle web search' }));

    // The entry is unconditionally reachable and the control verdict is honestly unknown - with no recipe no web fields compile.
    expect(screen.getByTestId('input-composer').getAttribute('data-web-control-state')).toBe('unknown');
    expect(screen.getByTestId('input-composer').getAttribute('data-web-search-enabled')).toBe('false');
    expect(screen.getByTestId('input-composer').getAttribute('data-web-outbound-active')).toBe('false');
    expect(mockUseStreamChat.mock.calls.at(-1)?.[0]).toMatchObject({ webSearchEnabled: false });
  });
});
