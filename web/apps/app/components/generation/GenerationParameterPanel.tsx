'use client';

import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronRight } from 'lucide-react';
import type { AIModel, Provider } from '@oriveo/shared';
import type { GenerationParameterOverrides, GenerationParameterProfile, GenerationParameterValue } from '@oriveo/core/providers/request-builders/types';
import {
  previewGenerationCompatibility,
  removeGenerationConflicts,
  validateOutputContractValue,
} from '@oriveo/core/providers/generation-workbench';
import { relayGenerationEndpointFingerprint } from '@oriveo/core/providers/relay-orchestrator';
import {
  applyGenerationParameterPreset,
  exportGenerationParameterSettingsJSON,
  importGenerationParameterSettingsJSON,
  loadGenerationParameterOverrides,
  listGenerationParameterPresets,
  removeGenerationParameterPreset,
  saveGenerationParameterOverrides,
  saveConnectionGenerationParameterDefaults,
  saveGenerationParameterPreset,
  generationParameterProfileFingerprint,
  valueOverride,
} from '../../lib/core/chat/generation-parameter-settings';
import {
  buildProviderStreamOptions,
  generationParameterAdjustable,
  isReasoningParameter,
  modelSupportsGenerationParameter,
  resolveGenerationProfileForModel,
} from '../../lib/core/chat/stream-options';
import { capabilityRuntimeIdentity } from '../../lib/core/chat/capability-preference-settings';
import {
  generationPanelEmptyState,
  generationPanelVisibleParameters,
  hasSeenNonEmptyGenerationProfile,
  recordSeenGenerationProfile,
  showsUnverifiedBadge,
  showsUnverifiedGroupNote,
  type GenerationParameterEmptyState,
} from '../../lib/core/chat/generation-panel-presentation';
import { partitionGenerationParameterValues } from '../../lib/core/chat/generation-parameter-lifecycle';
import {
  effectiveGenerationSupport,
  generationSupportPresentation,
} from '../../lib/core/chat/generation-support-presentation';
import { clearUnsupportedParamLearning } from '@oriveo/core/providers/unsupported-param';
import { getRelayRuntimeConfig } from '../../lib/core/metadata/metadata-client';
import {
  relayCapabilityEvidenceIdentity,
  resolveGenerationParameterEvidence,
} from '../../lib/core/chat/capability-evidence';
import { useCapabilityEvidenceExpiry } from '../../lib/core/chat/use-capability-evidence-expiry';
import { showToast } from '../Toast';
import {
  clearGenerationParameterDiagnostics,
  exportGenerationParameterDiagnosticsJSON,
  listGenerationParameterDiagnostics,
} from '../../lib/core/chat/generation-parameter-diagnostics';
import {
  CUSTOM_FRAGMENT_SETTINGS_EVENT,
  customFragmentEntryState,
  customFragmentSupportedModels,
  forwardPortCustomFragmentsIfNeeded,
} from '../../lib/core/chat/custom-fragment-settings';
import { CustomRequestFieldsEditor } from './CustomRequestFieldsEditor';
import styles from './GenerationParameterPanel.module.css';

type Scope = 'default' | 'session';
type ProfileParameter = GenerationParameterProfile['parameters'][number];
type CommonTranslator = ReturnType<typeof useTranslations>;

const GENERATION_PARAMETER_LABEL_KEYS: Readonly<Record<string, string>> = {
  max_output_tokens: 'generationParameterNameMaxOutputTokens',
  min_tokens: 'generationParameterNameMinTokens',
  temperature: 'generationParameterNameTemperature',
  top_p: 'generationParameterNameTopP',
  top_k: 'generationParameterNameTopK',
  frequency_penalty: 'generationParameterNameFrequencyPenalty',
  presence_penalty: 'generationParameterNamePresencePenalty',
  repetition_penalty: 'generationParameterNameRepetitionPenalty',
  seed: 'generationParameterNameSeed',
  stop: 'generationParameterNameStop',
  verbosity: 'generationParameterNameVerbosity',
  logprobs: 'generationParameterNameLogprobs',
  top_logprobs: 'generationParameterNameTopLogprobs',
  reasoning_effort: 'generationParameterNameReasoningEffort',
  reasoning_budget: 'generationParameterNameReasoningBudget',
  reasoning_mode: 'generationParameterNameReasoningMode',
  response_format: 'generationParameterNameResponseFormat',
};

function generationParameterLabel(id: string | undefined, tc: CommonTranslator): string {
  return tc(GENERATION_PARAMETER_LABEL_KEYS[id ?? ''] ?? 'generationParameters');
}

function generationSourceLabel(_source: string | undefined, tc: CommonTranslator): string {
  return tc('generationSourceOther');
}

function generationTransportLabel(_transport: string | undefined, tc: CommonTranslator): string {
  return tc('generationTransportOther');
}

function generationCompatibilityIssueLabel(
  issue: { key: string; kind: 'conflict' | 'requires' | 'rendering' | 'streaming'; conflictsWith?: string },
  tc: CommonTranslator,
): string {
  const parameter = generationParameterLabel(issue.key, tc);
  return `${parameter}: ${tc('issue')}`;
}

