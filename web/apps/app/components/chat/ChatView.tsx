'use client';

import { useState, useCallback, useMemo, useEffect, useRef, useSyncExternalStore } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type { AIModel, Attachment, ChatMessage, Conversation, Provider, ReasoningMode, QuoteContext } from '@oriveo/shared';
import { Button } from '@oriveo/ui';
import { useAppStore } from '../../providers/StoreProvider';
import { selectIsStreamingFor } from '../../lib/core/store/selectors';
import { useNotifications } from '../../lib/hooks/useNotifications';
import { useMediaQuery } from '../../lib/hooks/useMediaQuery';
import { useAttachmentDragDrop } from '../../lib/hooks/useAttachmentDragDrop';
import type { AttachmentFilePolicy } from '../../lib/hooks/useAttachmentIntake';
import { useStreamChat } from '../../lib/hooks/useStreamChat';
import { loadSyncCore } from '../../lib/core/sync-lazy';
import { getVanillaStore } from '../../providers/StoreProvider';
import { pinNoteToConversation, unpinNoteFromConversation } from '../../lib/core/conversation-ops';
import { canAcceptDroppedAttachment } from '../../lib/core/chat/attachment-policy';
import { TopBar } from './TopBar';
import { AttachmentIcon, WarningIcon, CloseIcon, ChevronLeftIcon } from '../icons';
import { MessageList } from './MessageList';
import { InputComposer, type AttachedNoteRef } from './InputComposer';
import { AttachmentSizeLimitDialog } from './AttachmentSizeLimitDialog';
import { SkillsLanding } from './SkillsLanding';
import { SkillIntro } from './SkillIntro';
import { LazyModelSwitcher } from './LazyChatOverlays';
import { showToast } from '../Toast';
import { SkillActionPromptDialog } from '../skills/SkillActionPromptDialog';
import { normalizeUUID, sameNormalizedID } from '../../lib/utils/id-utils';
import { stripMarkdownForClipboard } from '../../lib/utils/markdown-preview';
import {
  getCachedMetadataVersion,
  getLibraryRuntimeConfig,
  getProviderAttachmentSupport,
  getRelayRuntimeConfig,
  onVersionChange,
  refreshMetadata,
} from '../../lib/core/metadata/metadata-client';
import { resolveRelayAttachmentSupport } from '../../lib/core/providers/relay-runtime-support';

import { getSkillById } from '../../lib/core/skills/query';
import { startConversationWithSkill } from '../../lib/core/skills/start-conversation';
import { markNewConversationRoutePromotion } from '../../lib/core/chat/route-transition';
import { useSkillL10n } from '../../lib/hooks/useSkillL10n';

import { trackEvent, telemetryProviderKind, telemetryModelID } from '../../lib/core/telemetry';
import styles from './ChatView.module.css';
import { ConversationBootstrapState } from './ConversationBootstrapState';
import { ConversationStalledState } from './ConversationStalledState';
import { useConversationHydration } from './hooks/useConversationHydration';
import { useExpensiveModelHint } from './hooks/useExpensiveModelHint';
import { useChatModelSelection } from './hooks/useChatModelSelection';
import { useRelatedNoteRecall } from './hooks/useRelatedNoteRecall';
import { ExportMenuButton } from './ExportMenuButton';
import { ChatAmbientAurora } from './ChatAmbientAurora';
import { ThemeToggleButton } from './ThemeToggleButton';
import { LibraryConfirmationDialog } from './LibraryConfirmationDialog';
import { extractLibrarySourceMentions } from '../../lib/core/library/source-mentions';
import { isLibraryFeatureEnabled } from '../../lib/core/library/feature-flag';
import { resolveLibraryResearchRoute, resolveLibraryResearchUnavailableReason } from '../../lib/core/library/routing';
import {
  relayCapabilityEvidenceIdentity as resolveRelayCapabilityEvidenceIdentity,
  currentCapabilityEvidenceModel,
  resolveModelCapabilityEvidence,
} from '../../lib/core/chat/capability-evidence';
import { useCapabilityEvidenceExpiry } from '../../lib/core/chat/use-capability-evidence-expiry';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../lib/core/chat/stream-options';
import { capabilityControlIsConfigurable, capabilityControlReasonMessageKey, hasExactCapabilityTransportRecipe, presentCapabilityControl, webPreferenceReachesTheWire, type CapabilityControlPresentation } from '../../lib/core/chat/capability-control-presentation';
import { CUSTOM_FRAGMENT_SETTINGS_EVENT, customFragmentOwnerFacts, forwardPortCustomFragmentsIfNeeded } from '../../lib/core/chat/custom-fragment-settings';
import { CUSTOM_FRAGMENT_ERROR_KIND } from '../../lib/core/chat/custom-fragment-rejection';
import type { ReasoningIntent } from '@oriveo/core/providers/request-preference/types';
import { generationParameterProfileFingerprint } from '../../lib/core/chat/generation-parameter-settings';
import { capabilityRuntimeIdentity, displayCapabilityPreferences, loadCapabilityPreferenceDraft, saveCapabilityPreferenceDraft, saveCapabilityPreferences, withCapabilityReasoningIntent } from '../../lib/core/chat/capability-preference-settings';
import { capabilityRejectionIsDormant, invokeCapabilityRecoveryRetry } from '../../lib/core/chat/capability-recovery-runtime';
import { resolveChatCapabilityOutboundDecision } from '../../lib/core/chat/chat-capability-outbound-decision';
import { LibraryContextPicker } from './LibraryContextPicker';
import { resolveDirectMaxDocuments } from '../../lib/core/library/types';
import type { LibraryDocumentRef, LibraryProvider } from '../../lib/core/library/types';
import {
  selectionAskElapsedBucket,
  selectionAskTelemetryProperties,
} from '../../lib/core/chat/quote-telemetry';

interface ChatViewProps {
  conversationId?: string;
  searchQuery?: string;
}

/** Stable empty message array so an unresolved conversation does not mint a new reference every render. */
const EMPTY_MESSAGES: ChatMessage[] = [];

/**
 * The only two projection tables between reasoning intent and the enum. `off` and
 * "provider default" both collapse to `automatic` in `ReasoningMode`, which is exactly
 * why the enum alone cannot be the source of truth. Both directions are spelled out
 * here so no call site inlines its own copy.
 */
const REASONING_MODE_BY_INTENT: Record<string, ReasoningMode> = {
  low: 'fast', balanced: 'balanced', deep: 'deep', max: 'max', off: 'automatic',
};
const REASONING_INTENT_BY_MODE: Record<ReasoningMode, ReasoningIntent | undefined> = {
  automatic: undefined, fast: 'low', balanced: 'balanced', deep: 'deep', max: 'max',
};

