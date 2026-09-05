'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Cpu, Loader2, Radar, Save } from 'lucide-react';
import type { LocalEngineKind, Provider, RelayConnectionSecurityMode } from '@oriveo/shared';
import { formatApiKeyPreview, LOCAL_ENGINE_TEMPLATES, makeRelayRequested } from '@oriveo/shared';
import { Button } from '@oriveo/ui';
import { normalizeEndpointForSecurityMode } from '@oriveo/core/providers/relay-security-mode';
import { RelaySecurityModeControl } from '../../../../components/providers/RelaySecurityModeControl';
import { useAppStore, getVanillaStore } from '../../../../providers/StoreProvider';
import * as providerOps from '../../../../lib/core/provider-ops';
import {
  providerKeyValidatedProperties,
  ProviderSetupSurface,
  trackEvent,
} from '../../../../lib/core/telemetry';
import { createRelayManualModel } from '../../../../lib/core/provider-model-ops';
import { connectLocalEngineInBrowser, type LocalBrowserConnectionResult } from '../../../../lib/core/providers/local-browser-probe';
import { buildRelayCapabilityBitmap } from '../../../../lib/core/providers/relay-resolution';
import { createCanonicalUUID } from '../../../../lib/utils/id-utils';
import styles from './RelaySetup.module.css';
import type { CustomLLMConnectionCoordinator } from './custom-llm-connection-coordinator';

const engines: LocalEngineKind[] = ['ollama', 'llamacpp', 'lmstudio', 'vllm', 'openwebui'];