type GenerationParameterPanelProps = {
  provider: Provider;
  model: AIModel;
  conversationId?: string;
  scope?: Scope;
  onOverrideChange?: (hasOverride: boolean) => void;
  /**
   * Grey out controls in the "not adjustable" class, but always give them a primary
   * action, otherwise the row is a dead end. The panel does not know where the model
   * switcher lives, so it only hands out the parameter id and the host opens the
   * switcher with its existing filter.
   *
   * Omitting this is not a dead end either: mount points with no model switcher expand a
   * read-only candidate list in place, the same fallback `DeveloperGroup` uses, so the
   * user still learns which models make the parameter adjustable.
   */
  onFindSupportedModels?: (parameterId: string) => void;
  /**
   * Read-only propagation while sending. Read-only means "cannot be changed right now",
   * not "this feature is absent": the parameter area becomes non-editable while the
   * developer group still renders as a status line.
   */
  isReadOnly?: boolean;
  /**
   * Passed when the host carries the custom request fields layer itself (the popover
   * switches to a third pane). Without it the panel pushes that layer internally, which
   * is required where the host has no pane stack and must offer its own way back.
   */
  onOpenCustomFields?: () => void;
  /** Way out of "this model has no custom fields": pick a model that declares a field schema. */
  onSelectCustomFieldsModel?: (model: AIModel) => void;
  /**
   * Set when the host already renders a title bar of its own (the popover's second pane
   * does). Writing "advanced settings" twice on one screen reads like a nested panel.
   * The scope line still renders.
   */
  hidesTitle?: boolean;
  /**
   * Set when the host is itself an already-scrolling container (the model options
   * popover's advanced settings pane). The panel gives up its border, shadow, max-height
   * and own overflow so a single outer scroller owns the gesture; two nested overflow
   * containers stall the screen at the inner boundary.
   */
  embedded?: boolean;
};

