'use client';

import { useEffect, useState, useMemo, useCallback, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { MessageCircle } from 'lucide-react';
import { ArrowClockwiseIcon, HardDrivesIcon, PlusIcon } from '@phosphor-icons/react';
import type { AIModel, Provider, ReasoningMode, RelayRequestedConfig } from '@oriveo/shared';
import {
  displayableRelayFormIssues,
  relayFormFieldDefinition,
  relayFormNormalizedEndpoint,
  validateRelayForm,
  type RelayFormIssue,
  type RelayFormDraft,
} from '@oriveo/core/providers/relay-form-validation';
import { relayHasCredentialMaterialAcross } from '@oriveo/core/providers/relay-runtime-support';
import { normalizeEndpointForSecurityMode } from '@oriveo/core/providers/relay-security-mode';
import { BackButton, Button } from '@oriveo/ui';
import { RelayPrivacyNotice } from '../../../components/providers/RelayPrivacyNotice';
import { RelaySecurityModeControl } from '../../../components/providers/RelaySecurityModeControl';
import { useProviderActions } from '../../../lib/hooks/useProviderActions';
import { useAppStore, getVanillaStore } from '../../../providers/StoreProvider';
import { getProviderInstanceDisplayName } from '../../../lib/core/providers/provider-display';
import { enableProviderModel, enableProviderModels } from '../../../lib/core/provider-model-ops';
import { showToast } from '../../../components/Toast';
import {
  isCleartextRelayConnection,
  relayProviderCredentialState,
} from '../../../lib/core/providers/relay-runtime-support';
import { extractPingErrorMessage } from '../../../lib/core/providers/ping-relay';
import { relayFormIssueMessage } from '../../../lib/core/providers/relay-form-messages';
import { hasRelayConnectedEvidence } from '../../../lib/core/providers/probe/probe-runner';
import { ConfirmDeleteDialog } from './components/ConfirmDeleteDialog';
import { EditableProviderName } from './components/EditableProviderName';
import { RelayRecoveryCard } from './components/RelayRecoveryCard';
import { localizeProviderLastError } from './provider-last-error';

const RELAY_UNVERIFIED_SOURCE = 'Connection has not been verified.';
import { useProviderChatLauncher } from './useProviderChatLauncher';
import { RelayApiKeyDialog } from './components/RelayApiKeyDialog';
import { RelayDetailBoard } from './components/RelayDetailBoard';
import { initialRelayKeysPageStateFromSeed, RelayKeysPage } from './components/RelayKeysPage';
import type { RelayKeysPageState } from './relay-keys-page-state';
import { RelayWebSearchPage } from './components/RelayWebSearchPage';
import { effectiveRelayWebFragmentsForProvider } from '../../../lib/core/chat/relay-web-fragments';
import {
  parseRelayDetailPage,
  relayDetailPageQuery,
  relayDetailParentPage,
  type RelayDetailPage,
} from './relay-detail-nav';
import {
  RELAY_DETAIL_TEXT,
  relayDetailBoard,
  relayDetailRecoveryCard,
  type DetailRowAction,
  type RelayRecoveryActionID,
} from './relay-detail-board';
import {
  relayEditActiveCompatRows,
  relayEditBoard,
  relayEditDraftFromProvider,
  relayEditDraftMatchesSaved,
  relayEditNextGroupChoice,
  relayEditSavedRequested,
  relayEditSavePatch,
  relayEditSavePatchFor,
  type EditCollapsibleGroup,
  type EditCompatRowID,
  type EditGroup,
  type RelayEditDraft,
  type RelayEditStatus,
} from './relay-edit-board';
import { RelayEditConnection } from './components/RelayEditConnection';
import { RelaySettingsFailureCard } from './components/RelaySettingsFailureCard';
import { buildRelaySettingsCandidate } from '../../../lib/core/provider-ops';
import { relayWebProbeSource } from '../../../lib/core/relay-web-probe-ops';
import {
  applyRelayKeyOperation,
  enableProviderModelWithProbe,
  redetectRelayModels,
  useRelayLazyProbeStates,
} from '../../../lib/core/relay-model-probe-ops';
import { refreshRelayCatalogInStore } from '../../../lib/core/providers/provider-sync';
import { RelayAvatarPickerButton } from '../../../components/RelayAvatarPicker';
import { relayShotSeed } from '../../../lib/dev/relay-shots-mode';
import { ModelBrowser } from './ModelBrowser';
import { ProviderDetailNoticeView, useProviderDetailNotice } from './provider-detail-notice';
import {
  isRelayCatalogKeyFilter,
  relayCatalogBoard,
  relayCatalogEnableAllModelIDs,
  relayCatalogHeader,
  relayCatalogKeyStrip,
  relayCatalogFailureReasonKey,
  relayCatalogLayout,
  RELAY_CATALOG_TEXT,
  type RelayCatalogFilter,
} from './relay-catalog-board';
import {
  RelayCatalogChips,
  RelayCatalogKeyStrip,
  RelayCatalogLegend,
  RelayCatalogMoreMenu,
  RelayCatalogRowBody,
  RelayCatalogStatusText,
  useRelayCatalogRowLabel,
} from './components/RelayCatalogParts';
import catalogPartStyles from './components/RelayCatalogParts.module.css';
import { RelayParametersDialog } from './components/RelayParametersDialog';
import {
  relayCapabilityTestPlan,
  relayCapabilityTestTransport,
  runRelayCapabilityTest,
} from '../../../lib/core/relay-capability-test-ops';
import { RelayCapabilityTestPanel, type RelayCapabilityTestPanelProps } from './components/RelayCapabilityTestPanel';
import {
  probeRelayModelTransportOnce,
  restoreAllRelayAutomatic,
  setRelayCapabilityOverride,
  setRelayModelTransport,
  setRelayReasoningLevels,
  type RelayAdvancedCapabilityKey,
} from '../../../lib/core/relay-model-advanced-ops';
import {
  RELAY_ADVANCED_TEXT,
  relayModelAdvancedBoard,
  type RelayAdvancedControl,
  type RelayAdvancedProbe,
  type RelayAdvancedSegment,
} from './relay-model-advanced-board';
import { RelayModelAdvanced } from './components/RelayModelAdvanced';
import styles from './ProviderDetail.module.css';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { relayKeySecrets } from '@oriveo/shared/relay/relay-keys';
import boardStyles from './components/RelayDetailBoard.module.css';
import { createProviderSelectionSnapshot, resolveRelayVerificationSampleModelID } from '../../../lib/core/providers/provider-selection-snapshot';
import { findRelayModel, relayModelKey } from '../../../lib/core/providers/relay-model-identity';

interface RelayDetailProps {
  provider: Provider;
}

/** "Test capability" bottom panel: starts testing as soon as it is tapped; running -> done / interrupted. */
type CapabilityTestPanelState = { modelName: string; modelID: string; state: RelayCapabilityTestPanelProps['state'] };

export function RelayDetail({ provider }: RelayDetailProps) {
  const router = useRouter();
  const tr = useTranslations('pages.relayDetail');
  const tSetup = useTranslations('pages.relaySetup');
  const tc = useTranslations('common');
  const t = useTranslations('pages.providerDetail');
  const te = useTranslations('errors');
  /** The form issue's message key carries a namespace (the same mapping as the add flow), so it is resolved with the root translator. */
  const tRoot = useTranslations();

  const {
    isSyncing,
    catalogLoadState,
    relaySettingsSaveFailure,
    saveKey,
    removeKey,
    clearRelayCredentials,
    saveName,
    saveRelaySettings,
    saveRelaySettingsUnverified,
    retryRelaySettingsSave,
    clearRelaySettingsSaveFailure,
    refreshRelayCatalog,
    reconnectRelaySecurityMode,
    verifyRelayConnection,
    testRelayDraft,
    addModels,
    removeModel,
    toggleModel,
    deleteProvider,
  } = useProviderActions(provider);

  // The single source for the credential decision: authMode (plus what the key store actually holds); whether apiKeyPreview is empty is not consulted
  const credentialState = relayProviderCredentialState(provider);
  const isCleartextConnection = isCleartextRelayConnection(provider.relayRequested?.securityMode);

  const { startChatWithModel: handleChatWithModel, canStartChatWithModel } = useProviderChatLauncher(provider);

  const [showConfirmDelete, setShowConfirmDelete] = useState(false);
  const [showAddModels, setShowAddModels] = useState(false);
  /** The model behind the "Not connected - view reason" dialog. */
  const [unreachableModelID, setUnreachableModelID] = useState<string | null>(null);
  // Recovery card dismiss (x): page-level and not persisted -- it does not reappear when returning from a subview, and reappears after leaving the detail page and coming back (same as iOS).
  const [recoveryCardDismissed, setRecoveryCardDismissed] = useState(false);
  /**
   * Page-level cancellation: lazy verification on enable and re-detection started from this page both carry it, and leaving the detail page aborts them.
   * Created in an effect so StrictMode's simulated unmount does not cancel the one actually in use.
   */
  const pageAbortRef = useRef<AbortController | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    pageAbortRef.current = controller;
    return () => controller.abort();
  }, []);
  /** Connection-level generation parameters dialog. */
  const [showParameters, setShowParameters] = useState(false);
  const [capabilityTestPanel, setCapabilityTestPanel] = useState<CapabilityTestPanelState | null>(null);
  const capabilityTestAbortRef = useRef<AbortController | null>(null);
  const [modelInput, setModelInput] = useState('');
  const detailNotice = useProviderDetailNotice(provider.id);
  /** Recovery card "Re-verify" in flight: state drives the display, the ref latches repeated taps within the same frame. */
  const [isReverifying, setIsReverifying] = useState(false);
  const reverifyingRef = useRef(false);
  /**
   * The detail page is the board; the model library / keys page / model > advanced are real levels:
   * driven by URL query parameters, entering pushes, going back pops exactly one level, and a refresh restores from the URL. Editing the connection is still a same-page subview and does not go into the URL.
   */
  const [page, setPage] = useState<RelayDetailPage>(() => (
    parseRelayDetailPage(typeof window === 'undefined' ? '' : window.location.search)
  ));
  // Screenshot preset (dev builds only, always null in production): open the page already editing the connection.
  const [isEditing, setIsEditing] = useState(() => relayShotSeed()?.detail?.editing ?? false);
  const [, setWebSearchRevision] = useState(0);
  /** Query strings this page pushed into history itself: only then does it call router.back(); when a link with parameters was opened directly there are none, so it replaces to the level above. */
  const pushedQueriesRef = useRef<string[]>([]);
  const view = isEditing ? 'edit' : page.view;
  const advancedModelID = page.view === 'advanced' ? page.modelID : null;
  const advancedReadOnly = page.view === 'advanced' && page.readOnly;
  /** Single-protocol probe result after a manually chosen protocol; kept in this page's memory only. */
  const [advancedProbe, setAdvancedProbe] = useState<RelayAdvancedProbe | null>(null);
  const advancedProbeAbortRef = useRef<AbortController | null>(null);
  const [showKeyDialog, setShowKeyDialog] = useState(false);
  const [isDetecting, setIsDetecting] = useState(false);
  /** The draft for editing the connection: only the items editable on the page; every other field takes the value in the store at save time. */
  const [editDraft, setEditDraft] = useState<RelayEditDraft>(() => relayEditDraftFromProvider(provider));
  /** The connection record when the edit page was opened: at save time only fields where the draft differs from it count as user-changed, the rest take the live value at the moment of persisting. */
  const [editBaseline, setEditBaseline] = useState<Provider>(provider);
  /** Incremented on every draft change by the user; an in-flight test result only lands if the draft has not changed. */
  const draftRevisionRef = useRef(0);
  const [editStatus, setEditStatus] = useState<RelayEditStatus | null>(null);
  const [shownCompatRows, setShownCompatRows] = useState<ReadonlySet<EditCompatRowID>>(new Set());
  const [groupChoice, setGroupChoice] = useState<Partial<Record<EditCollapsibleGroup, boolean>>>({});
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false);
  const [endpointRevealVersion, setEndpointRevealVersion] = useState(0);
  const savedRequested = relayEditSavedRequested(provider);
  const draftHasCredentialMaterial = relayHasCredentialMaterialAcross([
    {
      authMode: savedRequested.authMode,
      hasStoredKey: (resolveProviderAPIKey(provider) ?? '').trim().length > 0,
      headers: savedRequested.headers,
      queryParams: savedRequested.queryParams,
    },
    {
      authMode: editDraft.authMode,
      hasStoredKey: false,
      headers: editDraft.headers,
      queryParams: editDraft.queryParams,
    },
  ]);

  const parsedModelIds = useMemo(() => {
    const lines = modelInput.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
    return [...new Set(lines)];
  }, [modelInput]);

  const newModelIds = useMemo(() => {
    const existingIds = new Set(provider.models.map((m) => relayModelKey(m.id)));
    return parsedModelIds.filter((id) => !existingIds.has(relayModelKey(id)));
  }, [parsedModelIds, provider.models]);
  const libraryModels = useMemo(() => {
    const enabledIDs = new Set(provider.models.map((model) => relayModelKey(model.id)));
    return provider.catalogModels.filter((model) => !enabledIDs.has(relayModelKey(model.id)));
  }, [provider.catalogModels, provider.models]);
  /** Model library subpage board: the protocol filter applies to both the enabled section and the catalog section. */
  // When opened with `?view=library&key=<id>`, the first frame is already filtered to that key.
  const [catalogFilter, setCatalogFilter] = useState<RelayCatalogFilter>(() => (
    page.view === 'library' && page.keyID ? { key: page.keyID } : 'all'
  ));
  /** Keys page state (in-flight fetches, hints) lives on this page: it survives going to the model library and coming back. */
  const [keysPageState, setKeysPageState] = useState<RelayKeysPageState>(initialRelayKeysPageStateFromSeed);
  const lazyProbeStates = useRelayLazyProbeStates(provider.id);
  const catalogBoard = useMemo(() => (view === 'library'
    ? relayCatalogBoard({
        provider,
        enabledModels: provider.models,
        catalogModels: provider.catalogModels,
        catalogLoaded: catalogLoadState === 'loaded',
        filter: catalogFilter,
        now: Date.now(),
        probeStates: lazyProbeStates,
      })
    : null), [catalogFilter, catalogLoadState, lazyProbeStates, provider, view]);
  const catalogLayout = relayCatalogLayout({ provider, catalogLoadState, libraryCount: libraryModels.length });
  // Read-only advanced (readonly=1) is entered from a catalog row, and the model may not be enabled yet.
  const advancedModel = view === 'advanced' && advancedModelID
    ? provider.models.find((model) => model.id === advancedModelID)
      ?? (advancedReadOnly ? provider.catalogModels.find((model) => model.id === advancedModelID) : undefined)
    : undefined;
  const advancedBoard = useMemo(() => (advancedModel
    ? relayModelAdvancedBoard({
        provider,
        model: advancedModel,
        now: Date.now(),
        probe: advancedProbe,
        readOnly: advancedReadOnly,
      })
    : null), [advancedModel, advancedProbe, advancedReadOnly, provider]);
  const catalogRowLabel = useRelayCatalogRowLabel();
  const catalogLibraryRows = useMemo(
    () => new Map((catalogBoard?.library.rows ?? []).map((row) => [row.model.id, row])),
    [catalogBoard],
  );

  const providerDisplayName = getProviderInstanceDisplayName(provider);
  // A relay has no default model: re-verify / type suggestion both use the verification sample (fallback model, then the first catalog entry).
  const lastUsedModelRef = useAppStore((s) => s.lastUsedModelRef);
  const relaySampleModelId = resolveRelayVerificationSampleModelID(provider, lastUsedModelRef);
  // The parameters dialog defaults to the connection's default model (the same resolution as opening a new chat); if it is not among the enabled ones, the first one.
  const snapshotDefaultModelID = showParameters
    ? createProviderSelectionSnapshot(provider, { lastUsedModelRef })?.defaultModel?.id
    : undefined;
  const parametersDefaultModelID = provider.models.some((model) => model.id === snapshotDefaultModelID)
    ? snapshotDefaultModelID!
    : provider.models[0]?.id ?? '';

  // The same capsule toast as the official detail page: adding from the model library shows "Added", removing shows "Removed - Undo"
  const handleCatalogToggleModel = (model: AIModel) => {
    const wasEnabled = findRelayModel(provider.models, model.id) !== undefined;
    if (wasEnabled) {
      toggleModel(model);
      return;
    }
    // Catalog row plus = enable (the original lazy-verification path), carrying the page-level signal: leaving the detail page cancels the lazy verification.
    enableProviderModelWithProbe(getVanillaStore(), provider, model, { signal: pageAbortRef.current?.signal });
    showToast(t('toast.modelAdded', { model: model.name }), 3000, undefined, 'success');
  };

  /** Group header "Add all": one write-back, zero probes; only the number of newly added models is announced, and 0 announces nothing. */
  const handleAddAllGroup = (modelIDs: readonly string[]) => {
    const ids = new Set(modelIDs);
    const added = enableProviderModels(getVanillaStore(), provider, provider.catalogModels.filter((model) => ids.has(model.id)));
    if (added > 0) showToast(tRoot(RELAY_CATALOG_TEXT.addedModels, { count: added }), 3000, undefined, 'success');
  };

  /** Retry on the key status bar: refreshes only that one key (onlyKeyIDs), the others are skipped. */
  const retryCatalogKey = (keyID: string) => {
    void refreshRelayCatalogInStore(getVanillaStore(), provider, { onlyKeyIDs: [keyID] });
  };

  /** Advanced "Key" section: picking one key -> rebind; picking Auto -> rebind to the rule's result; picking the current one writes nothing. */
  const selectAdvancedKey = (value: string) => {
    const section = advancedBoard?.keySection;
    if (!advancedModel || !section || advancedBoard?.readOnly) return;
    const keyID = value === 'auto' ? section.autoKeyID : value;
    if (keyID === section.current.id) return;
    void applyRelayKeyOperation(
      getVanillaStore(),
      provider,
      { type: 'rebind', modelID: advancedModel.id, keyID },
      { signal: pageAbortRef.current?.signal },
    );
  };

  const runCapabilityTest = (model: AIModel, keyName: string | null) => {
    capabilityTestAbortRef.current?.abort();
    const controller = new AbortController();
    capabilityTestAbortRef.current = controller;
    const items = relayCapabilityTestPlan(model, provider);
    const update = (next: (state: CapabilityTestPanelState['state']) => CapabilityTestPanelState['state']) => {
      // Cancelled / superseded by a newer test: late progress and results no longer overwrite the panel.
      if (controller.signal.aborted || capabilityTestAbortRef.current !== controller) return;
      setCapabilityTestPanel((current) => current && { ...current, state: next(current.state) });
    };
    setCapabilityTestPanel({
      modelName: model.name,
      modelID: model.id,
      state: {
        transport: relayCapabilityTestTransport(provider, model) ?? 'chat',
        items,
        keyName,
        phase: 'running',
        results: {},
        running: { kind: 'text', startedAt: Date.now() },
        written: false,
        stopReason: null,
        // Fragment source of the web item: no stored fragment = test with the protocol template (the template is the effective fragment).
        webSource: relayWebProbeSource(provider, model),
      },
    });
    void runRelayCapabilityTest(getVanillaStore(), provider.id, model.id, {
      signal: controller.signal,
      onProgress: (progress) => update((state) => ({
        ...state,
        results: progress.results,
        running: progress.running ? { kind: progress.running, startedAt: Date.now() } : null,
      })),
    })
      .then((result) => update((state) => ({
        ...state,
        items: result.plan,
        phase: result.outcome === 'stopped' ? 'stopped' : 'completed',
        results: result.results,
        running: null,
        written: result.written,
        stopReason: result.stopReason ?? null,
        webSource: result.webSource ?? state.webSource,
      })))
      // Threw before writing: nothing was written, reported as "Interrupted: this model can no longer be tested". An error thrown after writing is handed out by the executor together with the results.
      .catch(() => update((state) => ({ ...state, phase: 'stopped', running: null, written: false, stopReason: 'unavailable' })))
      .finally(() => {
        if (capabilityTestAbortRef.current === controller) capabilityTestAbortRef.current = null;
      });
  };

  /** Cancel: aborts the in-flight request; the panel stops at "Interrupted: you cancelled the test", completed items are kept and nothing is written. */
  const cancelCapabilityTest = () => {
    capabilityTestAbortRef.current?.abort();
    capabilityTestAbortRef.current = null;
    setCapabilityTestPanel((current) => current && {
      ...current,
      state: { ...current.state, phase: 'stopped', running: null, stopReason: 'cancelled' },
    });
  };

  const closeCapabilityTest = useCallback(() => setCapabilityTestPanel(null), []);

  useEffect(() => () => capabilityTestAbortRef.current?.abort(), []);

  // Screenshot preset (dev builds only): once the injected save failure lands, focus the address (same address reveal as "Edit connection").
  useEffect(() => {
    if (relaySettingsSaveFailure && relayShotSeed()?.detail?.settingsFailure) setEndpointRevealVersion((version) => version + 1);
  }, [relaySettingsSaveFailure]);

  // Screenshot preset (dev builds only): the advanced page opens with the capability-test panel already in its running state, built like the initial state of runCapabilityTest.
  const shotCapabilityTestAppliedRef = useRef(false);
  useEffect(() => {
    const seeded = relayShotSeed()?.detail?.capabilityTest;
    if (!seeded || shotCapabilityTestAppliedRef.current || !advancedModel || !advancedBoard) return;
    shotCapabilityTestAppliedRef.current = true;
    setCapabilityTestPanel({
      modelName: advancedModel.name,
      modelID: advancedModel.id,
      state: {
        transport: relayCapabilityTestTransport(provider, advancedModel) ?? 'chat',
        items: relayCapabilityTestPlan(advancedModel),
        keyName: advancedBoard.keySection?.current.title ?? null,
        phase: 'running',
        results: seeded.results,
        running: { kind: seeded.running, startedAt: Date.now() },
        written: false,
        stopReason: null,
      },
    });
  });
  useEffect(() => () => advancedProbeAbortRef.current?.abort(), []);

  const resetAdvancedProbe = () => {
    advancedProbeAbortRef.current?.abort();
    advancedProbeAbortRef.current = null;
    setAdvancedProbe(null);
  };

  const pageHref = (target: RelayDetailPage) => `${window.location.pathname}${relayDetailPageQuery(target)}`;

  const navigateTo = (target: RelayDetailPage) => {
    pushedQueriesRef.current = [...pushedQueriesRef.current, relayDetailPageQuery(target)];
    // Every entry into the model library sets the filter by entry point: with a key it is key(id), without one it goes back to All.
    if (target.view === 'library') setCatalogFilter(target.keyID ? { key: target.keyID } : 'all');
    setPage(target);
    router.push(pageHref(target));
  };

  /** Select a chip; when leaving the key filter, drop key= from the URL (replace, no new history level) so a refresh no longer returns to the key filter. */
  const selectCatalogFilter = (filter: RelayCatalogFilter) => {
    setCatalogFilter(filter);
    if (page.view !== 'library' || !page.keyID || isRelayCatalogKeyFilter(filter)) return;
    const next: RelayDetailPage = { view: 'library' };
    const pushed = pushedQueriesRef.current;
    if (pushed.length > 0 && pushed[pushed.length - 1] === relayDetailPageQuery(page)) {
      pushedQueriesRef.current = [...pushed.slice(0, -1), relayDetailPageQuery(next)];
    }
    setPage(next);
    router.replace(pageHref(next));
  };

  /** Going back pops exactly one level: if this page pushed that level, router.back(); otherwise (opened directly / refreshed) replace to the level above. */
  const navigateBack = () => {
    const parent = relayDetailParentPage(page);
    const pushed = pushedQueriesRef.current;
    setPage(parent);
    if (pushed.length > 0 && pushed[pushed.length - 1] === relayDetailPageQuery(page)) {
      pushedQueriesRef.current = pushed.slice(0, -1);
      router.back();
      return;
    }
    pushedQueriesRef.current = [];
    router.replace(pageHref(parent));
  };

  // Browser forward / back: restore the level from the URL and trim this page's push record to the current level.
  useEffect(() => {
    const onPopState = () => {
      const target = parseRelayDetailPage(window.location.search);
      const index = pushedQueriesRef.current.indexOf(relayDetailPageQuery(target));
      pushedQueriesRef.current = index >= 0 ? pushedQueriesRef.current.slice(0, index + 1) : [];
      if (target.view === 'library') setCatalogFilter(target.keyID ? { key: target.keyID } : 'all');
      setPage(target);
    };
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, []);

  // Leaving a model's advanced page (by any route) invalidates its single-protocol probe result.
  useEffect(() => () => {
    advancedProbeAbortRef.current?.abort();
    advancedProbeAbortRef.current = null;
    setAdvancedProbe(null);
  }, [advancedModelID]);

  const openAdvanced = (modelID: string) => {
    navigateTo({ view: 'advanced', modelID, readOnly: false });
  };

  /** Tapping a catalog row = read-only advanced; opening sends no request. */
  const openReadOnlyAdvanced = (model: AIModel) => {
    navigateTo({ view: 'advanced', modelID: model.id, readOnly: true });
  };

  // The model on the advanced page was removed (or the model in the link does not exist): fall back to the model library. On refresh the local library is still backfilling (startup not ready),
  // so the catalog may be empty for a moment: wait for the backfill to finish before deciding, and do not bounce read-only advanced back to the model library.
  const hydrationPhase = useAppStore((s) => s.hydrationPhase);
  const storeHydrating = hydrationPhase === 'booting' || hydrationPhase === 'metadata-pending';
  useEffect(() => {
    if (view === 'advanced' && !advancedModel && !storeHydrating) navigateBack();
  });

  /** Tapping a protocol segment: write user (Auto clears it), then run one 1-token probe on that single protocol; the result is only displayed, not written. */
  const selectAdvancedSegment = (segment: RelayAdvancedSegment) => {
    if (!advancedModel || !advancedBoard || advancedBoard.protocolRow.kind !== 'relay') return;
    if (advancedBoard.protocolRow.selected === segment) return;
    resetAdvancedProbe();
    if (segment === 'auto') {
      setRelayModelTransport(getVanillaStore(), provider.id, advancedModel.id, null);
      return;
    }
    setRelayModelTransport(getVanillaStore(), provider.id, advancedModel.id, segment);
    const controller = new AbortController();
    advancedProbeAbortRef.current = controller;
    setAdvancedProbe({ transport: segment, result: 'running' });
    void probeRelayModelTransportOnce(provider, advancedModel.id, segment, { signal: controller.signal, store: getVanillaStore() })
      .catch(() => null)
      .then((result) => {
        if (controller.signal.aborted) return;
        advancedProbeAbortRef.current = null;
        setAdvancedProbe(result ? { transport: segment, result } : null);
      });
  };

  const setAdvancedControl = (cap: RelayAdvancedCapabilityKey, control: RelayAdvancedControl) => {
    if (!advancedModel) return;
    setRelayCapabilityOverride(getVanillaStore(), provider.id, advancedModel.id, cap, control === 'auto' ? null : control === 'on');
  };

  const toggleAdvancedLevel = (level: ReasoningMode) => {
    if (!advancedModel || advancedBoard?.thinking?.kind !== 'levels') return;
    const selected = advancedBoard.thinking.cells.filter((cell) => cell.selected).map((cell) => cell.level);
    const next = selected.includes(level) ? selected.filter((item) => item !== level) : [...selected, level];
    setRelayReasoningLevels(getVanillaStore(), provider.id, advancedModel.id, next);
  };

  const restoreAdvanced = () => {
    if (!advancedModel) return;
    resetAdvancedProbe();
    restoreAllRelayAutomatic(getVanillaStore(), provider.id, advancedModel.id);
  };

  const handleRemoveEnabledModel = (model: AIModel) => {
    // When only one is left the same production rule refuses: no "removed" hint.
    if (removeModel(model.id) === false) return;
    showToast(
      t('toast.modelRemoved', { model: model.name }),
      4000,
      () => enableProviderModel(getVanillaStore(), provider, model),
      'removed',
      tc('undo'),
    );
  };

  const handleAddModels = () => {
    if (newModelIds.length === 0) return;
    addModels(newModelIds);
    setModelInput('');
    setShowAddModels(false);
  };

  // Switching authMode to none and deleting the key in the same round is done inside `updateProviderRelaySettings` --
  // it must be the same write as the settings themselves; splitting it into two writes would let the sync of the second push the just-deleted key back to the cloud.
  const hasSavedCredential = (resolveProviderAPIKey(provider) ?? '').trim().length > 0;
  /**
   * The form draft of the edit flow. **Editing = the prefilled state of the same form**:
   * the address is validated against this connection's own `securityMode` (it used to be measured against the default `remote_https`,
   * so a local engine's `http://` was always judged invalid and even a rename could not be saved); an empty key input means no change.
   */
  const formDraftFor = useCallback((draft: RelayEditDraft, patch: Partial<RelayFormDraft> = {}): RelayFormDraft => ({
    endpoint: draft.endpoint,
    apiKey: '',
    authMode: draft.authMode,
    securityMode: savedRequested.securityMode ?? 'remote_https',
    transport: draft.transport,
    modelID: relaySampleModelId ?? '',
    headers: draft.headers,
    queryParams: draft.queryParams,
    // "Is there a key" only looks at the key store itself, not at the apiKeyPreview display string
    hasSavedCredential,
    ...patch,
  }), [hasSavedCredential, relaySampleModelId, savedRequested.securityMode]);

  /** Take the first issue that "must be given a human sentence" (required-field issues only disable the button, with no red text on the spot). */
  const firstSpeakableIssue = useCallback(
    (issues: readonly RelayFormIssue[]): string | null => {
      const blocking = displayableRelayFormIssues(issues)[0];
      return blocking ? relayFormIssueMessage(blocking, tRoot) : null;
    },
    [tRoot],
  );

  /** Key validation on the detail page only goes by the saved configuration. */
  const validateApiKeyDraft = useCallback(
    (raw: string): { ok: true } | { ok: false; message: string } => {
      const draft = formDraftFor(relayEditDraftFromProvider(provider), { apiKey: raw });
      const message = firstSpeakableIssue(validateRelayForm(draft, 'edit'));
      return message ? { ok: false, message } : { ok: true };
    },
    [firstSpeakableIssue, formDraftFor, provider],
  );

  const validateSavedEndpoint = (): { ok: true; normalized: string } | { ok: false; message: string } => {
    const draft = formDraftFor(relayEditDraftFromProvider(provider));
    const message = firstSpeakableIssue(validateRelayForm(draft, 'edit'));
    if (message) return { ok: false, message };
    const normalized = relayFormNormalizedEndpoint(draft, 'edit');
    // What remains can only be the "required" kind (empty address), which has no red text, only this static hint.
    return normalized ? { ok: true, normalized } : { ok: false, message: tr('endpointEmpty') };
  };

  const editIssues = validateRelayForm(formDraftFor(editDraft), 'edit');
  const editNormalizedEndpoint = relayFormNormalizedEndpoint(formDraftFor(editDraft), 'edit');

  /** The user edits the draft: old test / failure results are invalidated immediately (matching iOS when the editor changes), and the compatibility rows opened so far accumulate. */
  const updateEditDraft = (patch: Partial<RelayEditDraft>) => {
    draftRevisionRef.current += 1;
    setEditDraft((current) => {
      const next = { ...current, ...patch };
      const active = relayEditActiveCompatRows(next);
      if (active.length > 0) setShownCompatRows((shown) => new Set([...shown, ...active]));
      return next;
    });
    setEditStatus((current) => (current?.kind === 'reconnecting' ? current : null));
    clearRelaySettingsSaveFailure();
  };

  const saveEditedConnection = async () => {
    const message = firstSpeakableIssue(editIssues);
    if (message || !editNormalizedEndpoint) {
      setEditStatus({ kind: 'failed', message: message ?? tr('endpointEmpty') });
      return;
    }
    // The draft in the middle of saving was edited again: this result is discarded as a whole, nothing is written back and the page is not closed, so the later edit stays (same as iOS).
    const revision = draftRevisionRef.current;
    const isStale = () => revision !== draftRevisionRef.current;
    const saved = await saveRelaySettings(
      relayEditSavePatchFor(editBaseline, editDraft, editNormalizedEndpoint),
      { isStale },
    );
    if (isStale()) return;
    if (saved) closeEditor();
  };

  const changeSecurityMode = async (input: {
    mode: Exclude<NonNullable<RelayRequestedConfig['securityMode']>, 'tofu_https'>;
    normalizedEndpoint: string;
  }) => {
    const cleartext = input.mode === 'local_http' || input.mode === 'private_vpn';
    // Persist only the connection security itself and what comes with it: unsaved protocol / auth / header drafts stay in the editor and are not persisted with the reconnect.
    const nextRequested: RelayRequestedConfig = {
      ...savedRequested,
      modelID: undefined,
      securityMode: input.mode,
      resolvedAPIBaseURL: undefined,
      ...(cleartext
        ? {
            authMode: 'none',
            ...(draftHasCredentialMaterial ? { headers: undefined, queryParams: undefined } : {}),
          }
        : {}),
    };
    const endpointUntouched = editDraft.endpoint === (provider.baseURLText ?? '');
    setEditDraft((current) => ({
      ...current,
      ...(cleartext
        ? { authMode: 'none' as const, ...(draftHasCredentialMaterial ? { headers: [], queryParams: [] } : {}) }
        : {}),
      ...(endpointUntouched ? { endpoint: input.normalizedEndpoint } : {}),
    }));
    if (endpointUntouched && input.normalizedEndpoint !== (provider.baseURLText ?? '').trim()) {
      setEndpointRevealVersion((version) => version + 1);
    }
    clearRelaySettingsSaveFailure();
    setEditStatus({ kind: 'reconnecting' });
    const result = await reconnectRelaySecurityMode({
      securityMode: input.mode,
      normalizedEndpoint: input.normalizedEndpoint,
      modelID: relaySampleModelId ?? '',
      unverifiedMessage: tSetup('connectionUnverified'),
      requested: nextRequested,
    });
    if (!result) {
      setEditStatus((current) => (current?.kind === 'reconnecting' ? null : current));
      return;
    }
    if (result.state === 'verified' && hasRelayConnectedEvidence(result.detection)) {
      setEditStatus({ kind: 'verified' });
      return;
    }
    setEditStatus({ kind: 'failed', message: result.diagnostic ?? tSetup('noProtocolVerified') });
  };

  const switchConflictToHttps = () => {
    const explicitHttps = (provider.baseURLText ?? '').replace(/^http:\/\//i, 'https://');
    const normalizedEndpoint = normalizeEndpointForSecurityMode(explicitHttps, 'remote_https');
    if (!normalizedEndpoint) {
      showToast(tr('connectionTypeInvalidAddress'), 4000, undefined, 'error');
      return;
    }
    void changeSecurityMode({ mode: 'remote_https', normalizedEndpoint });
  };

  /** Recovery card "Re-verify": tests only the saved connection and writes the result back to the connection status. */
  const retrySavedConnection = async () => {
    const endpointCheck = validateSavedEndpoint();
    if (!endpointCheck.ok) {
      showToast(endpointCheck.message, 4000, undefined, 'error');
      return;
    }
    try {
      await verifyRelayConnection(provider);
    } catch (error) {
      showToast(extractPingErrorMessage(error, te), 4000, undefined, 'error');
    }
  };

  /**
   * Test connection tests the draft: unsaved changes are tested too; when the draft equals the saved connection the result is written back to the connection status, otherwise it is only shown on this page.
   * If the draft is edited again while in flight, the result is discarded.
   */
  const testEditedConnection = async () => {
    const message = firstSpeakableIssue(editIssues);
    if (message || !editNormalizedEndpoint) {
      setEditStatus({ kind: 'failed', message: message ?? tr('endpointEmpty') });
      return;
    }
    // The saved key also goes through the same check, to keep fetch() from throwing "String contains non ISO-8859-1 code point"
    const keyCheck = validateApiKeyDraft(resolveProviderAPIKey(provider) ?? '');
    if (!keyCheck.ok) {
      setEditStatus({ kind: 'failed', message: keyCheck.message });
      return;
    }
    const draft = editDraft;
    const revision = draftRevisionRef.current;
    const persist = relayEditDraftMatchesSaved(provider, draft);
    // When equal to the saved connection, test the saved connection (where the stored address lacks a scheme or differs only by normalization, send the request to the normalized address without writing back).
    const candidate = persist
      ? (editNormalizedEndpoint === (provider.baseURLText ?? '').trim()
          ? provider
          : { ...provider, baseURLText: editNormalizedEndpoint })
      : buildRelaySettingsCandidate(provider, relayEditSavePatch(provider, draft, editNormalizedEndpoint));
    setEditStatus({ kind: 'testing' });
    try {
      const result = await testRelayDraft(candidate, persist);
      if (revision !== draftRevisionRef.current) return;
      setEditStatus(result ? { kind: 'verified' } : null);
    } catch (error) {
      if (revision !== draftRevisionRef.current) return;
      // pingRelay throws a ProviderError plain object (not an Error instance),
      // so String(error) directly would give "[object Object]". Fall back on the shared extractPingErrorMessage.
      setEditStatus({ kind: 'failed', message: extractPingErrorMessage(error, te) });
    }
  };

  const saveRelayKey = async (newKey: string) => {
    const endpointCheck = validateSavedEndpoint();
    if (!endpointCheck.ok) {
      showToast(endpointCheck.message, 4000, undefined, 'error');
      return;
    }
    await saveKey(newKey, endpointCheck.normalized);
  };

  // The web-search row state reads the on-device snippet store (including the old-field mapping); after the web-search settings page saves, the revision number is incremented to re-render and re-read.
  const board = relayDetailBoard(provider, lastUsedModelRef, {
    webSearchConfigured: Object.keys(effectiveRelayWebFragmentsForProvider(provider)).length > 0,
  });
  const hasStoredKey = hasSavedCredential;

  /** Every time the edit connection view is entered the draft is rebuilt from the saved configuration: changes just written on the detail page are not overwritten by an old draft. */
  const openEditConnection = () => {
    setEditBaseline(provider);
    setEditDraft(relayEditDraftFromProvider(provider));
    draftRevisionRef.current += 1;
    setEditStatus(null);
    setShownCompatRows(new Set());
    setGroupChoice({});
    setShowDiscardConfirm(false);
    clearRelaySettingsSaveFailure();
    setIsEditing(true);
  };

  /** Leaving the edit connection view discards the draft; an in-flight test result no longer lands on the page. */
  const closeEditor = () => {
    draftRevisionRef.current += 1;
    setEditDraft(relayEditDraftFromProvider(provider));
    setEditStatus(null);
    setShowDiscardConfirm(false);
    clearRelaySettingsSaveFailure();
    setIsEditing(false);
  };

  /** Close button: with unsaved changes, confirm discarding first. */
  const requestCloseEditor = () => {
    if (relayEditDraftMatchesSaved(provider, editDraft)) closeEditor();
    else setShowDiscardConfirm(true);
  };

  const toggleEditGroup = (group: EditGroup) => {
    if (group.id !== 'headers' && group.id !== 'compatibility') return;
    const id = group.id;
    setGroupChoice((current) => ({ ...current, [id]: relayEditNextGroupChoice(group) }));
  };

  const editBoard = view === 'edit'
    ? relayEditBoard({
        provider,
        baseline: editBaseline,
        displayName: providerDisplayName,
        draft: editDraft,
        status: editStatus,
        isSaving: isSyncing,
        issues: editIssues,
        normalizedEndpoint: editNormalizedEndpoint,
        shownCompatRows,
        groupChoice,
      })
    : null;

  const reverifySavedConnection = async () => {
    if (reverifyingRef.current) return;
    reverifyingRef.current = true;
    setIsReverifying(true);
    try {
      await retrySavedConnection();
    } finally {
      reverifyingRef.current = false;
      setIsReverifying(false);
    }
  };

  const recoveryCard = relayDetailRecoveryCard(
    provider,
    isReverifying,
    detailNotice !== null && 'unverifiedReason' in detailNotice,
  );

  const handleRecoveryAction = (id: RelayRecoveryActionID) => {
    if (id === 'editConnection') openEditConnection();
    else if (id === 'apiKeys') navigateTo({ view: 'keys' });
    else void reverifySavedConnection();
  };

  const handleBoardAction = (action: Exclude<DetailRowAction, null>) => {
    if (action === 'editConnection') openEditConnection();
    else if (action === 'openLibrary') navigateTo({ view: 'library' });
    else if (action === 'openWebSearch') navigateTo({ view: 'web' });
    else if (action === 'openParameters') setShowParameters(true);
    else navigateTo({ view: 'keys' });
  };

  // Re-detection calls the stage-1 domain function; on success it writes the last-detected time, and on a catalog failure it gives the existing catalog-failure copy.
  const detectAgain = async () => {
    if (isDetecting) return;
    setIsDetecting(true);
    try {
      const state = await redetectRelayModels(getVanillaStore(), provider, { signal: pageAbortRef.current?.signal });
      if (state === 'failed') showToast(tr('catalogFetchFailed'), 4000, undefined, 'error');
    } catch (error) {
      showToast(extractPingErrorMessage(error, te), 4000, undefined, 'error');
    } finally {
      setIsDetecting(false);
    }
  };

  // The detail page (key change failed) offers retry; on the edit connection page retry is the primary button, and the failure card only offers "Save anyway (unverified)".
  const relaySettingsFailureCard = (inEditor: boolean) => relaySettingsSaveFailure && (
    <RelaySettingsFailureCard
      error={relaySettingsSaveFailure.error}
      canSaveUnverified={relaySettingsSaveFailure.canSaveUnverified}
      apiKey={resolveProviderAPIKey(provider)}
      connectionKeySecrets={relayKeySecrets(provider)}
      relayRequested={inEditor
        ? relayEditSavePatch(provider, editDraft, editNormalizedEndpoint ?? (provider.baseURLText ?? '')).relayRequested
        : savedRequested}
      showRetry={!inEditor}
      onRetry={() => { void retryRelaySettingsSave(); }}
      onDismiss={inEditor ? clearRelaySettingsSaveFailure : undefined}
      onSaveUnverified={() => {
        void saveRelaySettingsUnverified().then((saved) => { if (saved && inEditor) closeEditor(); });
      }}
    />
  );

  // Exits under the key row: S3 gives only two ways out; with no auth required but a stored key, "Remove stored key" is kept (deleting it would delete the feature).
  const apiKeyRowExtras = credentialState === 'conflict' ? (
    <div className={boardStyles.rowExtras} data-tone="error" role="alert">
      <span>{tr('cleartextCredentialsBlocked')}</span>
      <Button tone="primary" size="sm" onClick={() => { void clearRelayCredentials(); }} disabled={isSyncing}>
        {tr('clearAndStay')}
      </Button>
      <Button tone="secondary" size="sm" onClick={switchConflictToHttps} disabled={isSyncing}>
        {tr('switchToHttpsConnection')}
      </Button>
    </div>
  ) : credentialState === 'not_required' && hasStoredKey ? (
    <div className={boardStyles.rowExtras}>
      <Button tone="secondary" size="sm" onClick={() => { void removeKey(); }} disabled={isSyncing}>
        {tr('removeKey')}
      </Button>
    </div>
  ) : null;

  return (
    <div className={styles.page}>
      {view === 'board' && (
        <>
          <div className={styles.header}>
            <BackButton className={styles.backBtn} label={tc('back')} onClick={() => router.push('/providers')} />
          </div>

          <ProviderDetailNoticeView notice={detailNotice} />

          {recoveryCard && !recoveryCardDismissed && (
            <RelayRecoveryCard
              card={recoveryCard}
              localizeReason={(reason) =>
                // iOS and the samples write the English source string (same as iOS ProviderIssueMessage.unverifiedConnectionKey); it is resolved in the current language when rendered
                reason === RELAY_UNVERIFIED_SOURCE ? tSetup('connectionUnverified') : localizeProviderLastError(reason, te) ?? reason
              }
              onAction={handleRecoveryAction}
              onDismiss={() => setRecoveryCardDismissed(true)}
            />
          )}

          {relaySettingsFailureCard(false)}

          <RelayDetailBoard
            board={board}
            nameSlot={
              <EditableProviderName
                name={providerDisplayName}
                onSave={saveName}
                editLabel={tr('editName')}
                saveLabel={tr('saveName')}
                cancelLabel={tc('cancel')}
                disabled={isSyncing}
                titleClassName={boardStyles.boardName}
                editButtonClassName={boardStyles.boardNamePencil}
                pencilSize={18}
              />
            }
            apiKeyRowLabel={hasStoredKey ? t('editKey') : t('apiKey')}
            apiKeyRowExtras={apiKeyRowExtras}
            onAction={handleBoardAction}
            onDetectAgain={() => { void detectAgain(); }}
            isDetecting={isDetecting}
            onDelete={() => setShowConfirmDelete(true)}
            disabled={isSyncing}
            footer={<RelayPrivacyNotice />}
          />
        </>
      )}

      {view === 'edit' && editBoard && (
        <RelayEditConnection
          board={editBoard}
          draft={editDraft}
          status={editStatus}
          locked={isSyncing}
          endpointRevealVersion={endpointRevealVersion}
          issueMessage={(issue) => relayFormIssueMessage(issue, tRoot)}
          onDraftChange={updateEditDraft}
          onToggleGroup={toggleEditGroup}
          renderSecurityControl={(icon, footnote) => (
            <RelaySecurityModeControl
              value={savedRequested.securityMode ?? 'remote_https'}
              endpoint={provider.baseURLText ?? ''}
              hasCredentialMaterial={draftHasCredentialMaterial}
              onChange={changeSecurityMode}
              busy={isSyncing}
              icon={icon}
              footnote={footnote}
            />
          )}
          onTest={() => { void testEditedConnection(); }}
          onPrimary={() => { void saveEditedConnection(); }}
          onClose={requestCloseEditor}
          failureCard={relaySettingsFailureCard(true)}
          showDiscardConfirm={showDiscardConfirm}
          onKeepEditing={() => setShowDiscardConfirm(false)}
          onDiscard={closeEditor}
        />
      )}

      {view === 'library' && catalogBoard && (() => {
        const header = relayCatalogHeader(provider);
        const keyStrip = relayCatalogKeyStrip(provider);
        const unreachable = unreachableModelID ? lazyProbeStates.get(unreachableModelID) : undefined;
        return (
        <>
      {/* Page header: avatar + "Model Library" + "host - N models (- K keys)" + refresh catalog */}
      <div className={styles.header} data-library-header>
        <BackButton className={styles.backBtn} label={tc('back')} onClick={navigateBack} />
        {header.avatarSource
          ? (
            <span className={boardStyles.headerIcon}>
              <RelayAvatarPickerButton source={header.avatarSource} size={32} />
            </span>
          )
          : (
            <span className={boardStyles.headerIcon} aria-hidden="true">
              <HardDrivesIcon size={32} weight="duotone" />
            </span>
          )}
        <div className={boardStyles.headerIdentity}>
          <h1 className={styles.title}>{tRoot(RELAY_DETAIL_TEXT.modelLibrary)}</h1>
          <p className={`${boardStyles.statusLine} ${boardStyles.twoLineClamp}`} data-library-subtitle>
            {[
              header.host,
              tRoot(RELAY_DETAIL_TEXT.modelCount, { count: header.modelCount }),
              ...(header.keyCount !== null ? [tRoot('pages.relayDetail.keysCount', { count: header.keyCount })] : []),
            ].filter(Boolean).join(' · ')}
          </p>
        </div>
        <button
          type="button"
          className={boardStyles.editConnectionButton}
          onClick={() => { void refreshRelayCatalog(); }}
          disabled={isSyncing || catalogLoadState === 'loading'}
          aria-label={tRoot('pages.relayDetail.detectAgain')}
          title={tRoot('pages.relayDetail.detectAgain')}
        >
          <ArrowClockwiseIcon size={18} weight="bold" aria-hidden="true" />
        </button>
      </div>

      <fieldset className={styles.relayReconnectGuard} disabled={isSyncing}>
      <RelayCatalogChips chips={catalogBoard.chips} selected={catalogBoard.filter} keyTitle={catalogBoard.filterKeyTitle} onSelect={selectCatalogFilter} />
      {/* Enabled section (Catalog board): tap / behavior / remove are unchanged, only the row content changes */}
      {/* As on iOS only one layer of card: the outer section drops the card surface and keeps only the inner list card. */}
      <div className={`${styles.section} ${catalogPartStyles.enabledSection}`} data-catalog-section="enabled">
        <div className={styles.sectionHeader}>
          <div className={styles.sectionHeaderLeft}>
            <div className={styles.sectionLabel}>
              {tRoot(RELAY_CATALOG_TEXT.sectionEnabled, { count: catalogBoard.enabled.count })}
            </div>
          </div>
        </div>

        {provider.models.length === 0 ? (
          <div className={styles.relayEmptyModels}>
            <div className={styles.relayEmptyModelsText}>{tr('noModelsHint')}</div>
          </div>
        ) : (
          <div className={styles.modelList}>
            {catalogBoard.enabled.rows.map(({ model, ...row }) => (
              <div key={model.id} className={styles.modelRow} data-catalog-row={model.id}>
                {/* Row line: the left column and the trailing column stay on one line without wrapping, vertically centered as a whole row. */}
                <div className={catalogPartStyles.enabledLine} data-row-line>
                {/* Tapping a row dispatches only by tapTarget: an enabled row enters writable advanced, and does so even when the model is unavailable. */}
                <button
                  type="button"
                  className={`${styles.modelClickArea} ${styles.catalogRowClickArea}`}
                  data-row-open
                  onClick={() => (row.tapTarget === 'advanced' ? openAdvanced(model.id) : openReadOnlyAdvanced(model))}
                  aria-label={catalogRowLabel({ model, ...row })}
                >
                  <RelayCatalogRowBody row={{ model, ...row }} hideStatus />
                </button>
                {/* Trailing column: the status text sits on the same centerline as chat / the overflow menu, right before the chat button (the generation-parameters entry is the Parameters row on the detail page). */}
                <div className={`${styles.modelActions} ${catalogPartStyles.enabledTrailing}`} data-row-trailing>
                  {row.status && row.status !== 'unreachable' && <RelayCatalogStatusText status={row.status} />}
                  {/* Not connected - view reason: tappable, opens the failure reason. */}
                  {row.status === 'unreachable' && (
                    <button
                      type="button"
                      className={catalogPartStyles.statusButton}
                      data-status="unreachable"
                      onClick={() => setUnreachableModelID(model.id)}
                    >
                      {tRoot(RELAY_CATALOG_TEXT.status.unreachable)}
                    </button>
                  )}
                  {row.trailing.map((item) => item === 'newChat' ? (
                    <button
                      key={item}
                      type="button"
                      className={`${styles.modelChatBtn} ${catalogPartStyles.trailingButton}`}
                      data-trailing="newChat"
                      onClick={() => handleChatWithModel(model)}
                      disabled={!canStartChatWithModel}
                      aria-label={tr('chatWithModel', { model: model.name })}
                      title={tr('chatWithModel', { model: model.name })}
                    >
                      <MessageCircle size={16} strokeWidth={2.2} aria-hidden="true" />
                    </button>
                  ) : item === 'more' ? (
                    <RelayCatalogMoreMenu
                      key={item}
                      items={row.menu}
                      buttonClassName={`${styles.modelChatBtn} ${catalogPartStyles.trailingButton}`}
                      onRemove={() => handleRemoveEnabledModel(model)}
                    />
                  ) : null)}
                </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Single-key catalog fetch failed: a full-width failure card with only Retry inside; an existing old catalog still shows below */}
      {catalogLoadState === 'loading' ? (
        <div className={styles.section} role="status">
          <div className={styles.sectionLabel}>{t('modelCatalog')}</div>
          <div className={styles.catalogStateCard}>{tc('loading')}</div>
        </div>
      ) : catalogLayout.failureCard ? (
        <div className={styles.section} role="alert" data-catalog-failure-card>
          <div className={catalogPartStyles.failureCard}>
            <div className={catalogPartStyles.failureTitle}>{tRoot('pages.relayDetail.catalogFetchFailedTitle')}</div>
            <div className={catalogPartStyles.failureReason}>{tRoot(relayCatalogFailureReasonKey(provider))}</div>
            <button type="button" className={catalogPartStyles.failureRetry} onClick={() => { void refreshRelayCatalog(); }}>
              {tRoot('common.retry')}
            </button>
          </div>
        </div>
      ) : null}

      {(keyStrip.length > 0 || catalogLayout.showLibrary) && (
        <div className={styles.section} data-catalog-section="library">
          {/* Section order: key status bar -> "Model library - N" header -> groups (2 or more keys; a failed key's Retry refreshes only that key; shown even when the catalog is empty) */}
          <RelayCatalogKeyStrip items={keyStrip} onRetry={retryCatalogKey} disabled={isSyncing} />
          {catalogLayout.showLibrary && (
            <div className={styles.sectionHeader}>
              <div className={styles.sectionHeaderLeft}>
                <div className={styles.sectionLabel}>
                  {tRoot(RELAY_CATALOG_TEXT.sectionLibrary, { count: catalogBoard.library.count })}
                </div>
              </div>
            </div>
          )}
          {catalogLayout.showLibrary && (
            <>
              <ModelBrowser
                catalogModels={catalogBoard.library.rows.map((row) => row.model)}
                popularitySourceModels={provider.catalogModels}
                providerKind="relay"
                providerLabel={providerDisplayName}
                provider={provider}
                onToggleModel={handleCatalogToggleModel}
                onOpenRow={openReadOnlyAdvanced}
                preserveCatalogOrder
                hideBrowseChrome
                relayRows={catalogLibraryRows}
                relayAddAll={{
                  modelIDs: (models) => relayCatalogEnableAllModelIDs(provider, models),
                  onAddAll: handleAddAllGroup,
                }}
              />
              {catalogLayout.enableHint && (
                <p className={styles.sectionHint} data-catalog-enable-hint>
                  {tRoot(RELAY_CATALOG_TEXT.enableHint[catalogLayout.enableHint])}
                </p>
              )}
            </>
          )}
        </div>
      )}

      {/* The only manual add on the page */}
      <div className={catalogPartStyles.footerActions}>
        <Button tone="secondary" size="sm" onClick={() => setShowAddModels(true)}>
          <PlusIcon size={14} weight="bold" aria-hidden="true" />
          {tRoot('pages.relaySetup.twoStep.addModelManually')}
        </Button>
      </div>

      {provider.models.length + libraryModels.length > 0 && <RelayCatalogLegend />}

      </fieldset>

      {unreachableModelID && unreachable?.phase === 'failed' && (
        <div className={styles.confirmOverlay} onClick={() => setUnreachableModelID(null)}>
          <div
            className={styles.confirmDialog}
            role="dialog"
            aria-modal="true"
            aria-label={tRoot('pages.relayDetail.catalogUnreachableTitle')}
            onClick={(event) => event.stopPropagation()}
          >
            <div className={styles.confirmTitle}>{tRoot('pages.relayDetail.catalogUnreachableTitle')}</div>
            <div className={styles.confirmDesc}>
              {[
                unreachable.statusCode,
                unreachable.error !== undefined ? extractPingErrorMessage(unreachable.error, te) : undefined,
              ].filter((part) => part !== undefined && part !== '').join(' · ')}
            </div>
            <div className={styles.confirmActions}>
              <Button tone="secondary" size="sm" onClick={() => setUnreachableModelID(null)}>
                {tc('close')}
              </Button>
            </div>
          </div>
        </div>
      )}
        </>
        );
      })()}

      {view === 'web' && (
        <RelayWebSearchPage
          provider={provider}
          connectionName={providerDisplayName}
          backLabel={tc('back')}
          onBack={navigateBack}
          onSaved={() => {
            setWebSearchRevision((revision) => revision + 1);
            navigateBack();
          }}
          disabled={isSyncing}
        />
      )}

      {view === 'keys' && (
        <RelayKeysPage
          provider={provider}
          backLabel={tc('back')}
          onBack={navigateBack}
          onReplaceImplicitKey={() => setShowKeyDialog(true)}
          onOpenLibrary={(keyID) => navigateTo({ view: 'library', keyID })}
          pageState={keysPageState}
          onPageStateChange={setKeysPageState}
          validateKey={validateApiKeyDraft}
          disabled={isSyncing}
        />
      )}

      {view === 'advanced' && advancedBoard && advancedModel && (
        <fieldset className={styles.relayReconnectGuard} disabled={isSyncing}>
          <RelayModelAdvanced
            board={advancedBoard}
            backLabel={tc('back')}
            onBack={navigateBack}
            onRestoreAll={restoreAdvanced}
            onSelectSegment={selectAdvancedSegment}
            onSetControl={setAdvancedControl}
            onToggleLevel={toggleAdvancedLevel}
            onTestCapabilities={() => runCapabilityTest(advancedModel, advancedBoard.keySection?.current.title ?? null)}
            onSelectKey={selectAdvancedKey}
            disabled={isSyncing}
          />
        </fieldset>
      )}

      {/* Bulk add models modal */}
      {showAddModels && (
        <div className={styles.confirmOverlay} onClick={() => setShowAddModels(false)}>
          <div className={styles.addModelsDialog} onClick={(e) => e.stopPropagation()}>
            <div className={styles.confirmTitle}>{tr('addModelsTitle')}</div>
            <div className={styles.confirmDesc}>{tr('addModelsHint')}</div>
            <textarea
              className={styles.modelTextarea}
              value={modelInput}
              onChange={(e) => setModelInput(e.target.value)}
              placeholder={tr('addModelsPlaceholder')}
              rows={6}
              autoFocus
            />
            <div className={styles.confirmActions}>
              <Button tone="secondary" size="sm" onClick={() => {
                setShowAddModels(false);
                setModelInput('');
              }}>
                {tc('cancel')}
              </Button>
              <Button tone="primary" size="sm" onClick={handleAddModels} disabled={newModelIds.length === 0}>
                {tr('addModelsConfirm', { count: newModelIds.length })}
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* Confirm delete */}
      {showConfirmDelete && (
        <ConfirmDeleteDialog
          title={tr('confirmDeleteTitle', { name: providerDisplayName })}
          description={tr('confirmDeleteDesc')}
          onConfirm={deleteProvider}
          onCancel={() => setShowConfirmDelete(false)}
        />
      )}

      {/* Test capability: bottom panel */}
      {capabilityTestPanel && (
        <RelayCapabilityTestPanel
          modelName={capabilityTestPanel.modelName}
          state={capabilityTestPanel.state}
          onCancel={cancelCapabilityTest}
          onDone={closeCapabilityTest}
        />
      )}

      {showParameters && provider.models.length > 0 && (
        <RelayParametersDialog
          provider={provider}
          models={provider.models}
          initialModelID={parametersDefaultModelID}
          onClose={() => setShowParameters(false)}
        />
      )}

      {showKeyDialog && (
        <RelayApiKeyDialog
          hasSavedKey={hasStoredKey}
          placeholder={relayFormFieldDefinition('api_key')?.placeholder ?? ''}
          onValidate={validateApiKeyDraft}
          onSave={saveRelayKey}
          onRemove={() => { void removeKey(); }}
          onClose={() => setShowKeyDialog(false)}
          disabled={isSyncing}
        />
      )}
    </div>
  );
}