export function LocalComputeSetup({ connection }: {
  connection: CustomLLMConnectionCoordinator;
}) {
  const router = useRouter();
  const t = useTranslations('pages.relaySetup');
  const td = useTranslations('pages.relayDetail');
  const tp = useTranslations('pages.providerSetup');
  const [engine, setEngine] = useState<LocalEngineKind>('ollama');
  const [endpoint, setEndpoint] = useState('');
  const [modelHint, setModelHint] = useState('');
  const [apiKey, setApiKey] = useState('');
  // The security mode always starts fail-safe: even for a local HTTP template, downgrading requires
  // the user to confirm it in the security control. Inferring it from the scenario or the engine is not authorization.
  const [securityMode, setSecurityMode] = useState<Exclude<RelayConnectionSecurityMode, 'tofu_https'>>('remote_https');
  const endpointInputRef = useRef<HTMLInputElement>(null);
  const providers = useAppStore((state) => state.providers ?? []);
  /**
   * Submission analytics context. Local compute had no analytics at all before, so a user who could
   * not reach their own Ollama simply gave up and was invisible. Once stored it shares the `relay` kind with a custom relay, and setup_surface tells the two entry points apart.
   */
  const submitTelemetryRef = useRef({ attempts: 0, wasFirstProvider: providers.length === 0 });

  const trackKeyValidated = (input: {
    success: boolean;
    errorCode?: string | null;
    endpoint: string | null | undefined;
  }) => {
    trackEvent('provider_key_validated', providerKeyValidatedProperties({
      providerKind: 'relay',
      success: input.success,
      errorCode: input.errorCode,
      endpoint: input.endpoint,
      relayKind: 'openai_compatible',
      entryPoint: providers.length === 0 ? 'onboarding' : 'direct_link',
      isFirstProvider: submitTelemetryRef.current.wasFirstProvider,
      connectionAttempts: submitTelemetryRef.current.attempts,
      setupSurface: ProviderSetupSurface.localCompute,
    }));
  };
  const [endpointNormalizationVersion, setEndpointNormalizationVersion] = useState(0);
  const result = connection.result?.scenario === 'local'
    ? connection.result.value as LocalBrowserConnectionResult
    : null;
  const committedResult = connection.result?.scenario === 'local' ? connection.result : null;
  const connecting = connection.phase === 'detecting';
  const supported = useMemo(() => typeof window !== 'undefined' && window.isSecureContext && typeof fetch === 'function', []);

  useEffect(() => {
    if (endpointNormalizationVersion === 0) return;
    endpointInputRef.current?.focus();
    endpointInputRef.current?.select();
  }, [endpointNormalizationVersion]);

  const invalidateConnection = () => {
    connection.invalidate();
  };

  const selectEngine = (next: LocalEngineKind) => {
    invalidateConnection();
    setEngine(next);
    // Engine templates are suggestions only. Preserve what the user typed and revoke any weaker
    // transport authorization when the protocol profile changes.
    setSecurityMode('remote_https');
    if (next !== 'openwebui') setApiKey('');
  };

  const connect = async () => {
    submitTelemetryRef.current.attempts += 1;
    submitTelemetryRef.current.wasFirstProvider = providers.length === 0;
    const normalizedEndpoint = normalizeEndpointForSecurityMode(endpoint, securityMode);
    if (!normalizedEndpoint) {
      trackKeyValidated({ success: false, errorCode: 'invalid_endpoint', endpoint });
      return;
    }
    if (normalizedEndpoint !== endpoint.trim()) {
      setEndpoint(normalizedEndpoint);
      setEndpointNormalizationVersion((version) => version + 1);
    }
    const completed = await connection.run<LocalBrowserConnectionResult>('local', async (signal) => (
      connectLocalEngineInBrowser({
        engine,
        endpoint: normalizedEndpoint,
        securityMode,
        modelHint,
        apiKey,
        signal,
      })
    ), (next) => ({
      verification: next.generationVerified,
      catalog: next.modelIDs.length > 0,
      canCommit: next.generationVerified && Boolean(next.apiBaseURL),
    }), () => ({
      state: 'unreachable',
      failure: 'cors_blocked',
      endpoint: normalizedEndpoint,
      modelIDs: [],
      models: [],
      generationVerified: false,
    }));
    // Failing to connect is the most common outcome for local compute (port not open, CORS blocked, model not loaded) and was previously invisible.
    if (completed && !completed.value.generationVerified) {
      trackKeyValidated({
        success: false,
        errorCode: completed.value.failure ?? 'unknown',
        endpoint: normalizedEndpoint,
      });
    }
  };

  const saveDetectedLocal = async () => {
    if (!result?.generationVerified || !result.apiBaseURL || !committedResult || !connection.canCommit(committedResult)) return;
    const selectedModel = modelHint.trim() || result.modelIDs[0];
    const models = result.models.map((runtime) => ({
        ...createRelayManualModel(runtime.id, runtime.id === selectedModel),
        isDefault: runtime.id === selectedModel,
        localLoadState: runtime.localLoadState,
        executionLocality: runtime.executionLocality,
    }));
    const openWebUI = engine === 'openwebui';
    const requested = makeRelayRequested('openai_compatible');
    requested.authMode = openWebUI ? 'bearer' : 'none';
    requested.securityMode = securityMode;
    requested.transport = 'openai_chat_completions';
    requested.modelID = selectedModel;
    requested.resolvedAPIBaseURL = result.apiBaseURL;
    requested.engineProfile = engine;
    const provider: Provider = {
        id: createCanonicalUUID(),
        kind: 'relay',
        customName: `Local ${engineLabel(engine)}`,
        status: { kind: 'connected' },
        models,
        catalogModels: models,
        lastCheckedAt: new Date().toISOString(),
        apiKey: openWebUI ? apiKey.trim() : '',
        apiKeyPreview: openWebUI ? formatApiKeyPreview(apiKey.trim()) : '',
        baseURLText: result.endpoint,
        relayKind: 'openai_compatible',
        relayRequested: requested,
        relayResolvedBaseURLText: result.apiBaseURL,
        relayResolvedTransport: 'openai_chat_completions',
        relayResolvedAuthMode: openWebUI ? 'bearer' : 'none',
        relayCapabilityBitmap: buildRelayCapabilityBitmap('openai_chat_completions', {
          catalogEvidenceSucceeded: true,
        }),
        relayProbeVersion: 2,
        relayLastProbeAt: new Date().toISOString(),
    };
    const committed = await providerOps.addProvider(getVanillaStore(), provider, {
      shouldCommit: () => connection.canCommit(committedResult),
    });
    if (committed === false || !connection.canCommit(committedResult)) return;
    trackKeyValidated({ success: true, endpoint: result.apiBaseURL });
    router.push(`/providers/${provider.id}`);
  };

  return (
    <>
      {!supported ? <section className={styles.statusCard} data-state="error" role="status"><strong>{t('probeBlocked')}</strong><p>{t('networkFailure')}</p></section> : (
        <div className={styles.form}>
          <div className={styles.field}>
            <label htmlFor="local-engine">{t('engine')}</label>
            <div className={styles.selectShell}>
              <Cpu size={17} aria-hidden="true" />
              <select id="local-engine" className={styles.engineSelect} value={engine} onChange={(event) => selectEngine(event.target.value as LocalEngineKind)} disabled={connecting} aria-label={tp('localCompute')}>
                {engines.map((item) => <option key={item} value={item}>{engineLabel(item)}</option>)}
              </select>
            </div>
          </div>
          <div className={styles.field}><label htmlFor="local-endpoint">{t('requestURLLabel')}</label><input ref={endpointInputRef} id="local-endpoint" className={styles.input} value={endpoint} placeholder={LOCAL_ENGINE_TEMPLATES[engine].defaultEndpoint} onChange={(event) => { invalidateConnection(); setEndpoint(event.target.value); }} spellCheck={false} disabled={connecting} />{engine !== 'openwebui' ? <small>{t('localNoCredentials')}</small> : null}</div>
          <RelaySecurityModeControl
            value={securityMode}
            endpoint={endpoint}
            hasCredentialMaterial={apiKey.trim().length > 0}
            busy={connecting}
            onChange={({ mode, normalizedEndpoint }) => {
              setSecurityMode(mode);
              setEndpoint(normalizedEndpoint);
              if (mode !== 'remote_https') setApiKey('');
              setEndpointNormalizationVersion((version) => version + 1);
              invalidateConnection();
            }}
          />
          {engine === 'openwebui' ? <div className={styles.field}><label htmlFor="local-api-key">{t('apiKeyLabel')}</label><input id="local-api-key" className={styles.input} type="password" autoComplete="off" value={apiKey} placeholder={t('apiKeyPlaceholder')} onChange={(event) => { invalidateConnection(); setApiKey(event.target.value); }} disabled={connecting} /></div> : null}
          <div className={styles.field}><label htmlFor="local-model">{t('defaultModelLabel')}</label><input id="local-model" className={styles.input} value={modelHint} onChange={(event) => { invalidateConnection(); setModelHint(event.target.value); }} placeholder={t('defaultModelOptional')} spellCheck={false} disabled={connecting} /></div>
          {endpoint.trim() && !normalizeEndpointForSecurityMode(endpoint, securityMode) ? <section className={styles.statusCard} data-state="error" role="status"><strong>{t('relayDetectionFailed')}</strong><p>{t('invalidRequestURL')}</p></section> : null}
          {result ? <section className={styles.statusCard} data-state={result.generationVerified ? 'success' : 'error'} role="status"><strong>{result.generationVerified ? t('relayDetected') : t('relayDetectionFailed')}</strong><p>{result.generationVerified ? t('modelsFound', { count: result.modelIDs.length }) : result.failure === 'cleartext_credentials' ? td('cleartextCredentialsBlocked') : t(localFailureKey(result.failure))}</p></section> : null}
          <div className={styles.actionBar}>
            <Button className={styles.primaryAction} onClick={result?.generationVerified ? saveDetectedLocal : connect} disabled={connecting || !normalizeEndpointForSecurityMode(endpoint, securityMode) || (engine === 'openwebui' && !apiKey.trim())}>{connecting ? <Loader2 className={styles.spinner} size={18} /> : result?.generationVerified ? <Save size={18} /> : <Radar size={18} />}<span>{connecting ? t('testingRelay') : result?.generationVerified ? t('connectAndSave') : t('detectConnectionSettings')}</span></Button>
          </div>
        </div>
      )}
    </>
  );
}

function engineLabel(engine: LocalEngineKind): string {
  if (engine === 'llamacpp') return 'llama.cpp';
  if (engine === 'lmstudio') return 'LM Studio';
  if (engine === 'vllm') return 'vLLM';
  if (engine === 'openwebui') return 'Open WebUI';
  return 'Ollama';
}

function localFailureKey(failure: LocalBrowserConnectionResult['failure']): string {
  if (failure === 'permission_denied') return 'probeBlocked';
  if (failure === 'cors_blocked') return 'networkFailure';
  if (failure === 'unsafe_address' || failure === 'redirect_blocked') return 'invalidRequestURL';
  if (failure === 'credential_required') return 'apiKeyRequired';
  if (failure === 'authentication_rejected') return 'authenticationRejected';
  return 'invalidResponse';
}