export function GenerationParameterPanel({
  provider,
  model,
  conversationId,
  scope = 'default',
  onOverrideChange,
  onFindSupportedModels,
  isReadOnly = false,
  onOpenCustomFields,
  onSelectCustomFieldsModel,
  hidesTitle = false,
  embedded = false,
}: GenerationParameterPanelProps) {
  const tc = useTranslations('common');
  const t = useTranslations('pages.providerDetail');
  const backupT = useTranslations('pages.backup');
  const profile = resolveGenerationProfileForModel(provider, model);
  const key = useMemo(() => ({
    providerId: provider.id,
    modelId: model.id,
    profileFingerprint: generationParameterProfileFingerprint(provider, model),
    ...(scope === 'session' && conversationId ? { conversationId } : {}),
  }), [conversationId, model, provider, scope]);
  const generationCapabilityOptions = useMemo(
    () => buildProviderStreamOptions(provider, undefined, model),
    [model, provider],
  );
  useCapabilityEvidenceExpiry(provider, model, generationCapabilityOptions);
  const relayEvidenceIdentity = useMemo(
    () => relayCapabilityEvidenceIdentity(provider, model, generationCapabilityOptions),
    [generationCapabilityOptions, model, provider],
  );
  // A clear request needs the full connection identity: the first four segments of both the
  // renderer and main cache keys come from it, and without them the partition cannot be
  // located. When identity is unavailable, no clear entry is shown.
  const unsupportedParamScope = useMemo(() => {
    if (provider.kind !== 'relay' || !relayEvidenceIdentity) return undefined;
    try {
      const endpointFingerprint = relayGenerationEndpointFingerprint(
        provider.baseURLText,
        model.id,
        generationCapabilityOptions,
        getRelayRuntimeConfig(),
      );
      return endpointFingerprint
        ? {
          providerKind: 'relay' as const,
          modelID: model.id,
          endpointFingerprint,
          partitionId: relayEvidenceIdentity.partitionId,
          connectionInstanceId: relayEvidenceIdentity.connectionInstanceId,
          connectionGeneration: relayEvidenceIdentity.connectionGeneration,
          credentialEpoch: relayEvidenceIdentity.credentialEpoch,
        }
        : undefined;
    } catch {
      // No fake clear entry while the connection address cannot form a valid production request.
      return undefined;
    }
  }, [generationCapabilityOptions, model, provider, relayEvidenceIdentity]);
  const [values, setValues] = useState<GenerationParameterOverrides>(() => loadGenerationParameterOverrides(key) ?? {});
  const [presetName, setPresetName] = useState('');
  const [presetRevision, setPresetRevision] = useState(0);
  const [diagnosticRevision, setDiagnosticRevision] = useState(0);
  const [dormantExpanded, setDormantExpanded] = useState(false);
  /** Carry the custom request fields layer here when the host has no pane stack of its own. */
  const [ownsCustomFieldsPage, setOwnsCustomFieldsPage] = useState(false);
  /** Pending confirmation for "restore defaults": it is an irreversible full wipe, so a single tap must not run it. */
  const [pendingReset, setPendingReset] = useState(false);
  /** Previous frame's dormant ids; null means the first frame, which never reports a restore. */
  const previousDormantIDs = useRef<string[] | null>(null);
  const importInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setValues(loadGenerationParameterOverrides(key) ?? {});
  }, [key]);

  useEffect(() => { setOwnsCustomFieldsPage(false); }, [model.id, provider.id]);

  useEffect(() => {
    const refresh = () => setDiagnosticRevision((revision) => revision + 1);
    window.addEventListener('oriveo:unsupported-param-self-healed', refresh);
    return () => window.removeEventListener('oriveo:unsupported-param-self-healed', refresh);
  }, []);

  // Records that a non-empty profile has been seen for this model on this connection. The
  // test uses the declared parameter count rather than the visible one: state B asks whether
  // the profile ever had content, not whether filtering emptied it.
  const declaredCount = profile?.parameters?.length ?? 0;
  useEffect(() => {
    recordSeenGenerationProfile(provider.id, model.id, declaredCount);
  }, [declaredCount, model.id, provider.id]);

  // The visible set may only be asked of this one function, which is also what the composer chip's
  // entryVisible calls. Any second copy of the rules here would let the chip promise a row the
  // panel then refuses to draw.
  const entryScope = scope === 'session' ? 'session' : 'connectionDefaults';
  const visible = generationPanelVisibleParameters(provider, model, entryScope);
  const emptyState = generationPanelEmptyState({
    provider,
    model,
    scope: entryScope,
    hasSeenNonEmptyProfile: hasSeenNonEmptyGenerationProfile(provider.id, model.id),
  });
  const visibleEvidence = profile ? visible.map((parameter) => resolveGenerationParameterEvidence({
    provider,
    model,
    profile,
    parameterId: parameter.id!,
    hasExplicitValue: values[parameter.id!]?.state === 'value',
    relayIdentity: relayEvidenceIdentity,
    streamOptions: generationCapabilityOptions,
    generationRevision: profile.revision ?? model.metadataRevision,
  })) : [];

  // Split stored values field by field into active and dormant against the current profile.
  // This must run before the empty-state early return, because the dormant summary also
  // appears at the bottom of the empty state.
  const partition = partitionGenerationParameterValues({ provider, model, values });
  const dormantIds = partition.dormantIds;

  const persist = (next: GenerationParameterOverrides) => {
    setValues(next);
    saveGenerationParameterOverrides(key, next);
    // Same rule as the composer dot: only currently effective values count, dormant ones do not.
    onOverrideChange?.(Object.values(
      partitionGenerationParameterValues({ provider, model, values: next }).active,
    ).some((item) => item?.state !== 'inherit'));
  };

  // When a profile matches again the compatible values come back on their own (they were never
  // deleted, only the criteria changed), so show a one-off toast. Dormant values removed by
  // "clear" cannot be misreported as restored, because `values[id]` is gone.
  const dormantKey = dormantIds.join('|');
  useEffect(() => {
    const previous = previousDormantIDs.current;
    previousDormantIDs.current = dormantIds;
    if (previous === null) return; // First frame only records the snapshot and shows no toast
    const restored = previous.filter((id) => !dormantIds.includes(id) && values[id] !== undefined);
    if (restored.length > 0) {
      showToast(tc('generationParameterDormantRestored', { count: restored.length }), 3000, undefined, 'success');
    }
    // Only compare when the dormant set actually changes, so the same toast is not repeated.
  }, [dormantKey]);

  const dormantSummary = dormantIds.length > 0 ? (
    <div className={styles.dormant} data-testid="generation-dormant-summary">
      <p>{tc('generationParameterDormantSummary', { count: dormantIds.length })}</p>
      <div className={styles.portableActions}>
        <button type="button" onClick={() => setDormantExpanded((expanded) => !expanded)}>
          {tc('generationParameterDormantView')}
        </button>
        {/* No clear action while read-only: it is a write, and nothing on this page can be written right now. */}
        {!isReadOnly && <button type="button" onClick={() => {
          // Delete only the dormant half and leave effective values alone; an empty record gets a tombstone from the storage layer.
          persist(partition.active);
          setDormantExpanded(false);
        }}>{tc('generationParameterDormantClear')}</button>}
      </div>
      {dormantExpanded && <ul className={styles.dormantList}>
        {dormantIds.map((id) => (
          <li key={id}>
            <span>{generationParameterLabel(id, tc)}</span>
            <span>{dormantValueText(partition.dormant[id], tc('remove'))}</span>
          </li>
        ))}
      </ul>}
    </div>
  ) : null;

  // The session form and the connection form are the same page and share one title; two names
  // for the same thing reads as two different features. The scope difference is carried
  // entirely by the two lines below.
  // "Restore defaults" is an irreversible full wipe, so tapping it only enters a pending
  // confirmation state, using the same confirmation copy as the other clients.
  const panelHeader = (reset?: () => void) => (
    <>
      <div className={styles.header}>
        <div>
          {!hidesTitle && <strong>{tc('modelBehavior')}</strong>}
          <p>{`${tc(scope === 'session' ? 'currentConversation' : 'connectionDefaults')} - ${model.name}`}</p>
        </div>
        {reset && !isReadOnly && (
          <button
            type="button"
            className={styles.reset}
            aria-expanded={pendingReset}
            onClick={() => setPendingReset(true)}
          >{tc('restoreModelBehavior')}</button>
        )}
      </div>
      {reset && !isReadOnly && pendingReset && (
        <div className={styles.resetConfirm} role="group" aria-label={tc('restoreModelBehavior')}>
          <p className={styles.customHint}>{tc('restoreModelBehaviorConfirm')}</p>
          <button type="button" onClick={() => setPendingReset(false)}>{tc('cancel')}</button>
          <button
            type="button"
            className={styles.customDangerAction}
            onClick={() => {
              reset();
              setPendingReset(false);
            }}
          >{tc('restoreModelBehavior')}</button>
        </div>
      )}
    </>
  );
  const scopeDetail = (
    <p className={styles.scopeHint}>
      {tc(scope === 'session' ? 'modelBehaviorScopeHint' : 'modelBehaviorConnectionScopeHint')}
    </p>
  );
  const developerGroup = (
    <DeveloperGroup
      provider={provider}
      model={model}
      isReadOnly={isReadOnly}
      onOpen={onOpenCustomFields ?? (() => setOwnsCustomFieldsPage(true))}
      {...(onSelectCustomFieldsModel ? { onSelectModel: onSelectCustomFieldsModel } : {})}
    />
  );

  // The custom request fields layer carried by this panel. It must come before the empty-state
  // check: once the schema is gone the panel falls entirely into the empty state, which is
  // exactly when the user most needs to get in and turn the configuration off.
  if (ownsCustomFieldsPage) {
    return (
      <section className={styles.panel} data-embedded={embedded ? 'true' : undefined} aria-label={tc('customRequestFieldsCustom')}>
        <div className={styles.subPageHeader}>
          <button type="button" className={styles.subPageBack} onClick={() => setOwnsCustomFieldsPage(false)}>
            {tc('back')}
          </button>
          <strong>{tc('customRequestFieldsCustom')}</strong>
        </div>
        <CustomRequestFieldsEditor
          provider={provider}
          model={model}
          {...(scope === 'session' && conversationId ? { conversationId } : {})}
        />
      </section>
    );
  }

  if (emptyState || !profile) {
    // Once the entry is permanent the container must never silently disappear: it stays visible
    // and renders one of the four titled empty states. With no profile it falls back to "not
    // verified", which is both true for a connection without a profile and the fail-safe side.
    const state: GenerationParameterEmptyState = emptyState ?? 'notVerified';
    return (
      <section className={styles.panel} data-embedded={embedded ? 'true' : undefined} aria-label={tc('modelBehavior')}>
        {panelHeader()}
        {scopeDetail}
        <div className={styles.group}>
          <strong className={styles.emptyTitle}>{tc('generationParameters')}</strong>
          <p className={styles.emptyHeadline}>{tc(EMPTY_STATE_TITLE_KEY[state])}</p>
          {state === 'notVerified' && (
            <p className={styles.scopeHint}>{tc('generationParameterEmptyNotVerifiedBody')}</p>
          )}
          {/* Bottom of the empty state: a one-line summary with view and clear actions, shown only when dormant values exist. */}
          {dormantSummary}
        </div>
        {/* The developer group is always present in the empty state too: a feature row evaporating along with the parameter table reads as a fault. */}
        {developerGroup}
      </section>
    );
  }

  const reset = () => persist({});
  const showsConnectionTools = scope === 'default' && !isReadOnly;
  const portableMapping = Object.fromEntries(profile.parameters
    .filter((parameter) => parameter.portability === 'portable' && parameter.id)
    .map((parameter) => [parameter.id!, parameter.id!]));
  const presets = listGenerationParameterPresets({ ...key, portableParameterIds: Object.keys(portableMapping) });
  const compatibilityIssues = previewGenerationCompatibility({ profile, overrides: values, streaming: true });
  const diagnostics = listGenerationParameterDiagnostics()
    .filter((entry) => !entry.modelId || entry.modelId === model.id);
  return (
    <section className={styles.panel} data-embedded={embedded ? 'true' : undefined} aria-label={tc('modelBehavior')}>
      {panelHeader(reset)}
      {scopeDetail}
      {/* An explanatory sentence, not a parameter row: a single full-width line with its own
          background, rather than a hairline plus two columns, whose skeleton is identical to
          .row and reads as one more disabled control. */}
      {scope === 'session' && profile.parameters.some(isReasoningParameter) && (
        <p className={styles.reasoningNotice} data-testid="generation-reasoning-notice">
          <strong>{tc('reasoning')}</strong>
          {' — '}
          {tc('controlledByReasoningShortcut')}
        </p>
      )}
      {/* Whenever the rendered set contains a relay unknown parameter, the group note is mandatory; omitting it would present a fake certainty. */}
      {showsUnverifiedGroupNote(visibleEvidence) && (
        <p className={styles.scopeHint}>{tc('generationParameterUnverifiedGroupNote')}</p>
      )}
      {/* Connection-level tools (presets, backup, diagnostics, relay tools) appear only on the
          provider detail side. The chat path is about changing this one conversation, and
          connection-level tools there would bury the task at hand. Hidden while read-only too. */}
      {showsConnectionTools && <div className={styles.presets}>
        <input
          value={presetName}
          aria-label={tc('generationPresetName')}
          placeholder={tc('generationPresetName')}
          onChange={(event) => setPresetName(event.target.value)}
        />
        <button type="button" disabled={!presetName.trim()} onClick={() => {
          saveGenerationParameterPreset({ ...key, name: presetName, values });
          setPresetName('');
          setPresetRevision((revision) => revision + 1);
        }}>{tc('save')}</button>
        {presets.map((preset) => <span key={`${preset.id}-${presetRevision}`} className={styles.preset}>
          <button type="button" onClick={() => {
            const applied = applyGenerationParameterPreset(preset, key, portableMapping);
            if (applied) persist(applied);
          }}>{preset.name}</button>
          <button type="button" aria-label={preset.name} title={preset.name} onClick={() => {
            const copied = applyGenerationParameterPreset(preset, key, portableMapping);
            if (copied) saveGenerationParameterPreset({ ...key, name: preset.name, values: copied });
            setPresetRevision((revision) => revision + 1);
          }}> </button>
          <button type="button" aria-label={tc('delete')} title={tc('delete')} onClick={() => {
            removeGenerationParameterPreset(preset.id);
            setPresetRevision((revision) => revision + 1);
          }}>×</button>
        </span>)}
      </div>}
      {showsConnectionTools && <div className={styles.portableActions}>
        <button type="button" onClick={() => {
          const portableIDs = new Set(profile.parameters
            .filter((parameter) => parameter.portability === 'portable')
            .map((parameter) => parameter.id));
          saveConnectionGenerationParameterDefaults(provider.id, Object.fromEntries(
            Object.entries(values).filter(([id]) => portableIDs.has(id)),
          ));
        }}>{tc('saveConnectionDefaults')}</button>
        <button type="button" onClick={() => {
          const blob = new Blob([exportGenerationParameterSettingsJSON()], { type: 'application/json' });
          const url = URL.createObjectURL(blob);
          const anchor = document.createElement('a');
          anchor.href = url;
          anchor.download = 'oriveo-generation-parameters.v1.json';
          anchor.click();
          URL.revokeObjectURL(url);
        }}>{backupT('export')}</button>
        <button type="button" onClick={() => importInput.current?.click()}>{backupT('import')}</button>
        <input
          ref={importInput}
          className={styles.hiddenInput}
          type="file"
          accept="application/json,.json"
          onChange={(event) => {
            const file = event.target.files?.[0];
            if (!file) return;
            void file.text().then((raw) => {
              importGenerationParameterSettingsJSON(raw);
              setValues(loadGenerationParameterOverrides(key) ?? {});
              setPresetRevision((revision) => revision + 1);
            }).catch(() => {});
            event.currentTarget.value = '';
          }}
        />
      </div>}
      {compatibilityIssues.length > 0 && <div className={styles.compatibility}>
        <span>{compatibilityIssues.map((issue) => generationCompatibilityIssueLabel(issue, tc)).join(' - ')}</span>
        {!isReadOnly && compatibilityIssues.some((issue) => issue.kind === 'conflict' || issue.kind === 'requires') && (
          <button type="button" onClick={() => persist(removeGenerationConflicts(values, compatibilityIssues))}>{tc('remove')}</button>
        )}
      </div>}
      {/* Clear the locally learned negative cache of which parameters this relay endpoint
          rejects. This is not "restore defaults" and touches no user-set parameter value. */}
      {showsConnectionTools && unsupportedParamScope && <div className={styles.portableActions}>
        <button type="button" onClick={() => {
          clearUnsupportedParamLearning(unsupportedParamScope);
          setDiagnosticRevision((revision) => revision + 1);
        }}>{tc('generationParameterClearLearnedCapabilities')}</button>
      </div>}
      <ParameterGroup
        title={tc('generationBasicSettings')}
        parameters={basicParameters(visible)}
        defaultOpen
        render={(parameter) => renderParameter(parameter)}
      />
      {GROUP_ORDER.map((group) => (
        <ParameterGroup
          key={group}
          title={tc(GROUP_LABELS[group])}
          parameters={advancedParameters(visible).filter((parameter) => (parameter.group ?? 'sampling') === group)}
          render={(parameter) => renderParameter(parameter)}
        />
      ))}
      {/* What "leave empty" means is what BYOK users care about most on this page: the field
          is simply absent from the request body, rather than filled in with a default. Session
          scope only, since the connection defaults path is about defaults and not about
          whether a field is sent on one request. */}
      {scope === 'session' && (
        <p className={styles.scopeHint} data-testid="generation-unset-note">{tc('generationParameterUnsetNote')}</p>
      )}
      {/* After transport is corrected at runtime, an old scope record can keep only some of its
          parameters in the new protocol template, so the panel is non-empty while those values
          have no row. The summary must appear here too, or dormant values in the non-empty
          state become silent orphans. */}
      {dormantSummary}
      {showsConnectionTools && <details className={styles.group} key={diagnosticRevision}>
        <summary>{tc('generationDiagnosticsHistory')}</summary>
        <div className={styles.diagnostics}>
          {diagnostics.length === 0 && <p>{tc('generationDiagnosticsEmpty')}</p>}
          {diagnostics.slice(0, 20).map((entry) => (
            <div key={entry.id}>
              <span>{generationParameterLabel(entry.parameter, tc)}</span>
              <span>{entry.status === 'recovered' ? tc('connected') : tc('issue')} - {generationTransportLabel(entry.transport, tc)}</span>
            </div>
          ))}
          {diagnostics.length > 0 && <div className={styles.portableActions}>
            <button type="button" onClick={() => {
              const blob = new Blob([exportGenerationParameterDiagnosticsJSON()], { type: 'application/json' });
              const url = URL.createObjectURL(blob);
              const anchor = document.createElement('a');
              anchor.href = url;
              anchor.download = 'oriveo-generation-diagnostics.redacted.json';
              anchor.click();
              URL.revokeObjectURL(url);
            }}>{backupT('export')}</button>
            <button type="button" onClick={() => {
              clearGenerationParameterDiagnostics();
              setDiagnosticRevision((revision) => revision + 1);
            }}>{tc('delete')}</button>
          </div>}
        </div>
      </details>}
      {/* The developer group is always the last cell and does not disappear while read-only. */}
      {developerGroup}
    </section>
  );

  function renderParameter(parameter: ProfileParameter) {
        const id = parameter.id!;
        const override = values[id];
        const evidence = resolveGenerationParameterEvidence({
          provider,
          model,
          profile: profile!,
          parameterId: id,
          hasExplicitValue: override?.state === 'value',
          relayIdentity: relayEvidenceIdentity,
          streamOptions: generationCapabilityOptions,
          generationRevision: profile!.revision ?? model.metadataRevision,
        });
        // Visibility/editability and wire injection are deliberately separate:
        // a runtime rejection suppresses only this process's request, not the
        // upstream support fact or the user's ability to amend the value.
        //
        // The editable test and the "show models supporting this parameter" filter must be the
        // same function, or a user can follow the filter, open the panel, and find the row still
        // greyed out.
        const adjustable = generationParameterAdjustable(profile?.wire[id], parameter.support, evidence);
        // The presentation class is read from the shared contract's presentationClasses table
        // rather than an inline switch. The evidence layer has only three values, and feeding it
        // straight in as presentation input is what made accepted_unverified unreachable and
        // unsupported read as unknown; start from the eight states the profile declares and let
        // evidence only veto or downgrade.
        const presentation = generationSupportPresentation(
          effectiveGenerationSupport(parameter.support, evidence),
        );
        return (
          <ParameterRow
            key={id}
            parameter={parameter}
            override={override}
            // The three reasoning parameters are editable in connection scope (values really go
            // out through mergeFirstExplicit); in session scope reasoning is owned solely by the
            // composer chip and is not rendered here. The editable test must share the outbound
            // allow list and may never be wider than it. When the panel as a whole is read-only
            // (managed connection or sending), narrow it once more.
            editable={adjustable && !isReadOnly}
            // Only temperature and max tokens get a plain-language annotation: they are the two
            // parameters most people ever touch, and the parameter name alone explains nothing to
            // a non-developer. Annotating every row would bury these two.
            annotation={PARAMETER_ANNOTATION_KEYS[id] ? tc(PARAMETER_ANNOTATION_KEYS[id]!) : undefined}
            // Locally synthesized relay unknown parameters stay adjustable, at the cost of saying
            // per row that support is inferred from the protocol and never measured. The badge is
            // neutral, not a warning.
            unverifiedLabel={adjustable && showsUnverifiedBadge(evidence)
              ? tc('generationParameterUnverifiedBadge')
              : undefined}
            inputID={`generation-${provider.id}-${model.id}-${id}`}
            defaultLabel={t('defaultURL')}
            omitLabel={tc('remove')}
            // supported and accepted are the normal case, and the normal case says nothing: ten
            // repeated "supported, source ..." lines would bury the unverified, fixed and unknown
            // rows that do need attention. Every other state keeps its full label including
            // Source, the only clue to where a verdict came from and what locally synthesized
            // relay parameters rely on.
            supportLabel={presentation.renders && presentation.labelKey ? tc(presentation.labelKey) : undefined}
            supportDetail={presentation.renders && presentation.detailKey ? tc(presentation.detailKey) : undefined}
            // Exit for the "not adjustable" class. The test reads the shared contract's
            // presentation class rather than the support literal; fixed, unsupported and
            // mode_dependent are assigned by presentationClasses.
            notAdjustableAction={presentation.classId === 'not_adjustable'
              ? {
                label: tc('generationParameterFindSupportedModels'),
                ...(onFindSupportedModels
                  ? { onClick: () => onFindSupportedModels(id) }
                  // With no switcher to open, list the candidates in place. Evaluated lazily:
                  // this resolves a generation profile plus evidence for every model on the
                  // connection, so doing it during render would repeat that once per frame for
                  // every non-adjustable parameter.
                  : { listCandidates: () => supportedModelNames(provider, model, id) }),
                emptyLabel: tc('capabilityControlNoSupportedModels'),
              }
              : undefined}
            sourceLabel={`${tc('generationParameterSource')}: ${generationSourceLabel(parameter.source, tc)}`}
            jsonSchemaLabel={tc('generationJsonSchemaLabel')}
            onClear={() => {
              const next = { ...values };
              delete next[id];
              persist(next);
            }}
            onOmit={() => persist({ ...values, [id]: { state: 'omit' } })}
            onChange={(value) => {
              const next = { ...values };
              for (const conflict of parameter.conflictsWith ?? []) delete next[conflict];
              for (const candidate of visible) {
                if (candidate.conflictsWith?.includes(id)) delete next[candidate.id];
              }
              persist({ ...next, [id]: valueOverride(value) });
            }}
          />
        );
  }
}

