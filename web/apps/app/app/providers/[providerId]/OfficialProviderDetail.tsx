'use client';

import { useState, useMemo, useEffect, useCallback, useSyncExternalStore } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { ListChecks, ListX, MessageCircle, SlidersHorizontal } from 'lucide-react';
import type { AIModel, Provider } from '@oriveo/shared';
import { Button, BackArrowIcon } from '@oriveo/ui';
import { getProviderDisplayName } from '@oriveo/config';
import { useProviderActions } from '../../../lib/hooks/useProviderActions';
import { useAppStore, getVanillaStore } from '../../../providers/StoreProvider';
import { showToast } from '../../../components/Toast';
import { selectResolvedCatalog } from '../../../lib/core/store/selectors';
import { getEffectiveStatusKind, isEffectiveWarning } from '../../../lib/core/providers/provider-status';
import { PROVIDER_VALIDATION_MESSAGES } from '../../../lib/core/providers/validation-messages';
import { ModelCommercialMetaInline, ModelMetaInline } from '../../../components/chat/ModelMetaInline';
import { ModelBrowser } from './ModelBrowser';
import { sortEnabledModels } from './model-browser-groups';
import { ConfirmDeleteDialog } from './components/ConfirmDeleteDialog';
import { EditApiKeyDialog } from './components/EditApiKeyDialog';
import { ProviderBalanceCard } from './ProviderBalanceCard';
import { isBalanceCapable } from '../../../lib/core/providers/balance';
import { ProviderDetailBrandHero } from './components/ProviderDetailBrandHero';
import { ProviderConnectionRecoveryCard } from './components/ProviderConnectionRecoveryCard';
import { ProviderSettingsPanel, type ProviderSettingsExpandedRow } from './components/ProviderSettingsPanel';
import { GenerationParameterPanel } from '../../../components/generation/GenerationParameterPanel';
import { RenameProviderDialog } from './components/RenameProviderDialog';
import { getProviderInstanceDisplayName } from '../../../lib/core/providers/provider-display';
import { useProviderChatLauncher } from './useProviderChatLauncher';
import {
  getCachedMetadataVersion,
  getGrokSubscriptionAvailability,
  getOpenAISubscriptionAvailability,
  getPublicProviderConfig,
  initMetadata,
  onVersionChange,
} from '../../../lib/core/metadata/metadata-client';
import * as providerOps from '../../../lib/core/provider-ops';
import { ProviderSubscriptionCard } from './components/ProviderSubscriptionCard';
import { GrokSubscriptionAuthorizationDialog } from '../../../components/providers/GrokSubscriptionAuthorizationDialog';
import { OpenAISubscriptionAuthorizationDialog } from '../../../components/providers/OpenAISubscriptionAuthorizationDialog';
import {
  getOfficialEndpointDescriptionTranslationKey,
  getOfficialEndpointOptionTranslationKey,
  isOfficialEndpointProvider,
  resolveOfficialEndpointOptions,
} from '../../../components/providers/official-endpoint-utils';
import styles from './ProviderDetail.module.css';

interface OfficialProviderDetailProps {
  provider: Provider;
}

