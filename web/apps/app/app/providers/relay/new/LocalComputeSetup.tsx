'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import {
  CaretRight,
  Check,
  CheckCircle,
  CircleNotch,
  Link,
  Scan,
  SlidersHorizontal,
  WarningCircle,
} from '@phosphor-icons/react';
import type { LocalEngineKind, Provider } from '@oriveo/shared';
import { formatApiKeyPreview, LOCAL_ENGINE_TEMPLATES, makeRelayRequested } from '@oriveo/shared';
import { Button } from '@oriveo/ui';
import { useAppStore, getVanillaStore } from '../../../../providers/StoreProvider';
import * as providerOps from '../../../../lib/core/provider-ops';
import {
  providerKeyValidatedProperties,
  ProviderSetupSurface,
  trackEvent,
} from '../../../../lib/core/telemetry';
import { createRelayManualModel } from '../../../../lib/core/provider-model-ops';
import {
  connectLocalEngineInBrowser,
  fingerprintLocalEngineInBrowser,
  localBrowserEndpointAccess,
  type LocalBrowserConnectionResult,
} from '../../../../lib/core/providers/local-browser-probe';
import { buildRelayCapabilityBitmap } from '../../../../lib/core/providers/relay-resolution';
import { createCanonicalUUID } from '../../../../lib/utils/id-utils';
import styles from './RelaySetup.module.css';
import type { CustomLLMConnectionCoordinator } from './custom-llm-connection-coordinator';
import {
  LOCAL_SETUP_ENGINES,
  LOCAL_SETUP_SECONDARY_KEY,
  localChannelDisplayName,
  localChannelTransport,
  localEngineDisplayName,
  localSetupBoard,
  type LocalChannel,
  type LocalSetupBoard,
  type LocalSetupConnectionValue,
} from './setup-board';
import { endpointFromSlotInput, endpointSchemeChip, endpointSlotText } from './setup-board-parts';

const LOCAL_CHANNELS: readonly LocalChannel[] = ['chat', 'native'];

