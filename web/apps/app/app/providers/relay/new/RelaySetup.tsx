'use client';

import { useCallback, useMemo, useRef, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type {
  Provider,
  RelayKind,
  RelayRequestedConfig,
} from '@oriveo/shared';
import {
  formatApiKeyPreview,
  makeRelayRequested,
} from '@oriveo/shared';
import { useAppStore, getVanillaStore } from '../../../../providers/StoreProvider';
import * as providerOps from '../../../../lib/core/provider-ops';
import {
  providerKeyValidatedProperties,
  ProviderSetupSurface,
  trackEvent,
} from '../../../../lib/core/telemetry';
import { createRelayManualModel } from '../../../../lib/core/provider-model-ops';
import { getProviderDefaultModelId } from '../../../../lib/core/metadata/metadata-client';
import {
  buildRelayCapabilityBitmap,
  inferRelayHeaderProfile,
  relayFamilyHintForTransport,
} from '../../../../lib/core/providers/relay-resolution';
import {
  hasRelayConnectedEvidence,
  probeRelayEndpoint,
  type RelayDiscoveryResult,
  type RelayProbeTransportKind,
} from '../../../../lib/core/providers/probe/probe-runner';
import {
  makeRelayDefaultProviderInstanceName,
  makeUniqueProviderInstanceName,
} from '../../../../lib/core/providers/provider-display';
import {
  displayableRelayFormIssues,
  relayFormNormalizedEndpoint,
  validateRelayForm,
  type RelayFormDraft,
  type RelayFormIssue,
} from '@oriveo/core/providers/relay-form-validation';
import {
  relayRequiresCredential,
  relaySensitiveCredentialValues,
} from '@oriveo/core/providers/relay-runtime-support';
import { extractErrorSnippet } from '@oriveo/core/util/error-snippet';
import { relayFormFieldMessage } from '../../../../lib/core/providers/relay-form-messages';
import { createCanonicalUUID } from '../../../../lib/utils/id-utils';
import { consumeRelayHandoff } from '../../new/relay-handoff';
import { RelaySimpleForm, type RelaySimpleFormValues } from './RelaySimpleForm';
import styles from './RelaySetup.module.css';
import {
  useCustomLLMConnectionCoordinator,
  type CustomLLMConnectionCoordinator,
  type CustomLLMConnectionResult,
  type CustomLLMScenario,
} from './custom-llm-connection-coordinator';
import { LocalComputeSetup } from './LocalComputeSetup';

const FALLBACK_MODEL_ID = 'gpt-5.6-sol';
const RELAY_SECURITY_MODE = 'remote_https' as const;

export function RelaySetup() {
  // Both entry points share the underlying connection coordinator, but the entry point has
  // already made the scenario choice, so the page does not ask the user to decide again.
  const searchParams = useSearchParams();
  const scenario: CustomLLMScenario = searchParams.get('mode') === 'local'
    ? 'local'
    : 'relay';
  const connection = useCustomLLMConnectionCoordinator();
  const tp = useTranslations('pages.providerSetup');
  const tc = useTranslations('common');
  const router = useRouter();
  return (
    <main className={styles.page}>
      <button className={styles.backButton} type="button" onClick={() => router.back()} aria-label={tc('back')}>
        <span aria-hidden="true">&#8592;</span>
      </button>
      <header className={styles.hero}>
        <h1>{scenario === 'local' ? tp('localCompute') : tp('customEndpoint')}</h1>
        <p>{scenario === 'local' ? tp('localComputeSubtitle') : tp('relaySubtitle')}</p>
      </header>
      {scenario === 'local'
        ? <LocalComputeSetup connection={connection} />
        : <RelayCloudSetup connection={connection} />}
    </main>
  );
}

function RelayCloudSetup({ connection }: { connection: CustomLLMConnectionCoordinator }) {
  const router = useRouter();
  const t = useTranslations('pages.relaySetup');
  /** Form issue message keys are full keys including the namespace (both flows share one mapping), so resolve them with the root translator. */
  const tRoot = useTranslations();
  const providers = useAppStore((state) => state.providers ?? []);
  const setHasCompletedOnboarding = useAppStore((state) => state.setHasCompletedOnboarding);
  const [handoff] = useState(() => consumeRelayHandoff());
  const entryPoint = handoff?.entryPoint ?? (providers.length === 0 ? 'onboarding' : 'direct_link');
  /**
   * Submission analytics context. The relay path used to emit no `provider_key_validated`
   * at all, so "entered a relay address, pressed the button, could not connect" - the number
   * one relay failure - did not exist in analytics.
   * `wasFirstProvider` is snapshotted the moment the button is pressed, since providers is
   * no longer empty once the save succeeds.
   */
  const submitTelemetryRef = useRef({ attempts: 0, wasFirstProvider: providers.length === 0 });

  const trackKeyValidated = useCallback((input: {
    success: boolean;
    errorCode?: string | null;
    endpoint: string | null | undefined;
    relayKind: RelayKind;
  }) => {
    trackEvent('provider_key_validated', providerKeyValidatedProperties({
      providerKind: 'relay',
      success: input.success,
      errorCode: input.errorCode,
      endpoint: input.endpoint,
      relayKind: input.relayKind,
      entryPoint,
      isFirstProvider: submitTelemetryRef.current.wasFirstProvider,
      connectionAttempts: submitTelemetryRef.current.attempts,
      setupSurface: ProviderSetupSurface.relaySetup,
    }));
  }, [entryPoint]);

  const [values, setValues] = useState<RelaySimpleFormValues>({
    name: '',
    endpoint: '',
    apiKey: '',
    defaultModel: '',
  });
  const [relayKind, setRelayKind] = useState<RelayKind>('openai_compatible');
  const [manualMode, setManualMode] = useState(false);
  const [customRequested, setCustomRequested] = useState<RelayRequestedConfig>(
    () => makeRelayRequested('custom'),
  );
  const [endpointNormalizationVersion, setEndpointNormalizationVersion] = useState(0);
  const [showKey, setShowKey] = useState(false);
  const result = connection.result?.scenario === 'relay'
    ? connection.result.value as RelayDiscoveryResult
    : null;

  const invalidateDiscovery = useCallback(() => {
    connection.invalidate();
  }, [connection]);

  const handleChange = useCallback((patch: Partial<RelaySimpleFormValues>) => {
    const onlyCatalogSelection = 'defaultModel' in patch
      && Object.keys(patch).length === 1
      && Boolean(result?.detection?.modelIDs.includes(patch.defaultModel ?? ''));
    setValues((previous) => ({ ...previous, ...patch }));
    if (!onlyCatalogSelection && ('endpoint' in patch || 'apiKey' in patch || 'defaultModel' in patch)) {
      invalidateDiscovery();
    }
  }, [invalidateDiscovery, result]);

  /** The protocol configuration currently in effect for the form. Manual mode uses the protocol the user picked, everything else the quick-mode default. */
  const formRequested = useMemo(() => {
    const requested = manualMode
      ? makeRelayRequested(relayKind, relayKind === 'custom' ? customRequested : undefined)
      : makeRelayRequested(relayKind);
    return {
      ...requested,
      securityMode: RELAY_SECURITY_MODE,
    };
  }, [customRequested, manualMode, relayKind]);

  /**
   * The add and edit pages share one form definition and one pure validation function. This
   * page no longer decides on its own whether an address is valid or a key is required -
   * that check may exist in exactly one place, or the same rule drifts separately in each flow.
   */
  const draft: RelayFormDraft = useMemo(() => ({
    endpoint: values.endpoint,
    apiKey: values.apiKey,
    authMode: formRequested.authMode,
    securityMode: RELAY_SECURITY_MODE,
    transport: formRequested.transport,
    modelID: values.defaultModel,
    headers: formRequested.headers ?? [],
    queryParams: formRequested.queryParams ?? [],
    // The add flow has no key store, only the key the user is typing right now.
    hasSavedCredential: false,
  }), [formRequested, values.apiKey, values.defaultModel, values.endpoint]);

  const issues: RelayFormIssue[] = useMemo(() => validateRelayForm(draft, 'create'), [draft]);

    // Required-field issues only keep the primary button disabled rather than flashing red text; everything else must produce a plain-language message.
  const errors = useMemo(() => ({
    endpoint: relayFormFieldMessage(displayableRelayFormIssues(issues), 'endpoint', tRoot),
    apiKey: relayFormFieldMessage(displayableRelayFormIssues(issues), 'api_key', tRoot),
  }), [issues, tRoot]);

  const validate = useCallback(() => issues.length === 0, [issues]);

  const runDetection = useCallback(async () => {
    if (!validate()) return;
    submitTelemetryRef.current.attempts += 1;
    submitTelemetryRef.current.wasFirstProvider = providers.length === 0;
    const normalizedEndpoint = relayFormNormalizedEndpoint(draft, 'create');
    if (!normalizedEndpoint) {
    // An invalid address is the number one relay failure and exactly the submission that analytics should capture.
      trackKeyValidated({
        success: false,
        errorCode: 'invalid_endpoint',
        endpoint: values.endpoint,
        relayKind,
      });
      return;
    }
    if (normalizedEndpoint !== values.endpoint.trim()) {
      setValues((previous) => ({ ...previous, endpoint: normalizedEndpoint }));
      setEndpointNormalizationVersion((version) => version + 1);
    }
    const completed = await connection.run('relay', async (signal) => (
      probeRelayEndpoint({
          endpoint: normalizedEndpoint,
          apiKey: values.apiKey.trim(),
          modelHint: values.defaultModel.trim() || undefined,
          forcedTransport: manualMode ? requestedTransportForKind(relayKind, customRequested) : undefined,
          securityMode: RELAY_SECURITY_MODE,
          authMode: formRequested.authMode === 'auto' ? undefined : formRequested.authMode,
          headers: formRequested.headers,
          queryParams: formRequested.queryParams,
          signal,
      })
    ), (next) => ({
      verification: Boolean(next.detection && hasRelayConnectedEvidence(next.detection)),
      catalog: Boolean(next.detection?.catalogEvidenceSucceeded),
      canCommit: next.state === 'verified' || next.state === 'needs_manual_model',
    }), (error) => ({
      state: 'failed',
      attempts: [],
      failure: 'network',
      diagnostic: relayFailureDiagnostic(error, values.apiKey, formRequested.headers, formRequested.queryParams),
      retriedRequestCount: 0,
    }));
    if (completed && !values.defaultModel.trim() && completed.value.detection?.modelIDs[0]) {
      setValues((previous) => ({ ...previous, defaultModel: completed.value.detection!.modelIDs[0] }));
    }
    // A failed probe means the user pressed the button and could not connect, which is worth more than the successful save.
    if (completed?.value.state === 'failed') {
      trackKeyValidated({
        success: false,
        errorCode: completed.value.failure ?? 'unknown',
        endpoint: normalizedEndpoint,
        relayKind,
      });
    }
  }, [connection, customRequested, draft, formRequested, manualMode, providers, relayKind, trackKeyValidated, validate, values]);

  const saveDetectedRelay = useCallback(async () => {
    const committedResult = connection.result?.scenario === 'relay'
      ? connection.result as CustomLLMConnectionResult<RelayDiscoveryResult>
      : null;
    const relayResult = committedResult?.value;
    const detection = relayResult?.detection;
    if (!detection || (relayResult.state !== 'verified' && relayResult.state !== 'needs_manual_model')) return;
    if (!connection.canCommit(committedResult)) return;
    // Reuse the same classification as form validation: the address written to storage cannot differ from the one just validated.
    const endpoint = relayFormNormalizedEndpoint(draft, 'create') ?? '';
    const apiKey = values.apiKey.trim();
    const modelID = values.defaultModel.trim();
    const catalogModels = detection.catalogModels.map((model) => ({
      ...model,
      capabilities: [...model.capabilities],
      isDefault: model.id === modelID,
    }));
    const selectedCatalogModel = catalogModels.find((model) => model.id === modelID);
    const enabledModels = modelID
      ? [{ ...(selectedCatalogModel ?? createRelayManualModel(modelID, true)), isDefault: true }]
      : [];
    const persistedCatalog = selectedCatalogModel || !modelID
      ? catalogModels
      : [...catalogModels, enabledModels[0]];
    const now = new Date().toISOString();
    const detectedKind = manualMode ? relayKind : relayKindForTransport(detection.transport);
    const requested = {
      ...makeRelayRequested(detectedKind, manualMode ? customRequested : undefined),
      ...formRequested,
    };
    requested.transport = detection.transport;
    requested.authMode = formRequested.authMode === 'auto' ? detection.authMode : formRequested.authMode;
    requested.securityMode = RELAY_SECURITY_MODE;
    requested.modelID = modelID || undefined;
    requested.resolvedAPIBaseURL = detection.apiBaseURL;
    const name = values.name.trim()
      ? makeUniqueProviderInstanceName(values.name, 'relay', providers)
      : makeRelayDefaultProviderInstanceName(endpoint, providers);
    const unverifiedMessage = t('connectionUnverified');
    const hasConnectedEvidence = hasRelayConnectedEvidence(detection);

    const provider: Provider = {
      id: createCanonicalUUID(),
      kind: 'relay',
      customName: name,
      status: hasConnectedEvidence
        ? { kind: 'connected' }
        : { kind: 'issue', message: unverifiedMessage },
      models: enabledModels,
      catalogModels: persistedCatalog,
      lastCheckedAt: now,
      lastError: hasConnectedEvidence ? undefined : unverifiedMessage,
      apiKey,
      apiKeyPreview: formatApiKeyPreview(apiKey),
      baseURLText: endpoint,
      relayKind: detectedKind,
      relayRequested: requested,
      relayResolvedBaseURLText: detection.apiBaseURL,
      relayResolvedTransport: detection.transport,
      relayResolvedAuthMode: detection.authMode,
      relayResolvedHeaderProfile: inferRelayHeaderProfile(detection.transport, detection.authMode),
      relayResolvedFamilyHint: relayFamilyHintForTransport(detection.transport),
      relayCapabilityBitmap: buildRelayCapabilityBitmap(detection.transport, {
        catalogEvidenceSucceeded: detection.catalogEvidenceSucceeded,
      }),
      relayProbeVersion: 2,
      relayLastProbeAt: now,
    };

    const committed = await providerOps.addProvider(getVanillaStore(), provider, {
      shouldCommit: () => connection.canCommit(committedResult),
    });
    // The older providerOps implementation returned void; only false is an explicit refusal to persist, so a compatibility return value must not be read as failure.
    if (committed === false || !connection.canCommit(committedResult)) return;
    // Unvalidated connections are still persisted (an escape hatch), but analytics must tell apart the runs that really connected.
    trackKeyValidated({
      success: hasConnectedEvidence,
      errorCode: hasConnectedEvidence ? null : 'unverified_connection',
      endpoint,
      relayKind: detectedKind,
    });
    if (hasConnectedEvidence) {
      setHasCompletedOnboarding(true);
      router.push(`/providers/${provider.id}`);
      return;
    }
    const context = entryPoint === 'onboarding' ? 'onboarding' : 'providers';
    router.push(`/providers/${provider.id}/manual-model?context=${context}`);
  }, [connection, draft, entryPoint, customRequested, formRequested, manualMode, providers, relayKind, result, router, setHasCompletedOnboarding, t, trackKeyValidated, values]);

  const handlePrimaryAction = result?.state === 'verified' || result?.state === 'needs_manual_model'
    ? saveDetectedRelay
    : runDetection;
  const defaultModelPlaceholder = getProviderDefaultModelId('openAI') ?? FALLBACK_MODEL_ID;
  return (
      <RelaySimpleForm
        values={values}
        onChange={handleChange}
        errors={errors}
        requiresCredential={relayRequiresCredential(formRequested.authMode)}
        endpointNormalizationVersion={endpointNormalizationVersion}
        showKey={showKey}
        onToggleKey={() => setShowKey((visible) => !visible)}
        canSubmit={issues.length === 0}
        defaultModelPlaceholder={defaultModelPlaceholder}
        manualMode={manualMode}
        onToggleManual={() => {
          invalidateDiscovery();
          setManualMode((enabled) => !enabled);
        }}
        relayKind={relayKind}
        onRelayKindChange={(kind) => {
          invalidateDiscovery();
          setRelayKind(kind);
        }}
        customRequested={customRequested}
        onCustomRequestedChange={(patch) => {
          invalidateDiscovery();
          setCustomRequested((previous) => ({ ...previous, ...patch }));
        }}
        result={result}
        isDetecting={connection.phase === 'detecting'}
        onPrimaryAction={handlePrimaryAction}
      />
  );
}

/** Uses the same errorSnippet plus relay credential list as the upstream diagnostics in probe-runner; never surfaces Error.message directly. */
export function relayFailureDiagnostic(
  error: unknown,
  apiKey: string,
  headers: RelayRequestedConfig['headers'],
  queryParams: RelayRequestedConfig['queryParams'],
): string | undefined {
  const message = error instanceof Error ? error.message : String(error);
  return extractErrorSnippet(JSON.stringify({ error: message }), 1_000, relaySensitiveCredentialValues({
    apiKey,
    headers,
    queryParams,
  }));
}

function requestedTransportForKind(
  relayKind: RelayKind,
  customRequested: RelayRequestedConfig,
): RelayProbeTransportKind {
  const requested = relayKind === 'custom' ? customRequested : makeRelayRequested(relayKind);
  // Native /completion has no generic probe shape; connection discovery still uses the
  // OpenAI catalog / chat probe, and the llama.cpp native runtime transport the user picked
  // is kept once it succeeds.
  return requested.transport === 'auto' || requested.transport === 'llamacpp_native'
    ? 'openai_chat_completions'
    : requested.transport;
}

function relayKindForTransport(transport: RelayProbeTransportKind): RelayKind {
  if (transport === 'openai_responses') return 'codex_style';
  if (transport === 'anthropic_messages') return 'anthropic_compatible';
  if (transport === 'gemini_generate_content') return 'gemini_compatible';
  return 'openai_compatible';
}