export function OfficialProviderDetail({ provider }: OfficialProviderDetailProps) {
  const router = useRouter();
  const t = useTranslations('pages.providerDetail');
  const tSetup = useTranslations('pages.providerSetup');
  const tc = useTranslations('common');
  const te = useTranslations('errors');
  const tr = useTranslations('pages.relayDetail');

  const {
    isSyncing,
    saveKey, saveBaseURL, saveName, resync,
    toggleModel, enableAllModels, disableAllModels, deleteProvider,
  } = useProviderActions(provider);

  const [showConfirmDelete, setShowConfirmDelete] = useState(false);
  const [showRenameDialog, setShowRenameDialog] = useState(false);
  const [showEditApiKeyDialog, setShowEditApiKeyDialog] = useState(false);
  const [showGrokReauthorizeDialog, setShowGrokReauthorizeDialog] = useState(false);
  const [showOpenAIReauthorizeDialog, setShowOpenAIReauthorizeDialog] = useState(false);
  const [dismissedRecoveryCard, setDismissedRecoveryCard] = useState(false);
  // metadata does not live in React state, so useSyncExternalStore subscribes to its
  // version number and gives useMemo a real dependency. The server snapshot returns 0 during SSR.
  const metadataVersion = useSyncExternalStore(
    onVersionChange,
    getCachedMetadataVersion,
    () => 0,
  );
  const [settingsExpandedRow, setSettingsExpandedRow] = useState<ProviderSettingsExpandedRow>(null);
  const [expandedGenerationModelId, setExpandedGenerationModelId] = useState<string | null>(null);
  const providerKindName = getProviderDisplayName(provider.kind);
  const providerDisplayName = getProviderInstanceDisplayName(provider);

  const {
    startChatWithModel: handleChatWithModel,
    startChatWithDefaultModel: handleStartChat,
  } = useProviderChatLauncher(provider);

  const expandSettingsRow = useCallback((row: ProviderSettingsExpandedRow) => {
    setSettingsExpandedRow(row);
    // Scroll to SettingsPanel once it expands, so the inline editor is visible right away.
    requestAnimationFrame(() => {
      document.getElementById('provider-settings-panel')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });
  }, []);

  // **Dispatch on kind**: `authMode` says only that a connection uses a subscription, not
  // which path it uses. Going by authMode alone would pop the Grok authorization sheet for
  // a Codex instance and try to exchange ChatGPT credentials against the x.ai endpoint.
  const isGrokSubscription = provider.authMode === 'subscription' && provider.kind === 'grok';
  const isOpenAISubscription = provider.authMode === 'subscription' && provider.kind === 'openAI';
  const isSubscription = isGrokSubscription || isOpenAISubscription;
  const grokSubscription = useMemo(
    () => getGrokSubscriptionAvailability(),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [metadataVersion],
  );
  const openAISubscription = useMemo(
    () => getOpenAISubscriptionAvailability(),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [metadataVersion],
  );
  // A subscription instance has no key to edit, so the same entry point (Hero, or "update key" on the recovery card) re-authorizes instead.
  const handleEditApiKey = useCallback(() => {
    if (isGrokSubscription) {
      setShowGrokReauthorizeDialog(true);
      return;
    }
    if (isOpenAISubscription) {
      setShowOpenAIReauthorizeDialog(true);
      return;
    }
    setShowEditApiKeyDialog(true);
  }, [isGrokSubscription, isOpenAISubscription]);
  const handleSwitchToApiKey = useCallback(async () => {
    await providerOps.switchProviderToApiKeyMode(getVanillaStore(), provider.id);
    setShowEditApiKeyDialog(true);
  }, [provider.id]);
  const handleEditEndpoint = useCallback(() => expandSettingsRow('endpoint'), [expandSettingsRow]);

  // Use the resolved catalog, with metadata as the authoritative source.
  const resolvedCatalog = useMemo(
    () => selectResolvedCatalog(provider),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [provider, metadataVersion],
  );
  const catalogModels = useMemo(
    () => resolvedCatalog.catalog.filter((m) => !m.isEnabled),
    [resolvedCatalog],
  );
  const addedModelCount = resolvedCatalog.enabledModels.length;
  const sortedEnabledModels = useMemo(
    () => sortEnabledModels(resolvedCatalog.enabledModels, provider),
    [resolvedCatalog.enabledModels, provider],
  );

  const effectiveStatusKind = getEffectiveStatusKind(provider);
  const localizedLastError = useMemo(
    () => localizeProviderLastError(provider.lastError, te),
    [provider.lastError, te],
  );

  // Verify the connection: after resync completes, read the final status and lastError from
  // the store and show a semantic toast at the top for each of the three outcomes.
  // The loading flag (isSyncing) is already maintained by useProviderActions; this only adds the result feedback.
  const handleVerifyConnection = useCallback(async () => {
    await resync();
    const finalProvider = getVanillaStore().getState().providers.find((p) => p.id === provider.id);
    if (!finalProvider) return;
    if (finalProvider.status.kind === 'issue') {
      const detail = localizeProviderLastError(finalProvider.lastError, te) ?? finalProvider.lastError ?? '';
      showToast(t('toast.connectionCheckFailed', { error: detail }), 3000, undefined, 'error');
    } else if (finalProvider.lastError) {
      // unverified or a soft failure: still usable, so show it as a warning with lastError carrying the reason.
      const soft = localizeProviderLastError(finalProvider.lastError, te) ?? finalProvider.lastError;
      showToast(soft, 3000, undefined, 'warning');
    } else {
      showToast(t('toast.connectionVerified'), 3000, undefined, 'success');
    }
  }, [resync, provider.id, t, te]);
  const providerConfig = useMemo(
    () => getPublicProviderConfig(provider.kind),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [metadataVersion, provider.kind],
  );
  const officialEndpointOptions = useMemo(() => {
    const options = resolveOfficialEndpointOptions(provider.kind, providerConfig);
    if (options.length === 0) {
      return [];
    }

    return options.map((option) => {
      if (!isOfficialEndpointProvider(provider.kind)) {
        return option;
      }

      const translationKey = getOfficialEndpointOptionTranslationKey(provider.kind, option.id);
      return {
        ...option,
        label: translationKey ? tSetup(translationKey) : option.label,
      };
    });
  }, [provider.kind, providerConfig, tSetup]);
  const officialEndpointDescription = useMemo(() => {
    if (
      !isOfficialEndpointProvider(provider.kind)
      || officialEndpointOptions.length === 0
    ) {
      return null;
    }

    return tSetup(getOfficialEndpointDescriptionTranslationKey(provider.kind));
  }, [officialEndpointOptions.length, provider.kind, tSetup]);
  const endpointSectionLabel = officialEndpointOptions.length > 0
    ? tSetup('officialEndpoint')
    : t('baseURL');

  // Show the recovery card when the key is missing or there is a real error, and the user has not dismissed it.
  const showsRecoveryCard = !dismissedRecoveryCard && isEffectiveWarning(effectiveStatusKind);

  useEffect(() => {
    initMetadata().catch(() => {});
  }, []);

  // Reset the dismissed state when the provider changes, so the new provider's health is evaluated afresh.
  useEffect(() => {
    setDismissedRecoveryCard(false);
  }, [provider.id]);

  return (
    <div className={styles.page}>
      {/* Top bar —   back Hero   name  title   iOS   */}
      <div className={styles.topBar}>
        <button
          className={styles.backBtn}
          onClick={() => router.push('/providers')}
          aria-label={tc('back')}
        >
          <BackArrowIcon />
        </button>
      </div>

      {/* Recovery Card —   key /   HealthBanner  */}
      {showsRecoveryCard && (
        <ProviderConnectionRecoveryCard
          provider={provider}
          onEditApiKey={handleEditApiKey}
          onRetryConnection={handleVerifyConnection}
          onCheckEndpoint={officialEndpointOptions.length > 0 ? handleEditEndpoint : undefined}
          checkEndpointLabel={endpointSectionLabel}
          onDismiss={() => setDismissedRecoveryCard(true)}
          localizedLastError={localizedLastError}
        />
      )}

      {/* Brand Hero — subduedBrand   +   +   API Key +   CTA */}
      <ProviderDetailBrandHero
        provider={provider}
        onStartChat={handleStartChat}
        onVerifyConnection={handleVerifyConnection}
        onEditApiKey={handleEditApiKey}
        onEditName={() => setShowRenameDialog(true)}
        isSyncing={isSyncing}
      />

      {/*   —   4   fetchBalance API   §3  */}
      {isBalanceCapable(provider.kind) && provider.apiKey && (
        <ProviderBalanceCard provider={provider} />
      )}

      {isSubscription && (
        <ProviderSubscriptionCard
          availability={isOpenAISubscription ? openAISubscription : grokSubscription}
          onReauthorize={() =>
            isOpenAISubscription
              ? setShowOpenAIReauthorizeDialog(true)
              : setShowGrokReauthorizeDialog(true)
          }
          onSwitchToApiKey={() => { void handleSwitchToApiKey(); }}
          namespace={
            isOpenAISubscription
              ? 'pages.providerDetail.openaiSubscription'
              : 'pages.providerDetail.grokSubscription'
          }
          testIdPrefix={isOpenAISubscription ? 'openai' : 'grok'}
        />
      )}

      {/* Enabled models */}
      <div className={styles.section}>
        <div className={styles.sectionHeader}>
          <div className={styles.sectionHeaderLeft}>
            <div className={styles.sectionLabel}>{t('addedModels')}</div>
            <div className={styles.sectionHint}>
              {t('addedModelsHint', { count: addedModelCount })}
            </div>
          </div>
          <div className={styles.batchActions}>
            <Button tone="secondary" size="sm" onClick={enableAllModels}>
              <span className={styles.btnWithIcon}>
                <ListChecks className={styles.btnIcon} size={14} strokeWidth={2.2} aria-hidden="true" />
                {t('addAll')}
              </span>
            </Button>
            <Button tone="secondary" size="sm" onClick={disableAllModels}>
              <span className={styles.btnWithIcon}>
                <ListX className={styles.btnIcon} size={14} strokeWidth={2.2} aria-hidden="true" />
                {t('removeAll')}
              </span>
            </Button>
          </div>
        </div>
        {sortedEnabledModels.length === 0 ? (
          <div className={styles.emptyModels}>{t('noAddedModels')}</div>
        ) : (
          <div className={styles.modelList}>
            {sortedEnabledModels.map((model) => (
              <div key={model.id} className={styles.modelItem}>
                <div className={styles.modelPrimary}>
                  <span className={styles.modelName}>{model.name}</span>
                  <ModelMetaInline
                    model={model}
                    provider={provider}
                    containerClassName={styles.modelMeta}
                    priceClassName={styles.modelPrice}
                  />
                  <ModelCommercialMetaInline
                    model={model}
                    containerClassName={styles.modelSpecs}
                    itemClassName={styles.modelSpec}
                  />
                </div>
                <div className={styles.modelActions}>
                  {/*   IA CR-09 / D20  provider   LLM
                       / / ** ** D1   14  
                      generation profile  */}
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
                    className={styles.toggle}
                    type="button"
                    role="switch"
                    aria-checked="true"
                    aria-label={t('disableModelA11y', { model: model.name })}
                    data-on
                    onClick={() => toggleModel(model)}
                  >
                    <span className={styles.toggleThumb} />
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

      {/* Model browser */}
      {catalogModels.length > 0 && (
        <div className={styles.section}>
          <div className={styles.sectionLabel}>{t('modelCatalog')}</div>
          <ModelBrowser
            catalogModels={catalogModels}
            popularitySourceModels={resolvedCatalog.catalog}
            providerKind={provider.kind}
            providerLabel={providerKindName}
            provider={provider}
            onToggleModel={(model) => {
              // Success toast at the top, giving clear feedback when a model is added from the library; gated on wasEnabled so removing one does not trigger it.
              const wasEnabled = provider.models.some((m) => m.id === model.id);
              toggleModel(model);
              if (!wasEnabled) {
                showToast(t('toast.modelAdded', { model: model.name }), 3000, undefined, 'success');
              }
            }}
          />
        </div>
      )}

      {/* Settings —   panel 4  Edit API Key / Endpoint / Advanced / Delete  */}
      <div id="provider-settings-panel">
        <div className={styles.sectionLabel} style={{ marginBottom: 12 }}>
          {t('settings.title')}
        </div>
        <ProviderSettingsPanel
          provider={provider}
          onSaveBaseURL={saveBaseURL}
          endpointSectionLabel={endpointSectionLabel}
          endpointOptions={officialEndpointOptions}
          endpointDescription={officialEndpointDescription}
          endpointDisplayFallback={t('defaultURL')}
          onDelete={() => setShowConfirmDelete(true)}
          expandedRow={settingsExpandedRow}
          onExpandedRowChange={setSettingsExpandedRow}
        />
      </div>

      {/* Confirm delete */}
      {showConfirmDelete && (
        <ConfirmDeleteDialog
          title={t('confirmDeleteTitle')}
          description={t('confirmDeleteDesc')}
          onConfirm={deleteProvider}
          onCancel={() => setShowConfirmDelete(false)}
        />
      )}

      {/* Rename dialog */}
      {showRenameDialog && (
        <RenameProviderDialog
          currentName={providerDisplayName}
          onSave={(newName) => {
            saveName(newName);
            setShowRenameDialog(false);
          }}
          onCancel={() => setShowRenameDialog(false)}
        />
      )}

      {/* Re-authorizing swaps the credential without rebuilding the provider; a rebuild would lose
          the model enablement state and the custom name the user built up on this instance. */}
      {showGrokReauthorizeDialog && grokSubscription.state === 'available' && (
        <GrokSubscriptionAuthorizationDialog
          config={grokSubscription.config}
          onAuthorized={(credential) => {
            setShowGrokReauthorizeDialog(false);
            void providerOps
              .persistGrokSubscriptionCredential(getVanillaStore(), provider.id, credential)
              .then(() => resync());
          }}
          onCancel={() => setShowGrokReauthorizeDialog(false)}
        />
      )}

      {showOpenAIReauthorizeDialog && openAISubscription.state === 'available' && (
        <OpenAISubscriptionAuthorizationDialog
          config={openAISubscription.config}
          onAuthorized={(credential) => {
            setShowOpenAIReauthorizeDialog(false);
            void providerOps
              .persistOpenAISubscriptionCredential(getVanillaStore(), provider.id, credential)
              .then(() => resync());
          }}
          onCancel={() => setShowOpenAIReauthorizeDialog(false)}
        />
      )}

      {/* Edit API Key dialog: shared entry point for the hero at the top and the recovery card. */}
      {showEditApiKeyDialog && (
        <EditApiKeyDialog
          currentKeyPreview={provider.apiKeyPreview}
          onSave={async (newKey) => {
            await saveKey(newKey);
            setShowEditApiKeyDialog(false);
          }}
          onCancel={() => setShowEditApiKeyDialog(false)}
        />
      )}
    </div>
  );
}

function localizeProviderLastError(
  lastError: string | undefined,
  t: (key: string) => string,
): string | undefined {
  if (!lastError) {
    return undefined;
  }

  if (lastError === 'The API key you entered is invalid or has been revoked. Please check your key and try again.') {
    return t('invalidKey.message');
  }

  if (lastError === 'You have exceeded the rate limit. Please wait a moment and try again.') {
    return t('rateLimited.message');
  }

  if (lastError === 'Unable to connect. Please check your internet connection and try again.') {
    return t('network.message');
  }

  if (lastError === 'The AI provider is experiencing issues. Please try again later.') {
    return t('upstream.message');
  }

  if (lastError === 'The model catalog response was invalid. Please try again.') {
    return t('emptyResponse.message');
  }

  if (lastError === 'The model catalog is empty. Please try again later or enter a model ID manually.') {
    return t('emptyModelCatalog.message');
  }

  // BYOK key validation: invalid shows a red banner, unverified a muted soft hint.
  if (lastError === PROVIDER_VALIDATION_MESSAGES.invalidKey) {
    return t('validation.invalidKey');
  }

  if (lastError === PROVIDER_VALIDATION_MESSAGES.unverified) {
    return t('validation.unverified');
  }

  if (
    lastError === 'The request was malformed. Please check your input and try again.'
    || /^Request failed with status \d+\. Please try again\.$/.test(lastError)
  ) {
    return t('requestFailed.message');
  }

  return lastError;
}
