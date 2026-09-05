'use client';

import { useEffect, useState, useMemo, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { AlertTriangle, Brain, GitBranch, MessageCircle, Search, SlidersHorizontal, Wrench } from 'lucide-react';
import type { AIModel, Provider, RelayAuthMode, RelayKind, RelayRequestedConfig, RelayTransport, RelayWebSearchToolName } from '@oriveo/shared';
import {
  compatibleRelayKinds,
  inferModelFamily,
  inferRelayKind,
  makeRelayRequested,
  suggestedRelayKind,
} from '@oriveo/shared';
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
import { Button, BackArrowIcon, CloseIcon } from '@oriveo/ui';
import { RelayPrivacyNotice } from '../../../components/providers/RelayPrivacyNotice';
import { RelayKeyValueEditor } from '../../../components/providers/RelayKeyValueEditor';
import { RelaySecurityModeControl } from '../../../components/providers/RelaySecurityModeControl';
import { useProviderActions } from '../../../lib/hooks/useProviderActions';
import { useAppStore } from '../../../providers/StoreProvider';
import { getProviderInstanceDisplayName } from '../../../lib/core/providers/provider-display';
import { createRelayManualModel } from '../../../lib/core/provider-model-ops';
import { resolveRelayRuntimeFields } from '../../../lib/core/providers/relay-resolution';
import {
  isCleartextRelayConnection,
  relayProviderCredentialState,
} from '../../../lib/core/providers/relay-runtime-support';
import {
  extractPingErrorMessage,
  extractRelayPingFailureDetails,
} from '../../../lib/core/providers/ping-relay';
import { relayFormIssueMessage } from '../../../lib/core/providers/relay-form-messages';
import { hasRelayConnectedEvidence } from '../../../lib/core/providers/probe/probe-runner';
import { ModelMetaInline } from '../../../components/chat/ModelMetaInline';
import { ConfirmDeleteDialog } from './components/ConfirmDeleteDialog';
import { EditableProviderName } from './components/EditableProviderName';
import { ProviderConnectionRecoveryCard } from './components/ProviderConnectionRecoveryCard';
import { getEffectiveStatusKind, isEffectiveWarning } from '../../../lib/core/providers/provider-status';
import { useProviderChatLauncher } from './useProviderChatLauncher';
import { RelayEditorHeroCard } from './components/RelayEditorHeroCard';
import { RelayConnectionCard } from './components/RelayConnectionCard';
import { RelayPresetModeInfoCard } from './components/RelayPresetModeInfoCard';
import { RelayTintedSection } from './components/RelayTintedSection';
import { ModelBrowser } from './ModelBrowser';
import { GenerationParameterPanel } from '../../../components/generation/GenerationParameterPanel';
import styles from './ProviderDetail.module.css';

interface RelayDetailProps {
  provider: Provider;
}

export function RelayDetail({ provider }: RelayDetailProps) {
  const router = useRouter();
  const tr = useTranslations('pages.relayDetail');
  const tSetup = useTranslations('pages.relaySetup');
  const tc = useTranslations('common');
  const t = useTranslations('pages.providerDetail');
  const te = useTranslations('errors');
  /** Form issue text keys carry a namespace (the same map the add flow uses), so they resolve with the root translator. */
  const tRoot = useTranslations();

  const {
    isSyncing,
    catalogLoadState,
    relaySettingsSaveFailure,
    saveKey,
    removeKey,
    clearRelayCredentials,
    saveBaseURL,
    writeBackBaseURL,
    saveName,
    saveRelaySettings,
    relaySettingsSavePlan,
    saveRelaySettingsUnverified,
    retryRelaySettingsSave,
    clearRelaySettingsSaveFailure,
    refreshRelayCatalog,
    reconnectRelaySecurityMode,
    verifyRelayConnection,
    addModels,
    removeModel,
    toggleModel,
    deleteProvider,
  } = useProviderActions(provider);

  // Credential state comes only from authMode plus what the key store actually holds, never from whether apiKeyPreview is empty
  const credentialState = relayProviderCredentialState(provider);
  const isCleartextConnection = isCleartextRelayConnection(provider.relayRequested?.securityMode);

  const { startChatWithModel: handleChatWithModel } = useProviderChatLauncher(provider);

  const [showConfirmDelete, setShowConfirmDelete] = useState(false);
  const [showAddModels, setShowAddModels] = useState(false);
  const [expandedGenerationModelId, setExpandedGenerationModelId] = useState<string | null>(null);
  const [modelInput, setModelInput] = useState('');
  const [dismissedRecoveryCard, setDismissedRecoveryCard] = useState(false);
  const initialKind = provider.relayKind ?? inferRelayKind(provider.relayRequested, provider.baseURLText);
  const [draftKind, setDraftKind] = useState<RelayKind>(initialKind);
  const [draftRequested, setDraftRequested] = useState<RelayRequestedConfig>(
    () => provider.relayRequested ?? makeRelayRequested(initialKind),
  );
  const draftSecurityMode = draftRequested.securityMode ?? 'remote_https';
  const savedRequested = provider.relayRequested ?? makeRelayRequested(initialKind);
  const draftHasCredentialMaterial = relayHasCredentialMaterialAcross([
    {
      authMode: savedRequested.authMode,
      hasStoredKey: (provider.apiKey ?? '').trim().length > 0,
      headers: savedRequested.headers,
      queryParams: savedRequested.queryParams,
    },
    {
      authMode: draftRequested.authMode,
      hasStoredKey: false,
      headers: draftRequested.headers,
      queryParams: draftRequested.queryParams,
    },
  ]);
  const [undoDraft, setUndoDraft] = useState<{ kind: RelayKind; requested: RelayRequestedConfig } | null>(null);
  const [pendingKindChange, setPendingKindChange] = useState<RelayKind | null>(null);
  const [pingState, setPingState] = useState<'idle' | 'checking' | 'ok' | 'error'>('idle');
  const [endpointNormalizationVersion, setEndpointNormalizationVersion] = useState(0);
  const [normalizedEndpointToReveal, setNormalizedEndpointToReveal] = useState<string | undefined>();
  /** On ok, "Connected via {endpoint}." / "Connected via {endpoint}. {n} model(s) reachable."; on error, a plain-language message */
  const [pingMessage, setPingMessage] = useState<string | null>(null);

  const relayKindLabel = (kind: RelayKind): string => {
    switch (kind) {
      case 'openai_compatible': return tSetup('kind.openai.title');
      case 'codex_style': return tSetup('kind.codex.title');
      case 'anthropic_compatible': return tSetup('kind.anthropic.title');
      case 'gemini_compatible': return tSetup('kind.gemini.title');
      case 'custom': return tSetup('kind.custom.title');
    }
  };

  const parsedModelIds = useMemo(() => {
    const lines = modelInput.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
    return [...new Set(lines)];
  }, [modelInput]);

  const newModelIds = useMemo(() => {
    const existingIds = new Set(provider.models.map((m) => m.id));
    return parsedModelIds.filter((id) => !existingIds.has(id));
  }, [parsedModelIds, provider.models]);
  const libraryModels = useMemo(() => {
    const enabledIDs = new Set(provider.models.map((model) => model.id));
    return provider.catalogModels.filter((model) => !enabledIDs.has(model.id));
  }, [provider.catalogModels, provider.models]);

  const providerDisplayName = getProviderInstanceDisplayName(provider);
  const defaultRelayModelId = provider.models.find((model) => model.isDefault)?.id
    ?? provider.models[0]?.id
    ?? null;
  const selectedDefaultModelId = draftRequested.modelID ?? defaultRelayModelId ?? '';
  const defaultModelOptions = useMemo(() => {
    const options = [...provider.catalogModels];
    if (selectedDefaultModelId && !options.some((model) => model.id === selectedDefaultModelId)) {
      const enabledModel = provider.models.find((model) => model.id === selectedDefaultModelId);
      options.unshift(enabledModel ?? createRelayManualModel(selectedDefaultModelId, true));
    }
    return options;
  }, [provider.catalogModels, provider.models, selectedDefaultModelId]);

  const handleAddModels = () => {
    if (newModelIds.length === 0) return;
    addModels(newModelIds);
    setModelInput('');
    setShowAddModels(false);
  };

  const modelForSuggestion = defaultRelayModelId
    ?? draftRequested.modelID
    ?? '';
  const inferredFamily = inferModelFamily(modelForSuggestion);
  const compatibleKinds = compatibleRelayKinds(inferredFamily);
  const suggestedKind = compatibleKinds.length > 0 && !compatibleKinds.includes(draftKind)
    ? suggestedRelayKind(inferredFamily)
    : null;

  useEffect(() => {
    if (!undoDraft) return;
    const timer = window.setTimeout(() => setUndoDraft(null), 5000);
    return () => window.clearTimeout(timer);
  }, [undoDraft]);

  // Any field edit invalidates the previous test result, so it is reset immediately rather than left to mislead
  useEffect(() => {
    setPingState('idle');
    setPingMessage(null);
    clearRelaySettingsSaveFailure();
  }, [clearRelaySettingsSaveFailure, draftKind, draftRequested]);

  const requestKindChange = (kind: RelayKind) => {
    if (kind === draftKind) return;
    setPendingKindChange(kind);
  };

  const confirmKindChange = () => {
    if (!pendingKindChange) return;
    setUndoDraft({ kind: draftKind, requested: draftRequested });
    setDraftRequested(makeRelayRequested(pendingKindChange, draftRequested));
    setDraftKind(pendingKindChange);
    setPendingKindChange(null);
  };

  const cancelKindChange = () => setPendingKindChange(null);

  const applySuggestedKind = () => {
    if (!suggestedKind) return;
    setUndoDraft({ kind: draftKind, requested: draftRequested });
    setDraftKind(suggestedKind);
    setDraftRequested(makeRelayRequested(suggestedKind, draftRequested));
  };

  const handleUndoKind = () => {
    if (!undoDraft) return;
    setDraftKind(undoDraft.kind);
    setDraftRequested(undoDraft.requested);
    setUndoDraft(null);
  };

  // Clearing the key when authMode switches to none happens inside `updateProviderRelaySettings`:
  // it has to ride the same write as the settings themselves, because with two separate writes the
  // second one's sync pushes the just-deleted key back to the cloud.
  /**
   * Draft state for the edit form. Editing is the same form in a pre-filled state, so the address is
   * validated against this connection's own `securityMode`; validating everything against the
   * default `remote_https` marked a local-engine `http://` endpoint permanently invalid and made
   * even a rename unsaveable. An empty key field means the key is left unchanged.
   */
  const editDraft = useCallback((patch: Partial<RelayFormDraft> = {}): RelayFormDraft => ({
    endpoint: provider.baseURLText ?? '',
    apiKey: '',
    authMode: draftRequested.authMode,
    securityMode: draftRequested.securityMode ?? 'remote_https',
    transport: draftRequested.transport,
    modelID: draftRequested.modelID ?? '',
    headers: draftRequested.headers ?? [],
    queryParams: draftRequested.queryParams ?? [],
    // Whether a key exists is answered by the key store itself, not by the apiKeyPreview display string
    hasSavedCredential: (provider.apiKey ?? '').trim().length > 0,
    ...patch,
  }), [draftRequested, provider.apiKey, provider.baseURLText]);

  /** First issue that needs a sentence of explanation; required-field issues only disable the button and show no inline error. */
  const firstSpeakableIssue = useCallback(
    (issues: readonly RelayFormIssue[]): string | null => {
      const blocking = displayableRelayFormIssues(issues)[0];
      return blocking ? relayFormIssueMessage(blocking, tRoot) : null;
    },
    [tRoot],
  );

  const validateEndpointDraft = useCallback(
    (raw: string): { ok: true; normalized: string } | { ok: false; message: string } => {
      const draft = editDraft({ endpoint: raw });
      const message = firstSpeakableIssue(validateRelayForm(draft, 'edit'));
      if (message) return { ok: false, message };
      const normalized = relayFormNormalizedEndpoint(draft, 'edit');
      // Anything left can only be a required-field issue (an empty address), which has no inline error, just this static hint.
      return normalized ? { ok: true, normalized } : { ok: false, message: tr('endpointEmpty') };
    },
    [editDraft, firstSpeakableIssue, tr],
  );

  const validateApiKeyDraft = useCallback(
    (raw: string): { ok: true } | { ok: false; message: string } => {
      const message = firstSpeakableIssue(validateRelayForm(editDraft({ apiKey: raw }), 'edit'));
      return message ? { ok: false, message } : { ok: true };
    },
    [editDraft, firstSpeakableIssue],
  );

  const buildRelayConfigPatch = useCallback((normalizedEndpoint: string) => {
    const nextDefaultModelID = (draftRequested.modelID ?? defaultRelayModelId ?? '').trim();
    const relayRequested: RelayRequestedConfig = {
      ...draftRequested,
      modelID: nextDefaultModelID || undefined,
    };
    const catalogDefault = provider.catalogModels.find((model) => model.id === nextDefaultModelID);
    const models = nextDefaultModelID
      ? provider.models.some((model) => model.id === nextDefaultModelID)
        ? provider.models.map((model) => ({ ...model, isDefault: model.id === nextDefaultModelID }))
        : [
            ...provider.models.map((model) => ({ ...model, isDefault: false })),
            catalogDefault
              ? { ...catalogDefault, isDefault: true }
              : createRelayManualModel(nextDefaultModelID, true),
          ]
      : provider.models;
    const relayRuntime = resolveRelayRuntimeFields({
      baseURLText: normalizedEndpoint,
      relayRequested,
    });
    return {
      relayKind: draftKind,
      relayRequested,
      models,
      ...relayRuntime,
    };
  }, [defaultRelayModelId, draftKind, draftRequested, provider.catalogModels, provider.models]);

  const relayConfigSavePlan = relaySettingsSavePlan(
    buildRelayConfigPatch((provider.baseURLText ?? '').trim()),
  );

  const saveRelayConfig = async () => {
    const draft = editDraft();
    const issues = validateRelayForm(draft, 'edit');
    const message = firstSpeakableIssue(issues);
    const normalizedEndpoint = relayFormNormalizedEndpoint(draft, 'edit');
    if (message || !normalizedEndpoint) {
      setPingState('error');
      setPingMessage(message ?? tr('endpointEmpty'));
      return;
    }
    setPingState('checking');
    const saved = await saveRelaySettings(buildRelayConfigPatch(normalizedEndpoint));
    if (saved) {
      setPingState('ok');
      setPingMessage(relayConfigSavePlan.needsVerification ? tr('testRelayPassed') : null);
    } else {
      setPingState('error');
      setPingMessage(tr('testRelayFailed'));
    }
  };

  const changeSecurityMode = async (input: {
    mode: Exclude<NonNullable<RelayRequestedConfig['securityMode']>, 'tofu_https'>;
    normalizedEndpoint: string;
  }) => {
    const cleartext = input.mode === 'local_http' || input.mode === 'private_vpn';
    const nextRequested: RelayRequestedConfig = {
      ...draftRequested,
      securityMode: input.mode,
      resolvedAPIBaseURL: undefined,
      ...(cleartext
        ? {
            authMode: 'none',
            ...(draftHasCredentialMaterial ? { headers: undefined, queryParams: undefined } : {}),
          }
        : {}),
    };
    setDraftRequested(nextRequested);
    if (input.normalizedEndpoint !== (provider.baseURLText ?? '').trim()) {
      setNormalizedEndpointToReveal(input.normalizedEndpoint);
      setEndpointNormalizationVersion((version) => version + 1);
    }
    setPingState('checking');
    setPingMessage(null);
    const result = await reconnectRelaySecurityMode({
      securityMode: input.mode,
      normalizedEndpoint: input.normalizedEndpoint,
      modelID: defaultRelayModelId ?? nextRequested.modelID ?? '',
      unverifiedMessage: tSetup('connectionUnverified'),
      requested: nextRequested,
    });
    if (!result) return;
    if (result.state === 'verified' && hasRelayConnectedEvidence(result.detection)) {
      setPingState('ok');
      setPingMessage(tr('connectionTypeReconnected'));
      return;
    }
    setPingState('error');
    setPingMessage(result.diagnostic ?? tSetup('noProtocolVerified'));
  };

  const switchConflictToHttps = () => {
    const explicitHttps = (provider.baseURLText ?? '').replace(/^http:\/\//i, 'https://');
    const normalizedEndpoint = normalizeEndpointForSecurityMode(explicitHttps, 'remote_https');
    if (!normalizedEndpoint) {
      setPingState('error');
      setPingMessage(tr('connectionTypeInvalidAddress'));
      return;
    }
    void changeSecurityMode({ mode: 'remote_https', normalizedEndpoint });
  };


  const testRelayConnection = async () => {
    // Pre-flight validation matches RelaySetup.handleTestConnection
    const endpointCheck = validateEndpointDraft(provider.baseURLText ?? '');
    if (!endpointCheck.ok) {
      setPingState('error');
      setPingMessage(endpointCheck.message);
      return;
    }
    const savedEndpoint = (provider.baseURLText ?? '').trim();
    const trimmedEndpoint = endpointCheck.normalized;
    if (trimmedEndpoint !== savedEndpoint) {
      await writeBackBaseURL(trimmedEndpoint);
      setNormalizedEndpointToReveal(trimmedEndpoint);
      setEndpointNormalizationVersion((version) => version + 1);
    }
    const apiKey = provider.apiKey;
    // A stored key runs through the same checks, so fetch() cannot throw "String contains non ISO-8859-1 code point"
    const keyCheck = validateApiKeyDraft(apiKey ?? '');
    if (!keyCheck.ok) {
      setPingState('error');
      setPingMessage(keyCheck.message);
      return;
    }

    setPingState('checking');
    setPingMessage(null);
    try {
      // Only a saved configuration can be tested; an in-progress relay settings draft must never
      // contaminate the existing state. A just-normalised address has already been written back
      // above, so candidate reflects the canonical address as persisted.
      const savedCandidate: Provider = trimmedEndpoint === savedEndpoint
        ? provider
        : { ...provider, baseURLText: trimmedEndpoint };
      const result = await verifyRelayConnection(savedCandidate);
      if (!result) return;
      setPingState('ok');
      // On success the message carries probedEndpoint, and the chat_completions path also carries modelCount
      setPingMessage(
        result.modelCount > 0
          ? tr('testRelayConnectedWithModels', { endpoint: result.probedEndpoint, count: result.modelCount })
          : tr('testRelayConnected', { endpoint: result.probedEndpoint }),
      );
    } catch (error) {
      setPingState('error');
      // pingRelay throws a ProviderError plain object rather than an Error instance, so String(error)
      // would produce "[object Object]"; extractPingErrorMessage handles it.
      setPingMessage(extractPingErrorMessage(error, te));
    }
  };

  const saveRelayKey = async (newKey: string) => {
    const endpointCheck = validateEndpointDraft(provider.baseURLText ?? '');
    if (!endpointCheck.ok) {
      setPingState('error');
      setPingMessage(endpointCheck.message);
      return;
    }
    if (endpointCheck.normalized !== (provider.baseURLText ?? '').trim()) {
      setNormalizedEndpointToReveal(endpointCheck.normalized);
      setEndpointNormalizationVersion((version) => version + 1);
    }
    await saveKey(newKey, endpointCheck.normalized);
  };

  const testResult: { ok: boolean; message: string } | null =
    pingState === 'ok' ? { ok: true, message: pingMessage ?? tr('testRelayPassed') }
    : pingState === 'error' ? { ok: false, message: pingMessage ?? tr('testRelayFailed') }
    : null;

  const codexIdentityChecked = draftRequested.transport === 'openai_responses'
    ? draftRequested.codexCompatIdentity !== false
    : draftRequested.codexCompatIdentity === true;

  const isCustom = draftKind === 'custom';
  const showWebSearchTool = draftRequested.transport === 'openai_responses';

  return (
    <div className={styles.page}>
      {/* Header */}
      <div className={styles.header}>
        <button className={styles.backBtn} onClick={() => router.push('/providers')} aria-label={tc('back')}>
          <BackArrowIcon />
        </button>
        <h1 className={styles.title}>{providerDisplayName}</h1>
      </div>

      {isEffectiveWarning(getEffectiveStatusKind(provider)) && !dismissedRecoveryCard && (
        <ProviderConnectionRecoveryCard
          provider={provider}
          onEditApiKey={() => {
            // Scroll to the RelayConnectionCard
            document.getElementById('relay-connection-card')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
          }}
          onRetryConnection={() => { void testRelayConnection(); }}
          onDismiss={() => setDismissedRecoveryCard(true)}
          disabled={isSyncing}
        />
      )}

      {/* Hero — gradient brand card with badge / kind pill / status / endpoint preview */}
      <RelayEditorHeroCard
        provider={provider}
        endpointText={provider.baseURLText ?? null}
        relayKind={draftKind}
        onChangeKind={() => {
          const selectEl = typeof document !== 'undefined'
            ? document.querySelector<HTMLSelectElement>('select[aria-label="relayType"], select#relay-kind')
            : null;
          selectEl?.focus();
          selectEl?.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }}
        nameSlot={
          <EditableProviderName
            name={providerDisplayName}
            onSave={saveName}
            editLabel={tr('editName')}
            saveLabel={tr('saveName')}
            cancelLabel={tc('cancel')}
            disabled={isSyncing}
          />
        }
      />

      {/* Connection - the combined endpoint / API Key / Test connection card */}
      <div id="relay-connection-card">
        <RelayConnectionCard
          endpoint={provider.baseURLText ?? ''}
          endpointPlaceholder={relayFormFieldDefinition('endpoint')?.placeholder ?? ''}
          apiKeyPlaceholder={relayFormFieldDefinition('api_key')?.placeholder ?? ''}
          endpointNormalizationVersion={endpointNormalizationVersion}
          normalizedEndpointToReveal={normalizedEndpointToReveal}
          connectionTypeSlot={(
            <RelaySecurityModeControl
              value={draftSecurityMode}
              endpoint={provider.baseURLText ?? ''}
              hasCredentialMaterial={draftHasCredentialMaterial}
              onChange={changeSecurityMode}
              busy={isSyncing}
            />
          )}
          onSaveEndpoint={saveBaseURL}
          onValidateEndpoint={validateEndpointDraft}
          onValidateApiKey={validateApiKeyDraft}
          credentialState={credentialState}
          isCleartext={isCleartextConnection}
          apiKeyPreview={provider.apiKeyPreview}
          onSaveApiKey={saveRelayKey}
          onRemoveApiKey={removeKey}
          onClearCredentials={clearRelayCredentials}
          onSwitchToHttps={switchConflictToHttps}
          onTestConnection={testRelayConnection}
          isTestingConnection={pingState === 'checking'}
          testResult={testResult}
          isSubmitting={isSyncing}
        />
      </div>

      <fieldset className={styles.relayReconnectGuard} disabled={isSyncing}>

      {/* Type — section without tint, default model is owned by the model list below */}
      <div className={styles.section}>
        <div className={styles.sectionHeader}>
          <div className={styles.sectionHeaderLeft}>
            <div className={styles.sectionLabel}>{tr('relaySettings')}</div>
            <div className={styles.sectionHint}>{tr('relaySettingsHint')}</div>
          </div>
          <Button tone="primary" size="sm" onClick={() => { void saveRelayConfig(); }}>
            {relayConfigSavePlan.needsVerification ? tr('verifyAndSave') : tr('saveRelaySettings')}
          </Button>
        </div>

        {suggestedKind && (
          <div className={styles.relaySuggestion}>
            <div className={styles.relaySuggestionText}>
              {tr('modelKindSuggestionDetail', {
                model: modelForSuggestion,
                current: relayKindLabel(draftKind),
                suggested: relayKindLabel(suggestedKind),
              })}
            </div>
            <div className={styles.relaySuggestionActions}>
              <Button tone="secondary" size="sm" onClick={applySuggestedKind}>{tr('applySuggestedKind')}</Button>
            </div>
          </div>
        )}

        {undoDraft && (
          <div className={styles.relaySuggestion}>
            <div className={styles.relaySuggestionText}>{tr('kindChangeApplied')}</div>
            <div className={styles.relaySuggestionActions}>
              <Button tone="secondary" size="sm" onClick={handleUndoKind}>{tr('undoKindChange')}</Button>
            </div>
          </div>
        )}

        <div className={styles.relayConfigGrid}>
          <label className={styles.relayField}>
            <span>{tr('relayType')}</span>
            <select
              id="relay-kind"
              className={styles.relaySelect}
              value={draftKind}
              onChange={(e) => requestKindChange(e.target.value as RelayKind)}
            >
              <option value="openai_compatible">{tSetup('kind.openai.title')}</option>
              <option value="codex_style">{tSetup('kind.codex.title')}</option>
              <option value="anthropic_compatible">{tSetup('kind.anthropic.title')}</option>
              <option value="gemini_compatible">{tSetup('kind.gemini.title')}</option>
              <option value="custom">{tSetup('kind.custom.title')}</option>
            </select>
          </label>
          {catalogLoadState === 'loaded' && provider.catalogModels.length > 0 && (
            <label className={styles.relayField}>
              <span>{tSetup('defaultModelLabel')}</span>
              <select
                className={styles.relaySelect}
                aria-label={tSetup('defaultModelLabel')}
                value={selectedDefaultModelId}
                onChange={(event) => setDraftRequested((previous) => ({
                  ...previous,
                  modelID: event.target.value || undefined,
                }))}
              >
                {!selectedDefaultModelId && (
                  <option value="">{tSetup('defaultModelOptional')}</option>
                )}
                {defaultModelOptions.map((model) => (
                  <option key={model.id} value={model.id}>
                    {model.name === model.id ? model.id : `${model.name} - ${model.id}`}
                  </option>
                ))}
              </select>
            </label>
          )}
          {catalogLoadState !== 'loading'
            && (catalogLoadState !== 'loaded' || provider.catalogModels.length === 0) && (
            <label className={styles.relayField}>
              <span>{tSetup('defaultModelLabel')}</span>
              <input
                className={styles.relayInput}
                aria-label={tSetup('defaultModelLabel')}
                value={selectedDefaultModelId}
                placeholder={tSetup('defaultModelPlaceholder')}
                onChange={(event) => setDraftRequested((previous) => ({
                  ...previous,
                  modelID: event.target.value || undefined,
                }))}
                autoComplete="off"
                spellCheck={false}
              />
              {catalogLoadState === 'failed' && <small>{tr('catalogFetchFailedHint')}</small>}
            </label>
          )}
        </div>
      </div>

      {relaySettingsSaveFailure && (
        <RelaySettingsFailureCard
          error={relaySettingsSaveFailure.error}
          canSaveUnverified={relaySettingsSaveFailure.canSaveUnverified}
          apiKey={provider.apiKey}
          relayRequested={draftRequested}
          onRetry={() => { void retryRelaySettingsSave(); }}
          onSaveUnverified={() => { void saveRelaySettingsUnverified(); }}
        />
      )}

      {/* Not custom: point the user at switching to fully custom */}
      {!isCustom && (
        <RelayPresetModeInfoCard
          relayKind={draftKind}
          onSwitchToCustom={() => requestKindChange('custom')}
        />
      )}

      {/* custom: the Protocol / Behavior / Web Search / Advanced HTTP tinted sections */}
      {isCustom && (
        <>
          {/* Protocol — Transport + Auth Mode, indigo */}
          <RelayTintedSection
            title={tr('sectionProtocol')}
            Icon={GitBranch}
            tint="#6366F1"
            tintDark="#818CF8"
          >
            <div className={styles.relayConfigGrid}>
              <label className={styles.relayField}>
                <span>{tr('transport')}</span>
                <select
                  className={styles.relaySelect}
                  value={draftRequested.transport}
                  onChange={(e) => setDraftRequested((prev) => {
                    const nextTransport = e.target.value as RelayTransport;
                    const next = { ...prev, transport: nextTransport };
                    // Switching transport away from Responses clears webSearchToolName to avoid a ghost value (mirrors RelaySetup)
                    if (nextTransport !== 'openai_responses') {
                      next.webSearchToolName = undefined;
                    }
                    return next;
                  })}
                >
                  <option value="openai_chat_completions">OpenAI Chat Completions</option>
                  <option value="openai_responses">OpenAI Responses</option>
                  <option value="anthropic_messages">Anthropic Messages</option>
                  <option value="gemini_generate_content">Gemini generateContent</option>
                  <option value="auto">Auto</option>
                </select>
              </label>

              <label className={styles.relayField}>
                <span>{tr('authMode')}</span>
                <select
                  className={styles.relaySelect}
                  value={draftRequested.authMode}
                  onChange={(e) => setDraftRequested((prev) => ({ ...prev, authMode: e.target.value as RelayAuthMode }))}
                >
                  <option value="bearer">Bearer</option>
                  <option value="x_api_key">x-api-key</option>
                  <option value="x_goog_api_key">x-goog-api-key</option>
                  <option value="query_key">Query key</option>
                  <option value="none">{tr('authModeNone')}</option>
                  <option value="auto">Auto</option>
                </select>
              </label>
            </div>
          </RelayTintedSection>

          {/* Behavior — Reasoning / Tier / Stream / Storage / Codex identity, purple */}
          <RelayTintedSection
            title={tr('sectionBehavior')}
            Icon={Brain}
            tint="#8C5FF8"
            tintDark="#C4B5FD"
          >
            <div className={styles.relayConfigGrid}>
              <label className={styles.relayField}>
                <span>{tr('reasoningEffort')}</span>
                <select
                  className={styles.relaySelect}
                  value={draftRequested.reasoningEffort ?? 'automatic'}
                  onChange={(e) => setDraftRequested((prev) => ({
                    ...prev,
                    reasoningEffort: e.target.value as NonNullable<RelayRequestedConfig['reasoningEffort']>,
                  }))}
                >
                  <option value="automatic">Auto</option>
                  <option value="low">Low</option>
                  <option value="medium">Medium</option>
                  <option value="high">High</option>
                  <option value="xhigh">Maximum</option>
                </select>
              </label>

              <label className={styles.relayField}>
                <span>{tr('serviceTier')}</span>
                <input
                  className={styles.relayInput}
                  value={draftRequested.serviceTier ?? ''}
                  onChange={(e) => setDraftRequested((prev) => ({ ...prev, serviceTier: e.target.value || undefined }))}
                />
              </label>

              <label className={styles.relayCheckField}>
                <input
                  type="checkbox"
                  checked={draftRequested.stream !== false}
                  onChange={(e) => setDraftRequested((prev) => ({ ...prev, stream: e.target.checked }))}
                />
                <span>{tr('stream')}</span>
              </label>

              <label className={styles.relayCheckField}>
                <input
                  type="checkbox"
                  checked={draftRequested.disableResponseStorage === true}
                  onChange={(e) => setDraftRequested((prev) => ({ ...prev, disableResponseStorage: e.target.checked || undefined }))}
                />
                <span>{tr('disableResponseStorage')}</span>
              </label>

              <label className={`${styles.relayCheckField} ${styles.withSubtitle}`}>
                <input
                  type="checkbox"
                  checked={codexIdentityChecked}
                  disabled={draftRequested.transport !== 'openai_responses'}
                  onChange={(e) => setDraftRequested((prev) => ({ ...prev, codexCompatIdentity: e.target.checked }))}
                />
                <span className={styles.relayCheckLabelStack}>
                  <span>{tr('codexCompatIdentity')}</span>
                  <small className={styles.relayCheckSubtitle}>{tr('codexCompatIdentitySubtitle')}</small>
                </span>
              </label>
            </div>
          </RelayTintedSection>

          {/* Web Search - sky tint, covering hasWebSearch / profile / transportKind and, for Responses, webSearchToolName */}
          <RelayTintedSection
            title={tr('sectionWebSearch')}
            Icon={Search}
            tint="#0EA5E9"
            tintDark="#38BDF8"
          >
            <div className={styles.relayConfigGrid}>
              {/* Relay web-search capability declaration plus an explicit transport kind choice */}
              <label className={styles.relayCheckField}>
                <input
                  type="checkbox"
                  checked={draftRequested.hasWebSearch === true}
                  onChange={(e) => setDraftRequested((prev) => ({
                    ...prev,
                    hasWebSearch: e.target.checked || undefined,
                    // Turning web search off clears the profile as well, to avoid a ghost value
                    webSearchProfile: e.target.checked ? prev.webSearchProfile : undefined,
                  }))}
                />
                <span>{tr('relayHasWebSearch')}</span>
              </label>

              {draftRequested.hasWebSearch === true && (
                <label className={styles.relayField}>
                  <span>{tr('relayWebSearchProfile')}</span>
                  <select
                    className={styles.relaySelect}
                    value={draftRequested.webSearchProfile ?? ''}
                    onChange={(e) => setDraftRequested((prev) => ({
                      ...prev,
                      webSearchProfile: e.target.value || undefined,
                    }))}
                  >
                    <option value="">{tr('relayWebSearchProfileAuto')}</option>
                    <option value="oai_responses_web">oai_responses_web</option>
                    <option value="oai_web_tool">oai_web_tool</option>
                    <option value="ant_web_tool">ant_web_tool</option>
                    <option value="gem_web">gem_web</option>
                    <option value="gem_web_retrieval">gem_web_retrieval</option>
                    <option value="grok_responses_web">grok_responses_web</option>
                    <option value="qwen_web">qwen_web</option>
                    <option value="zhipu_web">zhipu_web</option>
                    <option value="or_web">or_web</option>
                    <option value="kimi_web_search">kimi_web_search</option>
                  </select>
                </label>
              )}

              <label className={styles.relayField}>
                <span>{tr('relayTransportKind')}</span>
                <select
                  className={styles.relaySelect}
                  value={draftRequested.transportKind ?? ''}
                  onChange={(e) => setDraftRequested((prev) => ({
                    ...prev,
                    transportKind: e.target.value || undefined,
                  }))}
                >
                  <option value="">{tr('relayTransportKindAuto')}</option>
                  <option value="openai_chat">openai_chat</option>
                  <option value="openai_responses">openai_responses</option>
                  <option value="anthropic_messages">anthropic_messages</option>
                  <option value="gemini_generate">gemini_generate</option>
                  <option value="dashscope_native">dashscope_native</option>
                </select>
              </label>

              {showWebSearchTool && (() => {
                const current: RelayWebSearchToolName = draftRequested.webSearchToolName ?? 'web_search';
                const hintText =
                  current === 'disabled'
                    ? tr('webSearchToolHintDisabled')
                    : current === 'web_search_preview'
                      ? tr('webSearchToolHintLegacy')
                      : tr('webSearchToolHintDefault');
                const hintClass = `${styles.fieldHint}${current === 'disabled' ? ` ${styles.fieldHintWarning}` : ''}`;
                return (
                  <label className={styles.relayField}>
                    <span>{tr('webSearchToolName')}</span>
                    <select
                      className={styles.relayInput}
                      value={current}
                      onChange={(e) => {
                        const next = e.target.value as RelayWebSearchToolName;
                        // The default value web_search is not written into the schema and stays undefined
                        setDraftRequested((prev) => ({
                          ...prev,
                          webSearchToolName: next === 'web_search' ? undefined : next,
                        }));
                      }}
                    >
                      <option value="web_search">web_search</option>
                      <option value="web_search_preview">web_search_preview</option>
                      <option value="disabled">{tr('webSearchToolDisabled')}</option>
                    </select>
                    <small className={hintClass}>{hintText}</small>
                  </label>
                );
              })()}
            </div>
          </RelayTintedSection>

          {/* Advanced HTTP — User-Agent / Headers / Query Params, amber */}
          <RelayTintedSection
            title={tr('sectionAdvancedHttp')}
            Icon={Wrench}
            tint="#F59E0B"
            tintDark="#FBBF24"
          >
            <div className={styles.relayConfigGrid}>
              <label className={styles.relayField}>
                <span>{tr('customUserAgent')}</span>
                <input
                  className={styles.relayInput}
                  value={draftRequested.customUserAgent ?? ''}
                  onChange={(e) => setDraftRequested((prev) => ({ ...prev, customUserAgent: e.target.value || undefined }))}
                />
              </label>

              <div className={styles.relayFieldFull}>
                <RelayKeyValueEditor
                  label={tr('headers')}
                  name="headers"
                  values={draftRequested.headers}
                  onChange={(headers) => setDraftRequested((prev) => ({ ...prev, headers }))}
                  addLabel={tr('addHeader')}
                  removeLabel={tr('removeHeader')}
                  keyPlaceholder={relayFormFieldDefinition('headers')?.placeholder ?? tr('keyPlaceholder')}
                  valuePlaceholder={tr('valuePlaceholder')}
                />
              </div>

              <div className={styles.relayFieldFull}>
                <RelayKeyValueEditor
                  label={tr('queryParams')}
                  name="queryParams"
                  values={draftRequested.queryParams}
                  onChange={(queryParams) => setDraftRequested((prev) => ({ ...prev, queryParams }))}
                  addLabel={tr('addQueryParam')}
                  removeLabel={tr('removeQueryParam')}
                  keyPlaceholder={relayFormFieldDefinition('query_params')?.placeholder ?? tr('keyPlaceholder')}
                  valuePlaceholder={tr('valuePlaceholder')}
                />
              </div>
            </div>
          </RelayTintedSection>
        </>
      )}

      {/* Model list */}
      <div className={styles.section}>
        <div className={styles.sectionHeader}>
          <div className={styles.sectionHeaderLeft}>
            <div className={styles.sectionLabel}>{tr('models')}</div>
            <div className={styles.sectionHint}>
              {tr('modelsCount', { count: provider.models.length })}
            </div>
          </div>
          {provider.models.length > 0 && (
            <Button tone="secondary" size="sm" onClick={() => setShowAddModels(true)}>
              {tr('addMoreModels')}
            </Button>
          )}
        </div>

        {provider.models.length === 0 ? (
          <div className={styles.relayEmptyModels}>
            <div className={styles.relayEmptyModelsText}>{tr('noModels')}</div>
            <div className={styles.relayEmptyModelsHint}>{tr('noModelsHint')}</div>
            <Button onClick={() => setShowAddModels(true)}>{tr('addModels')}</Button>
          </div>
        ) : (
          <div className={styles.modelList}>
            {provider.models.map((model) => (
              <div key={model.id} className={styles.modelRow}>
                <button
                  type="button"
                  className={styles.modelClickArea}
                  onClick={() => handleChatWithModel(model)}
                  aria-label={tr('chatWithModel', { model: model.name })}
                >
                  <div className={styles.modelTitleRow}>
                    <span className={styles.modelRowName}>{model.name}</span>
                    {catalogLoadState === 'loaded'
                      && model.isManual !== true
                      && !provider.catalogModels.some((candidate) => candidate.id === model.id) && (
                        <span className={styles.modelMissingBadge}>{tr('modelMissingFromCatalog')}</span>
                      )}
                  </div>
                  {model.id !== model.name && (
                    <span className={styles.modelRowId}>{model.id}</span>
                  )}
                  <ModelMetaInline
                    model={model}
                    provider={provider}
                    containerClassName={styles.modelRowMeta}
                    priceClassName={styles.modelPrice}
                  />
                </button>
                <div className={styles.modelActions}>
                  {/* The model behaviour entry is always visible and never conditionally rendered.
                      With nothing to show, the panel renders its own empty state; hiding the entry
                      is what produces "one entry says this relay has none, another says it does". */}
                  <button
                    type="button"
                    className={styles.modelChatBtn}
                    onClick={() => setExpandedGenerationModelId((current) => current === model.id ? null : model.id)}
                    aria-label={tc('modelBehavior')}
                    title={tc('modelBehavior')}
                    aria-expanded={expandedGenerationModelId === model.id}
                  >
                    <SlidersHorizontal size={16} strokeWidth={2.2} aria-hidden="true" />
                  </button>
                  <button
                    type="button"
                    className={styles.modelChatBtn}
                    onClick={() => handleChatWithModel(model)}
                    aria-label={tr('chatWithModel', { model: model.name })}
                    title={tr('chatWithModel', { model: model.name })}
                  >
                    <MessageCircle size={16} strokeWidth={2.2} aria-hidden="true" />
                  </button>
                  <button
                    type="button"
                    className={styles.removeBtn}
                    onClick={() => removeModel(model.id)}
                    aria-label={tr('removeModel')}
                  >
                    <CloseIcon />
                  </button>
                </div>
                {expandedGenerationModelId === model.id && (
                  <GenerationParameterPanel provider={provider} model={model} />
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {catalogLoadState === 'loading' ? (
        <div className={styles.section} role="status">
          <div className={styles.sectionLabel}>{t('modelCatalog')}</div>
          <div className={styles.catalogStateCard}>{tc('loading')}</div>
        </div>
      ) : catalogLoadState === 'failed' ? (
        <div className={styles.section} role="alert">
          <div className={styles.sectionHeader}>
            <div className={styles.sectionHeaderLeft}>
              <div className={styles.sectionLabel}>{tr('catalogFetchFailed')}</div>
              <div className={styles.sectionHint}>{tr('catalogFetchFailedHint')}</div>
            </div>
            <Button tone="secondary" size="sm" onClick={() => { void refreshRelayCatalog(); }}>
              {tc('retry')}
            </Button>
            <Button tone="secondary" size="sm" onClick={() => setShowAddModels(true)}>
              {tr('addModels')}
            </Button>
          </div>
        </div>
      ) : libraryModels.length > 0 ? (
        <div className={styles.section}>
          <div className={styles.sectionHeader}>
            <div className={styles.sectionHeaderLeft}>
              <div className={styles.sectionLabel}>{t('modelCatalog')}</div>
              <div className={styles.sectionHint}>{t('catalogCount', { count: libraryModels.length })}</div>
            </div>
          </div>
          <ModelBrowser
            catalogModels={libraryModels}
            popularitySourceModels={provider.catalogModels}
            providerKind="relay"
            providerLabel={providerDisplayName}
            provider={provider}
            onToggleModel={toggleModel}
            preserveCatalogOrder
          />
        </div>
      ) : null}

      <RelayPrivacyNotice />

      {/* Danger zone */}
      <div className={styles.dangerZone}>
        <div className={styles.dangerIntro}>
          <span className={styles.dangerIcon} aria-hidden="true">
            <AlertTriangle size={16} strokeWidth={2.2} />
          </span>
          <div className={styles.dangerLabel}>{t('dangerZone')}</div>
        </div>
        <Button tone="danger" size="sm" onClick={() => setShowConfirmDelete(true)}>
          {tr('deleteRelay')}
        </Button>
      </div>

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

      {/* Delete confirmation */}
      {showConfirmDelete && (
        <ConfirmDeleteDialog
          title={tr('confirmDeleteTitle', { name: providerDisplayName })}
          description={tr('confirmDeleteDesc')}
          onConfirm={deleteProvider}
          onCancel={() => setShowConfirmDelete(false)}
        />
      )}

      {/* Relay type change confirmation */}
      {pendingKindChange && (
        <div className={styles.confirmOverlay} onClick={cancelKindChange}>
          <div className={styles.confirmDialog} onClick={(e) => e.stopPropagation()}>
            <div className={styles.confirmTitle}>{tr('confirmKindChangeTitle')}</div>
            <div className={styles.confirmDesc}>
              {tr('confirmKindChangeDesc', {
                from: relayKindLabel(draftKind),
                to: relayKindLabel(pendingKindChange),
              })}
            </div>
            <div className={styles.confirmActions}>
              <Button tone="secondary" size="sm" onClick={cancelKindChange}>{tc('cancel')}</Button>
              <Button tone="primary" size="sm" onClick={confirmKindChange}>{tr('confirmKindChangeApply')}</Button>
            </div>
          </div>
        </div>
      )}
      </fieldset>
    </div>
  );
}

function RelaySettingsFailureCard({
  error,
  canSaveUnverified,
  apiKey,
  relayRequested,
  onRetry,
  onSaveUnverified,
}: {
  error: unknown;
  canSaveUnverified: boolean;
  apiKey: string;
  relayRequested: RelayRequestedConfig;
  onRetry: () => void;
  onSaveUnverified: () => void;
}) {
  const tr = useTranslations('pages.relayDetail');
  const tSetup = useTranslations('pages.relaySetup');
  const te = useTranslations('errors');
  const details = extractRelayPingFailureDetails(error, { apiKey, relayRequested });
  return (
    <section className={styles.relayVerificationFailure} role="alert">
      <strong>{tr('testRelayFailed')}</strong>
      <p>{extractPingErrorMessage(error, te)}</p>
      <p>{tSetup('automaticRetries', { count: 0 })}</p>
      {(details.requestURL || details.statusCode !== undefined || details.upstreamMessage) && (
        <details className={styles.relayFailureDetails}>
          <summary>{tSetup('attemptedRequests')}</summary>
          {details.requestURL && (
            <div className={styles.relayFailureAttempt}>
              <code>POST {details.requestURL}</code>
              <span>{details.statusCode ?? tSetup('networkStatus')}</span>
            </div>
          )}
          {details.upstreamMessage && (
            <div className={styles.relayFailureDiagnostic}>
              <strong>{tSetup('upstreamDiagnostic')}</strong>
              <pre>{details.upstreamMessage}</pre>
              <small>{tr('upstreamBodyRedacted')}</small>
            </div>
          )}
        </details>
      )}
      <div className={styles.relayFailureActions}>
        <Button tone="primary" size="sm" onClick={onRetry}>{tr('verifyAndSave')}</Button>
        {canSaveUnverified && (
          <Button tone="secondary" size="sm" onClick={onSaveUnverified}>{tr('saveUnverified')}</Button>
        )}
      </div>
    </section>
  );
}