export function LocalComputeSetup({ connection }: {
  connection: CustomLLMConnectionCoordinator;
}) {
  const router = useRouter();
  const t = useTranslations('pages.relaySetup');
  // The address field title is the same string as the local row on the edit-connection page.
  const td = useTranslations('pages.relayDetail');
  const [endpoint, setEndpoint] = useState('');
  const [apiKey, setApiKey] = useState('');
  // Manually picked engine / channel: expanding it skips fingerprinting and connects with the chosen engine and channel.
  const [manualExpanded, setManualExpanded] = useState(false);
  const [manualEngine, setManualEngine] = useState<LocalEngineKind>('ollama');
  const [manualChannel, setManualChannel] = useState<LocalChannel>('chat');
  const endpointInputRef = useRef<HTMLInputElement>(null);
  const providers = useAppStore((state) => state.providers ?? []);
  const setLastUsedModelRef = useAppStore((state) => state.setLastUsedModelRef);
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
    ? connection.result.value as LocalSetupConnectionValue
    : null;
  const committedResult = connection.result?.scenario === 'local' ? connection.result : null;
  const connecting = connection.phase === 'detecting';
  const supported = useMemo(() => typeof window !== 'undefined' && window.isSecureContext && typeof fetch === 'function', []);
  // The browser can only reach loopback http and any https, so the address itself decides the security mode; there is no cleartext confirmation switch.
  const endpointAccess = localBrowserEndpointAccess(endpoint);
  const board = localSetupBoard({
    result,
    isDetecting: connecting,
    endpointAccess: endpointAccess.kind,
    manualExpanded,
    manualEngine,
    hasApiKey: apiKey.trim().length > 0,
  });

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
    setManualEngine(next);
    if (next !== 'llamacpp') setManualChannel('chat');
    if (next !== 'openwebui') setApiKey('');
  };

  const connect = async () => {
    submitTelemetryRef.current.attempts += 1;
    submitTelemetryRef.current.wasFirstProvider = providers.length === 0;
    if (endpointAccess.kind !== 'allowed') {
      trackKeyValidated({ success: false, errorCode: 'invalid_endpoint', endpoint });
      return;
    }
    const { normalized: normalizedEndpoint, securityMode } = endpointAccess;
    if (normalizedEndpoint !== endpoint.trim()) {
      setEndpoint(normalizedEndpoint);
      setEndpointNormalizationVersion((version) => version + 1);
    }
    const skipFingerprint = board.showsManualPicker;
    const completed = await connection.run<LocalSetupConnectionValue>('local', async (signal) => {
      let engine: LocalEngineKind;
      let channel: LocalChannel = 'chat';
      if (skipFingerprint) {
        engine = manualEngine;
        channel = manualEngine === 'llamacpp' ? manualChannel : 'chat';
      } else {
        // Fingerprint first, then connect by the result: the engine is fixed only when exactly one matches; generic / manual go to the manual picker.
        const fingerprint = await fingerprintLocalEngineInBrowser({ endpoint: normalizedEndpoint, securityMode, signal });
        if (fingerprint.outcome !== 'engine') {
          return {
            state: 'unreachable',
            endpoint: normalizedEndpoint,
            modelIDs: [],
            models: [],
            generationVerified: false,
            unrecognized: true,
          };
        }
        engine = fingerprint.engineProfile;
      }
      const connected = await connectLocalEngineInBrowser({
        engine,
        endpoint: normalizedEndpoint,
        securityMode,
        apiKey: engine === 'openwebui' ? apiKey : '',
        signal,
      });
      return { ...connected, engine, channel };
    }, (next) => ({
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
    if (completed?.value.unrecognized) setManualExpanded(true);
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
    if (!result?.generationVerified || !result.apiBaseURL || !result.engine || !committedResult || !connection.canCommit(committedResult)) return;
    if (endpointAccess.kind !== 'allowed') return;
    const engine = result.engine;
    const securityMode = endpointAccess.securityMode;
    // The native channel has no generic probe shape, so verification still goes through chat; the stored provider keeps the native channel the user picked, rooted at the engine address itself (no /v1).
    const transport = localChannelTransport(result.channel ?? 'chat');
    const apiBaseURL = transport === 'llamacpp_native' ? result.endpoint : result.apiBaseURL;
    // There is no default model slot: the verification sample is the first catalog entry, selected once setup completes.
    const selectedModel = result.modelIDs[0];
    // Local connections have no default model either: none is marked default, and the model just verified is pointed to by last-used instead.
    const models = result.models.map((runtime) => ({
        ...createRelayManualModel(runtime.id),
        localLoadState: runtime.localLoadState,
        executionLocality: runtime.executionLocality,
        ...(runtime.engineDeclaration ? { engineDeclaration: runtime.engineDeclaration } : {}),
    }));
    const openWebUI = engine === 'openwebui';
    const requested = makeRelayRequested('openai_compatible');
    requested.authMode = openWebUI ? 'bearer' : 'none';
    requested.securityMode = securityMode;
    requested.transport = transport;
    requested.resolvedAPIBaseURL = apiBaseURL;
    requested.engineProfile = engine;
    const provider: Provider = {
        id: createCanonicalUUID(),
        kind: 'relay',
        customName: `Local ${localEngineDisplayName(engine)}`,
        status: { kind: 'connected' },
        models,
        catalogModels: models,
        lastCheckedAt: new Date().toISOString(),
        apiKey: openWebUI ? apiKey.trim() : '',
        apiKeyPreview: openWebUI ? formatApiKeyPreview(apiKey.trim()) : '',
        baseURLText: result.endpoint,
        relayKind: 'openai_compatible',
        relayRequested: requested,
        relayResolvedBaseURLText: apiBaseURL,
        relayResolvedTransport: transport,
        relayResolvedAuthMode: openWebUI ? 'bearer' : 'none',
        relayCapabilityBitmap: buildRelayCapabilityBitmap(transport, {
          catalogEvidenceSucceeded: true,
        }),
        relayProbeVersion: 2,
        relayLastProbeAt: new Date().toISOString(),
    };
    const committed = await providerOps.addProvider(getVanillaStore(), provider, {
      shouldCommit: () => connection.canCommit(committedResult),
    });
    if (committed === false || !connection.canCommit(committedResult)) return;
    if (models.some((model) => model.id === selectedModel)) {
      setLastUsedModelRef({ providerID: provider.id, modelID: selectedModel });
    }
    trackKeyValidated({ success: true, endpoint: apiBaseURL });
    router.push(`/providers/${provider.id}`);
  };

  return (
    <>
      {!supported ? <section className={styles.statusCard} data-state="error" role="status"><strong>{t('probeBlocked')}</strong><p>{t('networkFailure')}</p></section> : (
        <div className={styles.form}>
          <div className={styles.field}>
            <label htmlFor="local-endpoint"><Link size={16} aria-hidden="true" />{td('engineAddress')}</label>
            <div className={styles.inputShell}>
              <span className={styles.schemeChip} data-testid="local-endpoint-scheme" aria-hidden="true">{endpointSchemeChip(endpoint)}</span>
              <input ref={endpointInputRef} id="local-endpoint" className={styles.shellInput} value={endpointSlotText(endpoint)} placeholder={endpointSlotText(LOCAL_ENGINE_TEMPLATES[board.showsManualPicker ? manualEngine : 'ollama'].defaultEndpoint)} onChange={(event) => { invalidateConnection(); setEndpoint(endpointFromSlotInput(endpoint, event.target.value)); }} spellCheck={false} disabled={connecting} />
            </div>
            {board.lanHttpBlocked
              ? <span className={styles.fieldError}>{t('localLanHttpBlocked')}</span>
              : board.slots.includes('apiKey') ? null : <small>{t('localNoCredentials')}</small>}
          </div>
          {endpointAccess.kind === 'invalid' ? <section className={styles.statusCard} data-state="error" role="status"><p>{t('invalidRequestURL')}</p></section> : null}
          {board.showsManualPicker ? (
            <div className={styles.manualPanel}>
              <div className={styles.field}>
                <label htmlFor="local-engine">{t('engine')}</label>
                <select id="local-engine" className={styles.input} value={manualEngine} onChange={(event) => selectEngine(event.target.value as LocalEngineKind)} disabled={connecting}>
                  {LOCAL_SETUP_ENGINES.map((item) => <option key={item} value={item}>{localEngineDisplayName(item)}</option>)}
                </select>
              </div>
              {board.showsChannelPicker ? (
                <div className={styles.field}>
                  <label htmlFor="local-channel">{t('localTileChannel')}</label>
                  <select id="local-channel" className={styles.input} value={manualChannel} onChange={(event) => { invalidateConnection(); setManualChannel(event.target.value as LocalChannel); }} disabled={connecting}>
                    {LOCAL_CHANNELS.map((item) => <option key={item} value={item} data-testid="relay_setup_local_channel_menu_option">{localChannelDisplayName(item)}</option>)}
                  </select>
                </div>
              ) : null}
            </div>
          ) : null}
          {board.slots.includes('apiKey') ? <div className={styles.field}><label htmlFor="local-api-key">{t('apiKeyLabel')}</label><input id="local-api-key" className={styles.input} type="password" autoComplete="off" value={apiKey} placeholder={t('apiKeyPlaceholder')} onChange={(event) => { invalidateConnection(); setApiKey(event.target.value); }} disabled={connecting} /></div> : null}
          <LocalDetectionCard board={board} result={result} />
          <div className={styles.actionBar}>
            <Button className={styles.primaryAction} onClick={board.primaryButton === 'connectAndSave' ? saveDetectedLocal : connect} disabled={!board.isPrimaryEnabled}>{connecting ? <CircleNotch className={styles.spinner} size={18} data-spinner aria-hidden="true" /> : board.primaryButton === 'connectAndSave' ? <Check size={18} weight="bold" /> : <Scan size={18} weight="bold" />}<span>{connecting ? t('detecting') : t(board.primaryButton)}</span></Button>
          </div>
          <button type="button" className={styles.manualToggle} data-testid="relay_setup_local_manual_engine_toggle" onClick={() => { invalidateConnection(); setManualExpanded((expanded) => !expanded); }} disabled={connecting}>
            <SlidersHorizontal size={18} aria-hidden="true" />
            <span>{t(LOCAL_SETUP_SECONDARY_KEY)}</span>
            <CaretRight size={16} className={styles.disclosureCaret} data-open={board.showsManualPicker} aria-hidden="true" />
          </button>
        </div>
      )}
    </>
  );
}

/** Detection card: recognized = summary line + three tiles; engine not recognized = warning card; connection failure keeps the existing failure line. */
function LocalDetectionCard({ board, result }: { board: LocalSetupBoard; result: LocalSetupConnectionValue | null }) {
  const t = useTranslations('pages.relaySetup');
  const td = useTranslations('pages.relayDetail');
  if (board.card === 'hidden' || !result && board.card !== 'detecting') return null;
  if (board.card === 'detecting') {
    return (
      <section className={styles.statusCard} data-state="detecting" role="status">
        <strong><CircleNotch className={styles.spinner} size={16} aria-hidden="true" />{t('detecting')}</strong>
      </section>
    );
  }
  if (board.failure === 'unrecognized') {
    return (
      <section className={styles.statusCard} data-state="warning" role="status">
        <div className={styles.cardHeadline}>
          <WarningCircle size={26} weight="duotone" aria-hidden="true" />
          <div><strong>{t('localUnrecognizedTitle')}</strong><p>{t('localUnrecognizedBody')}</p></div>
        </div>
      </section>
    );
  }
  if (board.failure === 'connection' || !board.summary) {
    return (
      <section className={styles.statusCard} data-state="error" role="status">
        <p>{result?.failure === 'cleartext_credentials' ? td('cleartextCredentialsBlocked') : t(localFailureKey(result?.failure))}</p>
      </section>
    );
  }
  const { summary } = board;
  return (
    <section className={styles.statusCard} data-state="success" role="status">
      <div className={styles.cardHeadline}>
        <CheckCircle size={26} weight="duotone" aria-hidden="true" />
        <div><strong>{t('localRecognized', { engine: summary.engine, count: summary.modelCount })}</strong></div>
      </div>
      <dl className={styles.summaryTiles}>
        <div><dt>{t('localTileChannel')}</dt><dd>{summary.channel}</dd></div>
        <div><dt>{t('localTileContext')}</dt><dd>{summary.contextLength ?? t('localValueUnavailable')}</dd></div>
        <div><dt>{t('localTileThinking')}</dt><dd>{t(summary.thinking)}</dd></div>
      </dl>
    </section>
  );
}

function localFailureKey(failure: LocalBrowserConnectionResult['failure'] | undefined): string {
  if (failure === 'permission_denied') return 'probeBlocked';
  if (failure === 'cors_blocked') return 'networkFailure';
  if (failure === 'unsafe_address' || failure === 'redirect_blocked') return 'invalidRequestURL';
  if (failure === 'credential_required') return 'apiKeyRequired';
  if (failure === 'authentication_rejected') return 'authenticationRejected';
  return 'invalidResponse';
}