/**
 * Developer group: the only entry point to custom request fields.
 *
 * Three hard rules:
 * 1. It does not disappear when read-only. Read-only means "cannot be changed right now",
 *    not "this feature is absent", and its state (unused / enabled) is exactly the fact a
 *    read-only user most needs. It degrades to a non-clickable status line instead.
 * 2. It does not disappear when unsupported either, and the row stays clickable: it gives the
 *    reason (which models have it) and the way out (which model to switch to). A row that
 *    vanishes on model switch only reads as a fault.
 * 3. State is read from storage once into React state and refreshed by subscribing to storage
 *    events (the editor writes and broadcasts on every keystroke), instead of decoding
 *    localStorage and parsing metadata three times per frame.
 */
function DeveloperGroup({ provider, model, isReadOnly, onOpen, onSelectModel }: {
  provider: Provider;
  model: AIModel;
  isReadOnly: boolean;
  onOpen?: () => void;
  onSelectModel?: (model: AIModel) => void;
}) {
  const tc = useTranslations('common');
  const transportIdentity = capabilityRuntimeIdentity(provider, model)?.transportIdentity;
  const [entry, setEntry] = useState(() => customFragmentEntryState({ provider, model, transportIdentity }));
  const [explained, setExplained] = useState(false);

  useEffect(() => {
    // Entering the page and switching models are discrete events, so run one lazy forward port
    // before reading. Without it a server recipe change that only bumps runtimeRevision would
    // flip this row from "enabled" back to "unused" with no user action. State is still read
    // from storage once here, not decoded per frame.
    const refresh = () => {
      if (transportIdentity) forwardPortCustomFragmentsIfNeeded({ provider, model, transportIdentity });
      setEntry(customFragmentEntryState({ provider, model, transportIdentity }));
    };
    refresh();
    window.addEventListener(CUSTOM_FRAGMENT_SETTINGS_EVENT, refresh);
    return () => window.removeEventListener(CUSTOM_FRAGMENT_SETTINGS_EVENT, refresh);
  }, [model, provider, transportIdentity]);

  const candidates = useMemo(
    () => customFragmentSupportedModels(provider).filter((candidate) => candidate.id !== model.id),
    [model.id, provider],
  );
  const statusText = tc(
    entry === 'unsupported' ? 'capabilityControlNotSupportedByModel'
      : entry === 'inUse' ? 'customRequestFieldsInUse'
      : 'customRequestFieldsNotInUse',
  );
  const rowLabel = (
    <>
      <span>{tc('customRequestFieldsCustom')}</span>
      <span className={styles.developerRowState}>{statusText}</span>
    </>
  );

  return (
    <div className={styles.developerGroup} data-testid="generation-developer-group">
      <strong className={styles.developerGroupTitle}>{tc('generationParameterDeveloper')}</strong>
      {isReadOnly ? (
        <div className={styles.developerRow} data-testid="generation-developer-row">{rowLabel}</div>
      ) : (
        <button
          type="button"
          className={styles.developerRow}
          data-interactive="true"
          data-testid="generation-developer-row"
          {...(entry === 'unsupported' ? { 'aria-expanded': explained } : {})}
          onClick={() => (entry === 'unsupported' ? setExplained((open) => !open) : onOpen?.())}
        >
          {rowLabel}
          {entry !== 'unsupported' && <ChevronRight size={14} aria-hidden="true" />}
        </button>
      )}
      {!isReadOnly && entry === 'unsupported' && explained && (
        <div className={styles.developerExplanation} data-testid="generation-developer-explanation">
          <p className={styles.customHint}>{tc('customRequestFieldsRequiresSchema')}</p>
          {candidates.length === 0 ? (
            // With no candidates at all, say plainly that switching models will not help, rather than opening an empty list.
            <p className={styles.customHint}>{tc('capabilityControlNoSupportedModels')}</p>
          ) : onSelectModel ? (
            <ul className={styles.developerCandidates}>
              {candidates.map((candidate) => (
                <li key={candidate.id}>
                  <button type="button" onClick={() => onSelectModel(candidate)}>{candidate.name}</button>
                </li>
              ))}
            </ul>
          ) : (
            // With no model-switch action from the host, just name the candidates: a button that cannot be clicked is worse than a plain statement.
            <p className={styles.customHint}>{candidates.map((candidate) => candidate.name).join(' - ')}</p>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * Which other models on this connection have this parameter adjustable (the read-only list).
 *
 * The test borrows `modelSupportsGenerationParameter` rather than adding a second one; two
 * copies would drift into "listed here, still greyed out there". The current model is excluded,
 * since switching to the model already in use is not a way out.
 */
function supportedModelNames(provider: Provider, current: AIModel, parameterId: string): string[] {
  return provider.models
    .filter((candidate) => candidate.id !== current.id
      && modelSupportsGenerationParameter(provider, candidate, parameterId))
    .map((candidate) => candidate.name);
}

/**
 * Titles for the three empty states, worded identically across clients.
 *
 * Copy rules: attribute to this connection rather than to the model, because evidence is
 * measured per provider and model and "the model does not support it" would be a claim without
 * evidence. No percentages, no progress numbers, no promised timelines.
 */
const EMPTY_STATE_TITLE_KEY: Record<GenerationParameterEmptyState, string> = {
  notVerified: 'generationParameterEmptyNotVerified',
  catalogManaged: 'generationParameterCatalogManaged',
  allUnsupported: 'generationParameterEmptyAllUnsupported',
};

/** Only these two parameters carry an annotation. */
const PARAMETER_ANNOTATION_KEYS: Readonly<Record<string, string | undefined>> = {
  temperature: 'generationParameterTemperatureNote',
  max_output_tokens: 'generationParameterMaxTokensNote',
};

const GROUP_ORDER = ['budget', 'reasoning', 'sampling', 'repetition', 'reproducibility', 'output_contract', 'engine_runtime'] as const;
const GROUP_LABELS: Record<(typeof GROUP_ORDER)[number], string> = {
  budget: 'generationGroupBudget', reasoning: 'generationGroupReasoning', sampling: 'generationGroupSampling',
  repetition: 'generationGroupRepetition', reproducibility: 'generationGroupReproducibility',
  output_contract: 'generationGroupOutputContract', engine_runtime: 'generationGroupEngineRuntime',
};

function basicParameters(parameters: ProfileParameter[]): ProfileParameter[] {
  const preferredSampling = parameters.find((item) => item.id === 'temperature')
    ?? parameters.find((item) => item.id === 'top_p');
  return parameters.filter((item) => item.id === 'max_output_tokens')
    .concat(preferredSampling ? [preferredSampling] : []);
}

function advancedParameters(parameters: ProfileParameter[]): ProfileParameter[] {
  const basic = new Set(basicParameters(parameters).map((item) => item.id));
  return parameters.filter((item) => !basic.has(item.id));
}

function ParameterGroup({ title, parameters, defaultOpen = false, render }: {
  title: string;
  parameters: ProfileParameter[];
  defaultOpen?: boolean;
  render: (parameter: ProfileParameter) => ReactNode;
}) {
  if (parameters.length === 0) return null;
  return <details className={styles.group} open={defaultOpen}>
    <summary>{title}</summary>
    <div>{parameters.map(render)}</div>
  </details>;
}

function ParameterRow({ parameter, override, editable, unverifiedLabel, annotation, inputID, defaultLabel, omitLabel, supportLabel, supportDetail, notAdjustableAction, sourceLabel, jsonSchemaLabel, onChange, onClear, onOmit }: {
  parameter: ProfileParameter;
  override?: GenerationParameterOverrides[string];
  editable: boolean;
  /** Render the per-row "unverified" badge whenever set; the test may only come from showsUnverifiedBadge. */
  unverifiedLabel?: string;
  /** Plain-language annotation; only temperature and max tokens have one, the rest pass undefined. */
  annotation?: string;
  inputID: string;
  defaultLabel: string;
  omitLabel: string;
  /** Set only outside the normal case (the silent class); the normal case renders no label at all, Source included. */
  supportLabel?: string;
  /** Per-state secondary copy, from the shared contract's supportMap.detailKey. */
  supportDetail?: string;
  /**
   * Primary action for the "not adjustable" class (shared contract
   * presentationClasses.not_adjustable.primaryAction). One of two shapes: `onClick` when the
   * host can open a model switcher, `listCandidates` when it cannot and a read-only list is
   * expanded in place. Neither being present would leave a dead end and is not allowed.
   */
  notAdjustableAction?: {
    label: string;
    onClick?: () => void;
    listCandidates?: () => readonly string[];
    /** Sentence used when there are no candidates: say plainly that switching models will not help, and do not expand an empty list. */
    emptyLabel?: string;
  };
  sourceLabel: string;
  jsonSchemaLabel: string;
  onChange: (value: GenerationParameterValue) => void;
  onClear: () => void;
  onOmit: () => void;
}) {
  const tc = useTranslations('common');
  const [schemaDraft, setSchemaDraft] = useState(() => override?.state === 'value' && isJSONRecord(override.value)
    ? JSON.stringify(override.value, null, 2) : '');
  const [schemaInvalid, setSchemaInvalid] = useState(false);
  /** null means never expanded, so candidates have not been computed yet; the list is evaluated on expand. */
  const [notAdjustableCandidates, setNotAdjustableCandidates] = useState<readonly string[] | null>(null);
  const id = parameter.id;
  const value = override?.state === 'value' ? override.value : undefined;
  const isBoolean = parameter.valueSchema === 'boolean';
  const stringValue = Array.isArray(value)
    ? value.join(', ')
    : typeof value === 'number' || typeof value === 'string' ? String(value) : '';
  return <div className={styles.row} data-parameter={id}>
    <div className={styles.labelStack}>
      {/* The badge sits outside the label: it is not part of the control's accessible name, and
          folding it in would turn the label into "temperature unverified", so neither screen
          readers nor tests could read a clean parameter name. */}
      <div className={styles.labelRow}>
        <label htmlFor={inputID}>{generationParameterLabel(id, tc)}</label>
        {unverifiedLabel && <em className={styles.unverifiedBadge} data-testid="generation-unverified-badge">{unverifiedLabel}</em>}
      </div>
      {annotation && (
        <span className={styles.parameterAnnotation} data-testid="generation-parameter-annotation">{annotation}</span>
      )}
      {supportLabel && <span data-testid="generation-support-line">{supportLabel} - {sourceLabel}</span>}
      {supportDetail && <span className={styles.supportDetail} data-testid="generation-support-detail">{supportDetail}</span>}
      {/* A greyed-out control must come with a primary action. The button follows the
          explanatory copy instead of joining the disabled control column, where the only way
          out would read as disabled too. */}
      {notAdjustableAction && <button
        type="button"
        className={styles.notAdjustableAction}
        data-testid="generation-not-adjustable-action"
        {...(notAdjustableAction.listCandidates
          ? { 'aria-expanded': notAdjustableCandidates !== null }
          : {})}
        onClick={() => {
          if (notAdjustableAction.onClick) {
            notAdjustableAction.onClick();
            return;
          }
          setNotAdjustableCandidates((current) => (
            current === null ? (notAdjustableAction.listCandidates?.() ?? []) : null
          ));
        }}
      >{notAdjustableAction.label}</button>}
      {notAdjustableCandidates !== null && (
        <span className={styles.notAdjustableCandidates} data-testid="generation-not-adjustable-candidates">
          {notAdjustableCandidates.length > 0
            ? notAdjustableCandidates.join(' - ')
            : notAdjustableAction?.emptyLabel}
        </span>
      )}
    </div>
    <div className={styles.control}>
      {parameter.support === 'fixed' ? (
        <span>{String(parameter.fixedValue ?? defaultLabel)}</span>
      ) : parameter.valueSchema === 'enum' && parameter.enumValues?.length ? (
        <select
          id={inputID}
          value={typeof value === 'string' || typeof value === 'number' ? String(value) : ''}
          disabled={!editable || override?.state === 'omit'}
          onChange={(event) => {
            const match = parameter.enumValues?.find((item) => String(item) === event.target.value);
            if (typeof match === 'string' || typeof match === 'number') onChange(match);
          }}
        >
          <option value="">{defaultLabel}</option>
          {value !== undefined && !parameter.enumValues.some((item) => item === value) && (
            <option value={String(value)}>{String(value)}</option>
          )}
          {parameter.enumValues.map((item) => <option key={String(item)} value={String(item)}>{String(item)}</option>)}
        </select>
      ) : parameter.valueSchema === 'json-schema' ? (
        <textarea
          id={inputID}
          value={schemaDraft}
          aria-invalid={schemaInvalid}
          aria-label={jsonSchemaLabel}
          placeholder={jsonSchemaLabel}
          disabled={!editable || override?.state === 'omit'}
          onChange={(event) => {
            const raw = event.target.value;
            setSchemaDraft(raw);
            if (!raw.trim()) {
              setSchemaInvalid(false);
              onClear();
              return;
            }
            try {
              const parsed: unknown = JSON.parse(raw);
              validateOutputContractValue(parameter.id, parsed as GenerationParameterValue);
              setSchemaInvalid(false);
              onChange(parsed as GenerationParameterValue);
            } catch {
              setSchemaInvalid(true);
            }
          }}
        />
      ) : isBoolean ? (
        <input id={inputID} type="checkbox" checked={value === true} disabled={!editable || override?.state === 'omit'} onChange={(event) => onChange(event.target.checked)} />
      ) : (
        <input
          id={inputID}
          type={parameter.valueSchema === 'integer' || parameter.valueSchema === 'number' ? 'number' : 'text'}
          min={parameter.range?.min}
          max={parameter.range?.max}
          step={parameter.range?.step ?? (parameter.valueSchema === 'integer' ? 1 : 'any')}
          value={stringValue}
          placeholder={override?.state === 'omit' ? omitLabel : defaultLabel}
          disabled={!editable || override?.state === 'omit'}
          onChange={(event) => {
            const raw = event.target.value;
            if (raw === '') return onClear();
            if (parameter.valueSchema === 'integer' || parameter.valueSchema === 'number') {
              const number = Number(raw);
              if (Number.isFinite(number)) onChange(number);
            } else if (parameter.valueSchema === 'string-list') {
              onChange(raw.split(',').map((item) => item.trim()).filter(Boolean));
            } else {
              onChange(raw);
            }
          }}
        />
      )}
      {editable && <button
          type="button"
          className={styles.clear}
          onClick={override?.state === 'omit' ? onClear : onOmit}
          aria-label={override?.state === 'omit' ? defaultLabel : omitLabel}
          title={override?.state === 'omit' ? defaultLabel : omitLabel}
        >{override?.state === 'omit' ? '↩' : '−'}</button>}
      {editable && override?.state === 'value' && <button type="button" className={styles.clear} onClick={onClear} aria-label={defaultLabel} title={defaultLabel}>×</button>}
    </div>
  </div>;
}

/**
 * The value column of the read-only dormant list. Echoed verbatim, never rounded or clipped
 * into a different value: the point of expanding it is to confirm what was originally set.
 */
function dormantValueText(
  override: GenerationParameterOverrides[string] | undefined,
  omitLabel: string,
): string {
  if (!override || override.state === 'inherit') return '';
  if (override.state === 'omit') return omitLabel;
  const value = override.value;
  if (Array.isArray(value)) return value.join(', ');
  return typeof value === 'object' ? JSON.stringify(value) : String(value);
}

function isJSONRecord(value: GenerationParameterValue | undefined): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}