export function ChatView({ conversationId, searchQuery }: ChatViewProps) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const t = useTranslations('pages.chat');
  const tSkills = useTranslations('skills');
  const tCommon = useTranslations('common');
  const tLibrary = useTranslations('library');
  const generationParameterDraftSessionId = useRef(`draft-${crypto.randomUUID()}`).current;
  const libraryFeatureEnabled = isLibraryFeatureEnabled();
  const { localizedName: localizedSkillName } = useSkillL10n();
  const [showSkillProviderPrompt, setShowSkillProviderPrompt] = useState(false);
  const focusMessageId = searchParams.get('focusMessageId');
  const fromNote = searchParams.get('fromNote');

  const providers = useAppStore((s) => s.providers);
  const account = useAppStore((s) => s.account);
  const libraryConnections = useAppStore((s) => s.libraryConnections);
	const libraryLoadState = useAppStore((s) => s.libraryLoadState);
  const libraryResearchEnabled = useAppStore((s) => s.libraryResearchEnabled);
  const setLibraryResearchEnabled = useAppStore((s) => s.setLibraryResearchEnabled);
  const setLibraryQuota = useAppStore((s) => s.setLibraryQuota);
  const libraryQuota = useAppStore((s) => s.libraryQuota);
  const activeConversationId = useAppStore((s) => s.activeConversationId);
  // Multi-conversation state: `isStreaming` must be read for `effectiveId`, not for any
  // stream (otherwise switching to B mid-stream and back to A shows B's partial text).
  // streamingText is deliberately *not* subscribed here: it changes every frame and
  // ChatView does not consume it, so subscribing would re-render the whole subtree for
  // every streamed token. Its only consumer, MessageList, reads it directly.
  const effectiveIdForSelectors = conversationId ?? activeConversationId ?? undefined;
  const isStreaming = useAppStore(selectIsStreamingFor(effectiveIdForSelectors));
  const syncState = useAppStore((s) => s.syncState);
  const notes = useAppStore((s) => s.notes);
  const setLastUsedModelRef = useAppStore((s) => s.setLastUsedModelRef);

  const sidebarOpen = useAppStore((s) => s.sidebarOpen);
  const setSidebarOpen = useAppStore((s) => s.setSidebarOpen);
  const memoryText = useAppStore((s) => s.preferences.memoryText);

  const [inputText, setInputText] = useState('');
  const [dismissedRelatedNoteIds, setDismissedRelatedNoteIds] = useState<string[]>([]);
  const [pendingPinnedNoteIds, setPendingPinnedNoteIds] = useState<string[]>([]);
  const [pendingQuoteContext, setPendingQuoteContext] = useState<QuoteContext | undefined>();
  const [quoteFocusSignal, setQuoteFocusSignal] = useState(0);
  const pendingQuoteAttachedAtRef = useRef<number | null>(null);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [libraryContextDocuments, setLibraryContextDocuments] = useState<LibraryDocumentRef[]>([]);
  const [showLibraryContextPicker, setShowLibraryContextPicker] = useState(false);
  const [showAttachmentSizeLimit, setShowAttachmentSizeLimit] = useState(false);
  const [reasoningMode, setReasoningMode] = useState<ReasoningMode>('automatic');
  /**
   * The single source of truth for reasoning intent. `ReasoningMode` cannot express
   * `off` or `low`, so driving the UI from the enum produces "tapped off but it shows
   * provider default, and tapping automatic is a silent no-op" - off has no slot in the
   * enum and gets folded back into automatic. `reasoningMode` is kept only as the
   * projection used by legacy outbound requests and the tier picker.
   */
  const [reasoningIntent, setReasoningIntent] = useState<ReasoningIntent | undefined>(undefined);
  const [webSearchEnabled, setWebSearchEnabled] = useState<boolean>(false);

  // ── Resolve conversation ──
  const effectiveId = conversationId ?? activeConversationId;
  const conversation = useAppStore((s) =>
    s.conversations.find((c) => sameNormalizedID(c.id, effectiveId)),
  );
  const conversationUseMemory = conversation?.useMemory;

  const {
    loadState,
    retryHydration,
    shouldShowConversationBootstrap,
    isComposerBlocked,
  } = useConversationHydration(effectiveId, conversation);

  // Skill attached to the current conversation
  const skillId = conversation?.skillId;
  const catalogSkills = useAppStore((s) => s.catalogSkills);
  const userSkills = useAppStore((s) => s.userSkills);
  const currentSkill = useMemo(
    () => skillId ? getSkillById(getVanillaStore(), skillId) : undefined,
    [skillId, catalogSkills, userSkills],
  );

  const isDesktop = useMediaQuery('(min-width: 1024px)');

  const { expensiveModelHint, evaluateExpensiveHint, clearExpensiveHint } = useExpensiveModelHint();

  // ── Resolve active provider and model + model selection handlers ──
  const {
    provider,
    currentModel,
    setSelectedModelId,
    setSelectedProviderId,
    showModelSwitcher,
    setShowModelSwitcher,
    handleModelSelect,
    handleEnableAndSelect,
    handleAddManualAndSelect,
    handleSwitchModel,
    handleToggleModelSwitcher,
  } = useChatModelSelection({
    runtimeProviders: providers,
    conversation,
    providers,
    evaluateExpensiveHint,
  });

  const providerAttachmentSupport = useMemo(() => (
    provider?.kind === 'relay'
      ? resolveRelayAttachmentSupport(provider, getRelayRuntimeConfig())
      : provider?.kind
        ? getProviderAttachmentSupport(provider.kind)
        : null
  ), [currentModel, provider]);

  const canAcceptDropped = useCallback(
    (attachment: Attachment) =>
      canAcceptDroppedAttachment(attachment, provider, currentModel, providerAttachmentSupport),
    [currentModel, provider, providerAttachmentSupport],
  );

  // ── Drag & Drop + Global Paste ──
  const handleFilesAccepted = useCallback((newAtts: Attachment[]) => {
    setAttachments((prev) => [...prev, ...newAtts]);
  }, []);
  const handleOversizedFiles = useCallback(() => {
    setShowAttachmentSizeLimit(true);
  }, []);
  const attachmentFilePolicy = useMemo<AttachmentFilePolicy | undefined>(() => undefined, [provider?.kind, currentModel]);
  const attachmentLimitDialogCopy: any = undefined;
  const { dragActive, dragHandlers } = useAttachmentDragDrop(
    handleFilesAccepted,
    handleOversizedFiles,
    {
      enabled: Boolean(provider && currentModel),
      canAcceptAttachment: canAcceptDropped,
      providerKind: telemetryProviderKind(provider?.kind),
      existingAttachments: attachments,
      attachmentFilePolicy,
    },
  );

  // Reuse one empty-array constant when there is no conversation: `?? []` mints a new
  // reference every render, which flows through useStreamChat's deps and turns retry/send
  // into new functions, defeating the message list's memoization.
  const messages = conversation?.messages ?? EMPTY_MESSAGES;
  // Empty conversation: full-strength aurora and a transparent top bar so the glow runs through (same condition as MessageList areaEmpty).
  const isEmptyChat = messages.length === 0 && !isStreaming;
  const showHomeComposer =
    isEmptyChat &&
    !shouldShowConversationBootstrap &&
    !currentSkill;
  // Capability evidence is metadata-backed; subscribing here keeps the
  // facade-derived composer controls in step with an arriving snapshot.
  const metadataVersion = useSyncExternalStore(
    onVersionChange,
    getCachedMetadataVersion,
    () => 0,
  );
  /**
   * Change signal for locally defined custom request fields. The editor persists and
   * broadcasts on every keystroke, and the chip's globe test (the custom branch of the
   * liveness check) has to recompute with it - otherwise enabling custom web access in
   * the editor leaves the globe dark until the next model switch.
   */
  const [customFragmentSettingsVersion, setCustomFragmentSettingsVersion] = useState(0);
  useEffect(() => {
    const bump = () => setCustomFragmentSettingsVersion((version) => version + 1);
    window.addEventListener(CUSTOM_FRAGMENT_SETTINGS_EVENT, bump);
    return () => window.removeEventListener(CUSTOM_FRAGMENT_SETTINGS_EVENT, bump);
  }, []);
  // Evidence is scoped to the production dispatch route, not model.transport.
  // This is the exact normal-chat intent; specialised sends build and pass their
  // own options at their request boundary.
  const capabilityEvidenceStreamOptions = useMemo(
    () => provider && currentModel
      ? buildProviderStreamOptions(
          provider,
          buildStreamOptionsFromIntent(currentModel, reasoningMode, false),
          currentModel,
        )
      : undefined,
    [currentModel, provider, reasoningMode],
  );
  const currentEvidenceModel = useMemo(
    () => provider && currentModel ? currentCapabilityEvidenceModel(provider, currentModel) : currentModel,
    [currentModel, metadataVersion, provider],
  );
  const capabilityEvidenceClock = useCapabilityEvidenceExpiry(
    provider,
    currentModel,
    capabilityEvidenceStreamOptions,
  );
  // Entry visibility is not a legacy profile or evidence verdict.
  // All chat models keep Web / Reasoning / Model Behavior visible; the exact
  // v2 control merely tells us whether automatic configuration is available.
  const webControl = useMemo(() => presentCapabilityControl(provider, currentModel, 'web'), [metadataVersion, provider, currentModel]);
  const reasoningControl = useMemo(() => presentCapabilityControl(provider, currentModel, 'reasoning'), [metadataVersion, provider, currentModel]);
  const generationControl = useMemo(() => presentCapabilityControl(provider, currentModel, 'generation'), [metadataVersion, provider, currentModel]);
  // Panel status copy is not pre-translated here: shape and wording are decided together
  // from state + reasonCode by the pure helpers in `model-control-capability-layout`
  // (`capabilityControlReasonMessageKey` is still used by the model list badges).
  const controlsManagedByOriveo = false;
  const capabilityPreferenceIdentity = useMemo(
    () => provider && currentModel ? capabilityRuntimeIdentity(provider, currentModel) : null,
    [metadataVersion, provider, currentModel],
  );
  // A missing identity no longer backfills a read-only reason here: an empty
  // `capabilityPreferenceIdentity` means the panel's `transportIdentity` is empty too, and
  // `resolveModelControlsEditability` settles on `runtimeIdentityUnavailable` *before* it
  // ever evaluates runtimeReadOnly. The panel derives that state's reason from identityGap
  // itself (each of the three gaps has a different recovery action), so a generic
  // "unavailable" string here is either never read or overwrites a more precise one.
  // For unknown / unavailable / custom_only the actionable primary step is switching to a
  // model on the same connection where auto configuration really works. Candidates come
  // from enabled models (provider.models) only - a catalog model would first have to be
  // enabled, which turns the panel into a second dead end.
  // Only scan for the capability that actually degraded; auto_available / managed_only
  // do not need the pass.
  const capabilityAlternativeModels = useMemo(() => {
    const collect = (
      capability: 'web' | 'reasoning' | 'generation',
      control: { state: string },
    ): AIModel[] => (
      provider && !controlsManagedByOriveo && control.state !== 'auto_available' && control.state !== 'managed_only'
        ? provider.models.filter((model) => model.id !== currentModel?.id
          && presentCapabilityControl(provider, model, capability).state === 'auto_available'
          // The candidate's own recipe must be written for this transport. Without this
          // check the user switches over and still compiles no automatic fields (outbound
          // drops the whole thing as `transport_mismatch`), turning the list into a second
          // dead end when it is meant to be the way out of the unavailable state.
          && hasExactCapabilityTransportRecipe(provider, model, capability))
        : []
    );
    return {
      web: collect('web', webControl),
      reasoning: collect('reasoning', reasoningControl),
      generation: collect('generation', generationControl),
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- metadataVersion is the change signal for the
    // metadata snapshot; presentCapabilityControl reads from that same snapshot on demand
  }, [controlsManagedByOriveo, currentModel, generationControl, metadataVersion, provider, reasoningControl, webControl]);
  const handleSelectAlternativeModel = useCallback((model: AIModel) => {
    if (!provider) return;
    handleModelSelect(model, provider);
  }, [handleModelSelect, provider]);
  // Primary action for the "not adjustable" row. capabilityAlternativeModels above is
  // computed per capability (web/reasoning/generation) as a whole and cannot answer
  // "which models support top_p", so this opens the model picker with an extra filter
  // dimension for "supports this parameter" (same predicate as
  // modelSupportsGenerationParameter) instead of listing candidates inside the panel.
  const [switcherRequiredParameterId, setSwitcherRequiredParameterId] = useState<string | undefined>(undefined);
  // Clear this filter dimension as soon as the picker closes. Hanging it on the closed
  // state rather than on each dismissal path: picking a model, tapping the scrim and
  // tapping the model name again all close it, and clearing per path is bound to miss one,
  // leaving the next open still filtered and looking as if models had disappeared.
  useEffect(() => {
    if (!showModelSwitcher) setSwitcherRequiredParameterId(undefined);
  }, [showModelSwitcher]);
  const handleFindModelsSupportingParameter = useCallback((parameterId: string) => {
    setSwitcherRequiredParameterId(parameterId);
    setShowModelSwitcher(true);
  }, [setShowModelSwitcher]);
  const [webPreference, setWebPreference] = useState<'off' | 'automatic' | 'force'>('off');

  /**
   * The web intent currently expressed in storage plus whether it can reach the wire -
   * one reading shared by the restore path and by the reset after a mutual exclusion is
   * lifted. The second call site (library document detached / scoped research turned off)
   * had no reading at all before: once exclusion forced `webSearchEnabled` to false
   * nothing read it back, so the globe stayed dark after detaching a document even though
   * the stored `automatic` never changed. Two copies would drift, so there is only one.
   */
  const readStoredWebIntent = useCallback((): {
    values: { web: 'off' | 'automatic' | 'force'; reasoningIntent?: ReasoningIntent };
    reachesTheWire: boolean;
  } => {
    if (!provider || !currentModel) return { values: { web: 'off' }, reachesTheWire: false };
    const identity = capabilityRuntimeIdentity(provider, currentModel);
    // Reading follows the same ladder as sending, and the display layer does no final
    // collapsing: `resolveCapabilityPreferences` folds `provider_default` into a single
    // value for the outbound compiler, so copying it would render "never set" as a user
    // choice. `displayCapabilityPreferences` only answers which layer first really stored a value.
    const values = identity
      ? loadCapabilityPreferenceDraft(!effectiveId ? generationParameterDraftSessionId : undefined, identity)
        ?? displayCapabilityPreferences({ ...identity, conversationId: effectiveId ?? undefined })
      : { web: 'off' as const };
    return {
      values,
      // `web !== 'off'` only means the user expressed something. When this metadata has no
      // official web configuration and no custom fields take over, the preference compiles
      // to nothing - storage is left alone (switching back to a capable model restores it),
      // the globe is simply not lit for a request that will not go out.
      reachesTheWire: values.web !== 'off' && webPreferenceReachesTheWire({
        provider, model: currentModel, ...(identity ? { transportIdentity: identity.transportIdentity } : {}),
      }),
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- metadataVersion is the change signal for identity/liveness
  }, [currentModel, effectiveId, generationParameterDraftSessionId, metadataVersion, provider]);

  useEffect(() => {
    if (!provider || !currentModel) return;
    const identity = capabilityRuntimeIdentity(provider, currentModel);
    // Restore is a discrete event (model switch / conversation switch / new metadata).
    // Typed preferences are migrated forward by their own read path; local custom fields
    // have no such path, so run it explicitly here.
    if (identity) {
      forwardPortCustomFragmentsIfNeeded({
        provider, model: currentModel, transportIdentity: identity.transportIdentity,
      });
    }
    const { values, reachesTheWire } = readStoredWebIntent();
    setWebSearchEnabled(reachesTheWire);
    setWebPreference(values.web);
    // Restore reads the intent, the single source of truth; `reasoningMode` is only its
    // projection, where off and "provider default" both land on automatic.
    setReasoningIntent(values.reasoningIntent);
    setReasoningMode(REASONING_MODE_BY_INTENT[values.reasoningIntent ?? ''] ?? 'automatic');
    // metadataVersion is an input to this restore as well: identity and liveness both need
    // the snapshot to be complete. On a cold start the snapshot has not arrived yet and the
    // pass can only read "nothing configured"; without recomputing on it the preference
    // would not come back until a model or conversation switch. Writes are idempotent
    // (what is read back is what was just written), so re-running is safe.
  }, [currentModel, effectiveId, generationParameterDraftSessionId, metadataVersion, provider, readStoredWebIntent]);

  const activeLibraryConnection = useMemo(
    () => libraryConnections.some((connection) => connection.status === 'active'),
    [libraryConnections],
  );
  const activeLibrarySources = useMemo(
    () => [...new Set(
      libraryConnections
        .filter((connection) => connection.status === 'active')
        .map((connection) => connection.provider),
    )] as LibraryProvider[],
    [libraryConnections],
  );
  /**
   * Which retrieval path a request takes (agent-driven multi-step, server-side retrieval,
   * or neither).
   *
   * The decision lives in core/library/routing and is shared with the send path - a
   * separate copy in the UI ends up with "the button is lit but sending took another path".
   */
  // The verdict changes as metadata arrives (without a snapshot libraryAgentic /
  // transport / serverResearchEnabled are all undefined), so the subscription above also
  // drives the route recomputation here.
  const relayCapabilityEvidenceIdentity = useMemo(() => {
    return provider && currentModel
      ? resolveRelayCapabilityEvidenceIdentity(provider, currentModel, capabilityEvidenceStreamOptions)
      : undefined;
  }, [account, capabilityEvidenceStreamOptions, currentModel, provider]);
  // The feature switch is not re-checked here: resolveLibraryResearchRoute queries
  // isLibraryFeatureEnabled() on its first line, and only it can tell a build-time
  // disable (a local, certain fact) from a backend `enabled=false` (possibly a stale
  // cached config, not a negative conclusion until confirmed this session).
  // Short-circuiting to 'none' out here would bypass that confirmation entirely.
  const libraryResearchRoute = useMemo(
    () => resolveLibraryResearchRoute(
      provider,
      currentModel,
      getLibraryRuntimeConfig(),
      activeLibraryConnection,
      undefined,
      undefined,
      relayCapabilityEvidenceIdentity,
    ),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- metadataVersion is the change signal for the
    // metadata snapshot; getLibraryRuntimeConfig() / isMetadataReady() read from it on demand
    [activeLibraryConnection, currentModel, libraryFeatureEnabled, provider, metadataVersion, relayCapabilityEvidenceIdentity],
  );
  // pending = this snapshot cannot answer, usually because a newly synced model is not in
  // the cached copy. Fetch a fresh one: initMetadata only refreshes in the background on a
  // cache hit, and waiting for expiry takes 24h.
  //
  // The force-refresh bookkeeping has to be keyed by provider+model rather than a single
  // boolean. A boolean means "one chance per component lifetime", so switching to a second
  // unlisted model in the same session settles straight to none without a refresh and the
  // user is told the current model has no automatic retrieval. Switching the pair grants a
  // new chance; the same pair never refreshes twice.
  const libraryPendingKey = `${provider?.id ?? ''}:${currentModel?.id ?? ''}`;
  const [libraryRefreshedPendingKey, setLibraryRefreshedPendingKey] = useState<string | null>(null);
  useEffect(() => {
    if (libraryResearchRoute !== 'pending') return;
    if (libraryRefreshedPendingKey === libraryPendingKey) return;
    void refreshMetadata().finally(() => setLibraryRefreshedPendingKey(libraryPendingKey));
  }, [libraryResearchRoute, libraryPendingKey, libraryRefreshedPendingKey]);
  // Still pending after one refresh means it really is not in the catalog, so present it
  // as unavailable rather than leaving the copy at "confirming" forever.
  const libraryDisplayRoute =
    libraryResearchRoute === 'pending' && libraryRefreshedPendingKey === libraryPendingKey
      ? 'none'
      : libraryResearchRoute;
  // pending counts as available: greying out the entry while undecided makes the feature
  // vanish for a moment even though it is about to come back. serverSide is only set once
  // the server path is certain - while pending it would wrongly claim retrieval happens on
  // the Oriveo server.
  const libraryResearchAvailable = libraryDisplayRoute !== 'none';
  const libraryResearchServerSide = libraryDisplayRoute === 'server';
  const libraryResearchPending = libraryDisplayRoute === 'pending';
  // A specific reason is only needed once unavailability is certain (not pending),
  // otherwise pending gets misreported as a definite reason. Shares the metadataVersion
  // dependency so both recompute together.
  const libraryResearchUnavailableReason = useMemo(
    () =>
      libraryDisplayRoute === 'none'
        ? resolveLibraryResearchUnavailableReason(
            provider,
            currentModel,
            getLibraryRuntimeConfig(),
            activeLibraryConnection,
            undefined,
            undefined,
            relayCapabilityEvidenceIdentity,
          )
        : undefined,
    // eslint-disable-next-line react-hooks/exhaustive-deps -- as with libraryResearchRoute, metadataVersion is the change signal
    [activeLibraryConnection, currentModel, libraryDisplayRoute, provider, metadataVersion, relayCapabilityEvidenceIdentity],
  );

  const effectiveLibraryResearchEnabled =
    libraryFeatureEnabled && libraryResearchEnabled;

  useEffect(() => {
    if (libraryResearchEnabled && (!libraryFeatureEnabled || !activeLibraryConnection || !libraryResearchAvailable || !account)) {
      setLibraryResearchEnabled(false);
    }
  }, [account, activeLibraryConnection, libraryResearchAvailable, libraryFeatureEnabled, libraryResearchEnabled, setLibraryResearchEnabled]);

  const capabilityRecoveryIdentity = capabilityEvidenceStreamOptions?.capabilityRecoveryIdentity;
  const webRuntimeRejected = capabilityRecoveryIdentity
    ? capabilityRejectionIsDormant(capabilityRecoveryIdentity, 'web', 'provider_recipe')
    : false;
  const reasoningRuntimeRejected = capabilityRecoveryIdentity
    ? capabilityRejectionIsDormant(capabilityRecoveryIdentity, 'reasoning', 'provider_recipe')
    : false;
  /**
   * Whether custom web fields are taking over this request right now. The chip's globe
   * test has to account for it: web access enabled through custom JSON reaches the wire
   * just the same, and missing this leaves the user with a dark globe next to an answer
   * that really did search the web. Facts come from the same `customFragmentOwnerFacts`
   * the outbound gate uses, not a second predicate.
   */
  const webCustomIsActive = useMemo(() => (
    provider && currentModel && capabilityPreferenceIdentity
      ? customFragmentOwnerFacts({
        provider, model: currentModel,
        transportIdentity: capabilityPreferenceIdentity.transportIdentity, owner: 'web',
      }).isActive
      : false
    // eslint-disable-next-line react-hooks/exhaustive-deps -- customFragmentSettingsVersion is the change signal
    // for local custom configuration (the editor broadcasts on every keystroke); the facts themselves are read from that same store on demand
  ), [capabilityPreferenceIdentity, currentModel, customFragmentSettingsVersion, provider]);
  const capabilityOutboundDecision = resolveChatCapabilityOutboundDecision({
    webRequested: webSearchEnabled && !effectiveLibraryResearchEnabled,
    webControl,
    webCustomIsActive,
    webDormant: webRuntimeRejected,
    reasoningModeRequested: reasoningMode,
    ...(reasoningIntent ? { reasoningIntentRequested: reasoningIntent } : {}),
    reasoningControl,
    reasoningDormant: reasoningRuntimeRejected,
  });
  // One decision object drives both the chip and the actual send: a local dormant state or a reverse intent gate no longer only closes the wire.
  const effectiveWebSearchEnabled = !controlsManagedByOriveo && capabilityOutboundDecision.webSearchEnabled;

  const recalledNotes = useRelatedNoteRecall(inputText, notes);
  const relatedNotes = useMemo(() => {
    const pinnedIds = conversation?.pinnedNoteIds ?? [];
    return recalledNotes
      .filter((result) =>
        !dismissedRelatedNoteIds.some((id) => sameNormalizedID(id, result.note.id)) &&
        !pendingPinnedNoteIds.some((id) => sameNormalizedID(id, result.note.id)) &&
        !pinnedIds.some((id) => sameNormalizedID(id, result.note.id)),
      )
      .map((result) => ({
        id: result.note.id,
        title: result.note.title.trim() || t('savedNoteUntitled'),
        score: result.score,
        sourceLabel: [result.note.sourceProviderName, result.note.sourceModelName]
          .filter((value): value is string => Boolean(value?.trim()))
          .join(' - '),
      }));
  }, [conversation?.pinnedNoteIds, dismissedRelatedNoteIds, pendingPinnedNoteIds, recalledNotes, t]);

  // Notes already pinned as context (conversation-level pinnedNoteIds plus compose-state
  // pendingPinnedNoteIds, deduplicated), shown as chips above the input: an honest view of
  // what is injected on every turn, removable in one tap.
  const attachedNotes = useMemo(() => {
    const ids = [...(conversation?.pinnedNoteIds ?? []), ...pendingPinnedNoteIds];
    const result: AttachedNoteRef[] = [];
    for (const id of ids) {
      if (result.some((item) => sameNormalizedID(item.id, id))) continue;
      const note = notes.find((candidate) => sameNormalizedID(candidate.id, id) && !candidate.deletedAt);
      if (!note) continue;
      result.push({
        id: note.id,
        title: note.title.trim() || t('savedNoteUntitled'),
        // Truncate to 2000 chars before stripping so a very long note does not run the full
        // regex; unclosed fences are handled by the clipboard strip. The clipboard variant
        // keeps code and line breaks (the preview card is pre-wrap + line-clamp), then trim to 280.
        bodyPreview: stripMarkdownForClipboard((note.body || note.bodySnapshot || '').slice(0, 2000))
          .replace(/\n{2,}/g, '\n')
          .slice(0, 280) || undefined,
        sourceLabel: note.sourceModelName?.trim() || note.sourceProviderName?.trim() || undefined,
        createdAt: note.createdAt,
      });
    }
    return result;
  }, [conversation?.pinnedNoteIds, pendingPinnedNoteIds, notes, t]);

  const savedNoteRefsByMessageId = useMemo(() => {
    if (!conversation?.id) return undefined;
    const refsByMessageId: Record<string, Array<{ id: string; title: string }>> = {};
    for (const note of notes) {
      if (note.deletedAt || !note.sourceMessageId) continue;
      if (!note.sourceConversationId || !sameNormalizedID(note.sourceConversationId, conversation.id)) continue;
      const key = normalizeUUID(note.sourceMessageId);
      const refs = refsByMessageId[key] ?? [];
      refs.push({
        id: note.id,
        title: note.title.trim() || t('savedNoteUntitled'),
      });
      refsByMessageId[key] = refs;
    }
    return Object.keys(refsByMessageId).length > 0 ? refsByMessageId : undefined;
  }, [conversation?.id, notes, t]);

  const replaceCurrentNoteId = useMemo(() => {
    if (!fromNote) return null;
    return notes.some((note) => !note.deletedAt && sameNormalizedID(note.id, fromNote))
      ? fromNote
      : null;
  }, [fromNote, notes]);

  // ── Stream Chat Hook ──
  const { send, continueAnswering, retry, editAndResend, stop } = useStreamChat({
    provider,
    currentModel,
    conversation,
    messages,
    reasoningMode,
    webSearchEnabled: effectiveWebSearchEnabled,
    libraryResearchEnabled: effectiveLibraryResearchEnabled && activeLibraryConnection && libraryResearchAvailable,
    generationParameterDraftSessionId,
    onSendFailed: setInputText,
    onLibraryContextFailed: libraryFeatureEnabled ? setLibraryContextDocuments : undefined,
  });

  /**
   * Retry without custom fields.
   *
   * Must be a stable reference: it is threaded down to every `MessageListItem` (memo) and
   * `MessageBubble` (memo), and a new function each render fails their shallow compares -
   * so typing (`inputText` state) and streaming (rAF writing `streamingTexts` every frame)
   * would re-render every bubble. The failed message is looked up from the store rather
   * than captured from `messages` so the deps stay down to what actually affects behavior.
   */
  const handleRetryWithoutCustom = useCallback((messageId: string) => {
    const failed = getVanillaStore().getState()
      .conversations.find((candidate) => sameNormalizedID(candidate.id, effectiveId))
      ?.messages.find((message) => message.id === messageId);
    // Custom fields fail closed: the request was rejected at compile time, so there is no
    // recovery descriptor to consult (those exist only when upstream rejected an applied
    // setting). The way out is to resend once without the custom fields.
    if (failed?.errorKind === CUSTOM_FRAGMENT_ERROR_KIND) {
      void retry(messageId, { excludeCustomFragments: true });
      return;
    }
    const recovery = failed?.capabilityRecovery;
    const currentIdentity = provider && currentModel
      ? capabilityRuntimeIdentity(provider, currentModel)
      : null;
    if (!currentIdentity || !recovery) return;
    invokeCapabilityRecoveryRetry({
      connectionId: currentIdentity.providerId,
      canonicalModelId: currentIdentity.canonicalModelId,
      finalTransport: currentIdentity.finalTransport,
      runtimeRevision: currentIdentity.runtimeRevision,
    }, recovery, (options) => {
      void retry(messageId, options);
    });
  }, [effectiveId, retry, provider, currentModel]);

  const handleLibraryContextOpen = useCallback(() => {
    if (!libraryFeatureEnabled) return;
    if (activeLibrarySources.length === 0) {
      showToast(tLibrary('connectRequired'), 5000, undefined, 'warning');
      return;
    }
    setShowLibraryContextPicker(true);
  }, [account, activeLibrarySources.length, libraryFeatureEnabled, router, tLibrary]);

  /**
   * Mutual exclusion between library context and web access - view state only, nothing is
   * persisted.
   *
   * Exclusion decides which evidence this one request carries; it is not the user's
   * expressed setting for the connection. It is enforced on the outbound side, where
   * `operations-send` forces `singleSend: { web: 'off' }` for both attached documents and
   * server-side retrieval, while the panel keeps showing the stored value. Persisting it
   * through `handleWebPreferenceChange('off')` used to wipe the user's web preference to
   * `off` the first time a document was attached, and detaching it did not bring the
   * preference back - a temporary scope choice permanently rewrote their default.
   */
  const handleLibraryContextChange = useCallback((documents: LibraryDocumentRef[]) => {
    setLibraryContextDocuments(documents);
    if (documents.length > 0) {
      setLibraryResearchEnabled(false);
      setWebSearchEnabled(false);
      return;
    }
    // Detaching every document lifts the exclusion, so view state returns to the stored
    // preference. Nothing is reset while scoped research is still on, since that exclusion still stands.
    if (!libraryResearchEnabled) setWebSearchEnabled(readStoredWebIntent().reachesTheWire);
  }, [libraryResearchEnabled, readStoredWebIntent, setLibraryResearchEnabled]);

  const handleWebPreferenceChange = useCallback((next: 'off' | 'automatic' | 'force') => {
    const input = capabilityPreferenceIdentity;
    if (!input) return;
    setWebPreference(next);
    setWebSearchEnabled(next !== 'off');
    if (next !== 'off') {
      setLibraryResearchEnabled(false);
      setLibraryContextDocuments([]);
    }
    const previous = displayCapabilityPreferences({ ...input, conversationId: effectiveId ?? undefined });
    if (!effectiveId) saveCapabilityPreferenceDraft(generationParameterDraftSessionId, input, { ...previous, web: next });
    else saveCapabilityPreferences({ ...input, scope: 'conversation_connection_model', conversationId: effectiveId }, { ...previous, web: next });
  }, [capabilityPreferenceIdentity, effectiveId, generationParameterDraftSessionId, setLibraryResearchEnabled]);

  /**
   * Scoped-research toggle inside the panel. It no longer opens the entry point: the
   * guards (signed out / not connected) all moved up into handleLibraryContextOpen, and an
   * unsupported model greys the toggle out in place rather than silently navigating away.
   */
  const handleLibraryResearchToggle = useCallback((next: boolean) => {
    if (!libraryFeatureEnabled) return;
    if (!next) {
      setLibraryResearchEnabled(false);
      // Turning scoped research off lifts the exclusion, so view state returns to the stored preference, unless documents are still attached.
      if (libraryContextDocuments.length === 0) setWebSearchEnabled(readStoredWebIntent().reachesTheWire);
      return;
    }
    if (!account || !activeLibraryConnection || !libraryResearchAvailable) return;
    setLibraryContextDocuments([]);
    // Same rule as attaching a document: exclusion only changes view state and does not go
    // through the persisting `handleWebPreferenceChange` path. Outbound, `operations-send`
    // forces `singleSend: { web: 'off' }` for both server-side retrieval and named
    // documents, while the panel keeps showing the stored value.
    setWebSearchEnabled(false);
    setLibraryResearchEnabled(true);
	}, [account, activeLibraryConnection, libraryContextDocuments.length, libraryResearchAvailable, libraryFeatureEnabled, readStoredWebIntent, setLibraryResearchEnabled]);

  // ── Handlers ──
  const handleSend = useCallback(async (overrideText?: string) => {
    const text = (overrideText ?? inputText).trim();
    if (!text || !provider || !currentModel) return;
    const currentAttachments = overrideText ? [] : [...attachments];
    const currentPendingPinnedNoteIds = overrideText ? [] : [...pendingPinnedNoteIds];
    const currentQuoteContext = overrideText ? undefined : pendingQuoteContext;
    const currentQuoteAttachedAt = pendingQuoteAttachedAtRef.current;
    const currentLibraryContextDocuments =
      libraryFeatureEnabled && !overrideText ? [...libraryContextDocuments] : [];
    const explicitLibrarySources = libraryFeatureEnabled
      ? extractLibrarySourceMentions(text)
      : [];
    if (explicitLibrarySources.length > 0 && currentLibraryContextDocuments.length === 0) {
      if (!account) {
        // A guest has no library connection and no scope toggle to flip (the toggle is a
        // no-op for guests). Use the same prompt as "signed in but this source is not
        // connected", otherwise sending clears the input with no feedback at all.
        showToast(tLibrary('connectRequired'), 5000, undefined, 'warning');
        return;
      }
      const connectedSources = new Set(
        libraryConnections
          .filter((connection) => connection.status === 'active')
          .map((connection) => connection.provider),
      );
      if (explicitLibrarySources.some((source) => !connectedSources.has(source))) {
        showToast(tLibrary('connectRequired'), 5000, undefined, 'warning');
        return;
      }
      if (!libraryResearchAvailable) {
        handleLibraryContextOpen();
        return;
      }
    }
    if (!overrideText) setInputText('');
    clearExpensiveHint();
    if (!overrideText) setAttachments([]);
    if (!overrideText) setPendingPinnedNoteIds([]);
    if (!overrideText) setLibraryContextDocuments([]);
    if (!overrideText && currentQuoteContext) {
      setPendingQuoteContext(undefined);
      pendingQuoteAttachedAtRef.current = null;
    }
    try {
      if (currentQuoteContext) {
        await send(
          text,
          messages,
          conversation,
          currentAttachments,
          currentPendingPinnedNoteIds,
          currentLibraryContextDocuments,
          currentQuoteContext,
        );
      } else {
        await send(
          text,
          messages,
          conversation,
          currentAttachments,
          currentPendingPinnedNoteIds,
          currentLibraryContextDocuments,
        );
      }
      if (currentQuoteContext) {
        trackEvent('selection_ask_sent', {
          ...selectionAskTelemetryProperties(currentQuoteContext),
          elapsed_bucket: selectionAskElapsedBucket(Date.now() - (currentQuoteAttachedAt ?? Date.now())),
        });
      }
    } catch {
      // The request threw before the send path accepted it (a failed dynamic import, for example): restore the pending reference.
      if (!overrideText && currentQuoteContext) {
        setPendingQuoteContext(currentQuoteContext);
        pendingQuoteAttachedAtRef.current = currentQuoteAttachedAt ?? Date.now();
      }
      return;
    }
  }, [
    attachments,
    account,
    clearExpensiveHint,
    conversation,
    currentModel,
    effectiveId,
    inputText,
    handleLibraryContextOpen,
    libraryResearchAvailable,
    libraryConnections,
    libraryContextDocuments,
    libraryFeatureEnabled,
    messages,
    pendingPinnedNoteIds,
    pendingQuoteContext,
    provider,
    router,
    send,
    setLastUsedModelRef,
    tLibrary,
  ]);

  const handleAskSelection = useCallback((quoteContext: QuoteContext) => {
    setPendingQuoteContext(quoteContext);
    pendingQuoteAttachedAtRef.current = Date.now();
    setQuoteFocusSignal((current) => current + 1);
    trackEvent('selection_ask_attached', selectionAskTelemetryProperties(quoteContext));
  }, []);

  const handleRemoveQuote = useCallback(() => {
    setPendingQuoteContext((current) => {
      if (current) trackEvent('selection_ask_removed', selectionAskTelemetryProperties(current));
      return undefined;
    });
    pendingQuoteAttachedAtRef.current = null;
  }, []);

  const handleDetachLibraryContext = useCallback((document: LibraryDocumentRef) => {
    setLibraryContextDocuments((current) => current.filter((candidate) =>
      candidate.source !== document.source || candidate.docId !== document.docId));
  }, []);

  const handleAttachRelatedNote = useCallback((noteId: string) => {
    const targetConversationId = conversation?.id ?? effectiveId;
    if (!targetConversationId) {
      setPendingPinnedNoteIds((current) => {
        if (current.some((id) => sameNormalizedID(id, noteId))) return current;
        return [...current, noteId].slice(-3);
      });
      setDismissedRelatedNoteIds((current) => current.some((id) => sameNormalizedID(id, noteId)) ? current : [...current, noteId]);
      showToast(t('noteAttachedToContext'), 2500, undefined, 'success');
      return;
    }
    const attached = pinNoteToConversation(getVanillaStore(), targetConversationId, noteId);
    if (attached) {
      setDismissedRelatedNoteIds((current) => [...current, noteId]);
      showToast(t('noteAttachedToContext'), 2500, undefined, 'success');
    }
  }, [conversation?.id, effectiveId, t]);

  const handleDismissRelatedNote = useCallback((noteId: string) => {
    setDismissedRelatedNoteIds((current) => current.some((id) => sameNormalizedID(id, noteId)) ? current : [...current, noteId]);
  }, []);

  // Detach a pinned context note: conversation-level -> unpin, compose-state -> drop from
  // pending. Also marks it dismissed so related-note matching does not immediately suggest it again.
  const handleDetachNote = useCallback((noteId: string) => {
    const targetConversationId = conversation?.id ?? effectiveId;
    if (targetConversationId) {
      unpinNoteFromConversation(getVanillaStore(), targetConversationId, noteId);
    }
    setPendingPinnedNoteIds((current) => current.filter((id) => !sameNormalizedID(id, noteId)));
    setDismissedRelatedNoteIds((current) => current.some((id) => sameNormalizedID(id, noteId)) ? current : [...current, noteId]);
  }, [conversation?.id, effectiveId]);

  // Skill tapped in SkillsLanding: create a draft conversation carrying the skillId and navigate to it.
  const handleSkillSelectFromLanding = useCallback((skill: NonNullable<typeof currentSkill>) => {
    const store = getVanillaStore();
    const result = startConversationWithSkill(store, skill, {
      title: localizedSkillName(skill),
    });
    if (result.kind === 'no-provider') {
      showToast(tSkills('needProvider'));
      setShowSkillProviderPrompt(true);
      return;
    }
    setSelectedProviderId(null);
    setSelectedModelId(null);
    markNewConversationRoutePromotion(result.conversationId);
    router.replace(`/chat/${result.conversationId}`);
  }, [router, tSkills, localizedSkillName]);

  // Starter prompt tapped in SkillsLanding: create a draft conversation carrying the skillId
  // and prefill the input. ChatView does not unmount (only the route changes), so inputText survives.
  const handleSkillStarterPromptFromLanding = useCallback(
    (skill: NonNullable<typeof currentSkill>, message: string) => {
      const store = getVanillaStore();
      const result = startConversationWithSkill(store, skill, {
        title: localizedSkillName(skill),
      });
      if (result.kind === 'no-provider') {
        showToast(tSkills('needProvider'));
        setShowSkillProviderPrompt(true);
        return;
      }
      setSelectedProviderId(null);
      setSelectedModelId(null);
      setInputText(message);
      markNewConversationRoutePromotion(result.conversationId);
      router.replace(`/chat/${result.conversationId}`);
    },
    [router, tSkills, localizedSkillName],
  );

  // Reasoning tier analytics: intercept the setReasoningMode call
  const handleReasoningModeChange = useCallback((next: ReasoningMode) => {
    const nextIntent = REASONING_INTENT_BY_MODE[next];
    // The early return has to compare both the enum and the intent: going from off back to
    // provider default leaves the enum at automatic either way, so comparing only the enum
    // is a permanently silent no-op and the user can never leave off.
    if (next === reasoningMode && nextIntent === reasoningIntent) return;
    const identity = capabilityPreferenceIdentity;
    if (!identity) return;
    trackEvent('reasoning_mode_changed', {
      from_mode: reasoningIntent === 'off' ? 'off' : reasoningMode,
      to_mode: next,
      model_id: telemetryModelID(provider?.kind, currentModel?.id ?? 'unknown'),
      provider_kind: telemetryProviderKind(provider?.kind),
    });
    setReasoningMode(next);
    setReasoningIntent(nextIntent);
    if (provider && currentModel) {
      const previous = displayCapabilityPreferences({ ...identity, conversationId: effectiveId ?? undefined });
      const nextPreferences = withCapabilityReasoningIntent(previous, nextIntent);
      if (!effectiveId) { saveCapabilityPreferenceDraft(generationParameterDraftSessionId, identity, nextPreferences); return; }
      const scope = 'conversation_connection_model';
      saveCapabilityPreferences({ ...identity, scope, ...(effectiveId ? { conversationId: effectiveId } : {}) }, nextPreferences);
    }
  }, [capabilityPreferenceIdentity, reasoningIntent, reasoningMode, currentModel, effectiveId, generationParameterDraftSessionId, provider]);

  /**
   * Pick a reasoning tier in the panel. `undefined` means automatic, i.e. inject no tier.
   *
   * The only projection tables are `REASONING_MODE_BY_INTENT` / `REASONING_INTENT_BY_MODE`
   * (see above), so the panel hands back a wire intent which is translated to the enum
   * here and then follows the existing write and analytics path. `off` takes its own
   * branch because `ReasoningMode` cannot express it.
   */
  const handleReasoningIntentChange = useCallback((intent: ReasoningIntent | undefined) => {
    if (intent === 'off') {
      const input = capabilityPreferenceIdentity;
      if (!input) return;
      setReasoningMode('automatic');
      setReasoningIntent('off');
      const previous = displayCapabilityPreferences({ ...input, conversationId: effectiveId ?? undefined });
      if (!effectiveId) saveCapabilityPreferenceDraft(generationParameterDraftSessionId, input, { ...previous, reasoningIntent: 'off' });
      else saveCapabilityPreferences({ ...input, scope: 'conversation_connection_model', conversationId: effectiveId }, { ...previous, reasoningIntent: 'off' });
      return;
    }
    handleReasoningModeChange(REASONING_MODE_BY_INTENT[intent ?? ''] ?? 'automatic');
  }, [capabilityPreferenceIdentity, effectiveId, generationParameterDraftSessionId, handleReasoningModeChange]);

  // ── Messages listener ──
  useEffect(() => {
    const effectiveConvId = conversationId ?? activeConversationId;
    if (!effectiveConvId) return;
    if (syncState === 'disabled') return;

    let cancelled = false;
    let stopListener: (() => void) | undefined;

    void loadSyncCore().then(({ getSyncAdapter }) => {
      if (cancelled) return;

      const adapter = getSyncAdapter();
      if (!adapter) return;

      adapter.startMessagesListener(effectiveConvId);
      stopListener = () => {
        adapter.stopMessagesListener();
      };
    });

    return () => {
      cancelled = true;
      stopListener?.();
    };
  }, [conversationId, activeConversationId, syncState]);

  useNotifications(isStreaming);

  // No automatic resync: the metadata cache manages freshness through its 24h TTL.

  // ── Stable TopBar callbacks ──
  const handleToggleSidebar = useCallback(() => setSidebarOpen(!getVanillaStore().getState().sidebarOpen), [setSidebarOpen]);
  const handleToggleMemory = useMemo(() => {
    if (!conversation) return undefined;
    return () => {
      getVanillaStore().getState().setConversationUseMemory(conversation.id, conversationUseMemory === false ? true : false);
    };
  }, [conversation, conversationUseMemory]);
  const extraActions = useMemo(() => {
    const canExport = conversation && conversation.messages.length > 0;
    return (
      <div className={styles.topBarActions}>
        {canExport ? <ExportMenuButton conversation={conversation} /> : null}
        <ThemeToggleButton />
      </div>
    );
  }, [conversation]);

  // ── No providers ──
  if (providers.length === 0 && !conversation) {
    return (
      <div className={styles.view}>
        <div className={styles.noProvider}>
          <p className={styles.noProviderText}>{t('noProviderHint')}</p>
          <Button onClick={() => router.push('/providers/new')}>
            {t('addProvider')}
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div
      className={styles.view}
      {...(isDesktop ? dragHandlers : {})}
    >
      <ChatAmbientAurora prominent={isEmptyChat} />
      <SkillActionPromptDialog
        open={showSkillProviderPrompt}
        kind="provider"
        title={tSkills('providerRequiredTitle')}
        message={tSkills('providerRequiredMessage')}
        actionLabel={tSkills('providerRequiredAction')}
        cancelLabel={tSkills('promptCancel')}
        onClose={() => setShowSkillProviderPrompt(false)}
        onAction={() => {
          setShowSkillProviderPrompt(false);
          router.push('/providers/new');
        }}
      />
      <AttachmentSizeLimitDialog
        open={showAttachmentSizeLimit}
        onClose={() => setShowAttachmentSizeLimit(false)}
        title={attachmentLimitDialogCopy?.title}
        message={attachmentLimitDialogCopy?.message}
        actionLabel={attachmentLimitDialogCopy?.actionLabel}
      />
      {libraryFeatureEnabled ? (
        <LibraryContextPicker
          open={showLibraryContextPicker}
          sources={activeLibrarySources}
          selected={libraryContextDocuments}
          researchAvailable={libraryResearchAvailable}
          researchServerSide={libraryResearchServerSide}
          researchPending={libraryResearchPending}
          researchUnavailableReason={libraryResearchUnavailableReason}
          researchEnabled={Boolean(libraryResearchEnabled)}
          onResearchEnabledChange={handleLibraryResearchToggle}
          remainingResearches={
            libraryQuota && libraryQuota.limit >= 0
              ? Math.max(0, libraryQuota.remaining)
              : null
          }
          maxDocuments={resolveDirectMaxDocuments(getLibraryRuntimeConfig())}
          onChange={handleLibraryContextChange}
          onClose={() => setShowLibraryContextPicker(false)}
          onQuota={setLibraryQuota}
        />
      ) : null}
      <TopBar
        transparentChrome={isEmptyChat}
        modelName={currentModel?.executionLocality === "proxied_cloud"
          ? `${currentModel.name} - ${t("viaOllamaCloud")}`
          : currentModel?.name}
        providerKind={provider?.kind}
        relayKind={provider?.relayKind}
        skillIcon={currentSkill?.icon}
        skillName={currentSkill?.name}
        sidebarOpen={sidebarOpen}
        isStreaming={isStreaming}
        conversationCost={conversation?.estimatedCost}
        onToggleSidebar={handleToggleSidebar}
        onModelClick={handleToggleModelSwitcher}
        memoryText={memoryText}
        useMemory={conversationUseMemory}
        onToggleMemory={handleToggleMemory}
        extraActions={extraActions}
      />
      {fromNote ? (
        <div className={styles.returnToNoteBar}>
          <button type="button" onClick={() => router.push(`/notes/${fromNote}`)}>
            <ChevronLeftIcon size={14} />
            {t('returnToNote')}
          </button>
        </div>
      ) : null}

      {showModelSwitcher && (
        <div className={styles.modelSwitcherLayer}>
            <LazyModelSwitcher
              providers={providers}
              selectedProviderId={provider?.id}
              selectedModelId={currentModel?.id}
              currentModel={currentModel}
              onSelect={handleModelSelect}
              onEnableAndSelect={handleEnableAndSelect}
              onAddManualAndSelect={handleAddManualAndSelect}
              requiredGenerationParameterId={switcherRequiredParameterId}
              onClose={() => setShowModelSwitcher(false)}
            />
        </div>
      )}

      <MessageList
          messages={messages}
          providers={providers}
          isStreaming={isStreaming}
          conversationId={effectiveId}
          searchQuery={searchQuery}
          focusMessageId={focusMessageId}
          replaceCurrentNoteId={replaceCurrentNoteId}
          savedNoteRefsByMessageId={savedNoteRefsByMessageId}
          emptyState={shouldShowConversationBootstrap ? (
            <ConversationBootstrapState />
          ) : loadState === 'stalled' ? (
            <ConversationStalledState onRetry={retryHydration} />
          ) : currentSkill ? (
            <SkillIntro skill={currentSkill} />
          ) : (
            <SkillsLanding
              onSkillSelect={handleSkillSelectFromLanding}
              onSkillStarterPrompt={handleSkillStarterPromptFromLanding}
              layout="default"
            />
          )}
        onRetry={retry}
        onRetryWithoutCustom={handleRetryWithoutCustom}
        onEditAndResend={editAndResend}
        onContinueAnswering={continueAnswering}
        onSwitchModel={handleSwitchModel}
        onAskSelection={handleAskSelection}
      />

      {/* Drag overlay */}
      {dragActive && (
        <div className={styles.dragOverlay}>
          <div className={styles.dragContent}>
            <AttachmentIcon size={32} />
            <span>{t('dropFiles')}</span>
          </div>
        </div>
      )}

      {expensiveModelHint && (
        <div className={styles.expensiveModelHint}>
          <WarningIcon className={styles.expensiveModelHintIcon} />
          <span className={styles.expensiveModelHintText}>
            {t('expensiveModelHint', {
              newModel: expensiveModelHint.newModel,
              multiplier: expensiveModelHint.multiplier,
              oldModel: expensiveModelHint.oldModel,
            })}
          </span>
          <button
            type="button"
            className={styles.expensiveModelHintClose}
            onClick={clearExpensiveHint}
            aria-label={tCommon('close')}
          >
            <CloseIcon strokeWidth={2.5} />
          </button>
        </div>
      )}

      <InputComposer
        value={inputText}
        onChange={setInputText}
        onSend={handleSend}
        onStop={stop}
        isStreaming={isStreaming}
        disabled={isComposerBlocked}
        attachments={attachments}
        onAttachmentsChange={setAttachments}
        reasoningIntent={reasoningIntent}
        onReasoningIntentChange={handleReasoningIntentChange}
        reasoningOutboundActive={capabilityOutboundDecision.hasReasoningSelection}
        webPreference={webPreference}
        onWebPreferenceChange={handleWebPreferenceChange}
        webOutboundActive={capabilityOutboundDecision.hasWebSelection}
        webRuntimeRejected={webRuntimeRejected}
        libraryResearchEnabled={libraryFeatureEnabled ? libraryResearchEnabled : undefined}
        onLibraryResearchToggle={libraryFeatureEnabled ? handleLibraryResearchToggle : undefined}
        currentModel={currentModel}
        generationParameterProvider={provider}
        generationParameterConversationId={effectiveId ?? generationParameterDraftSessionId}
        managedModelControls={controlsManagedByOriveo}
        webControl={webControl}
        reasoningControl={reasoningControl}
        generationControl={generationControl}
        capabilityTransportIdentity={capabilityPreferenceIdentity?.transportIdentity}
        reasoningRuntimeRejected={reasoningRuntimeRejected}
        capabilityAlternativeModels={capabilityAlternativeModels}
        onSelectAlternativeModel={handleSelectAlternativeModel}
        onOpenModelSwitcher={() => setShowModelSwitcher(true)}
        onOpenConnectionSettings={provider ? () => router.push(`/providers/${provider.id}`) : undefined}
        onFindModelsSupportingParameter={handleFindModelsSupportingParameter}
        providerAttachmentSupport={providerAttachmentSupport}
        providerKind={telemetryProviderKind(provider?.kind)}
        attachmentFilePolicy={attachmentFilePolicy}
        attachmentLimitDialogCopy={attachmentLimitDialogCopy}
        presentation={showHomeComposer ? 'home' : 'docked'}
        relatedNotes={relatedNotes}
        onAttachRelatedNote={handleAttachRelatedNote}
        onDismissRelatedNote={handleDismissRelatedNote}
        attachedNotes={attachedNotes}
        onDetachNote={handleDetachNote}
        libraryContextDocuments={libraryFeatureEnabled ? libraryContextDocuments : undefined}
        // Do not take up composer width when no source has ever been connected - opening
        // the chip would only show an empty panel. A non-empty pending document list must
        // keep showing, otherwise "connected then disconnected" leaves attached documents
        // impossible to clear.
        onAddLibraryContext={
          libraryFeatureEnabled && (activeLibraryConnection || libraryContextDocuments.length > 0)
            ? handleLibraryContextOpen
            : undefined
        }
        onDetachLibraryContext={libraryFeatureEnabled ? handleDetachLibraryContext : undefined}
        quoteContext={pendingQuoteContext}
        onRemoveQuote={handleRemoveQuote}
        quoteFocusSignal={quoteFocusSignal}
      />

      {libraryFeatureEnabled ? <LibraryConfirmationDialog /> : null}

    </div>
  );
}
