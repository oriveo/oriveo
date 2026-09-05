'use client';

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Check, ChevronLeft, ChevronRight, Globe, Lock, RefreshCw, Settings2, SlidersHorizontal, Sparkles } from 'lucide-react';
import type { AIModel, Provider } from '@oriveo/shared';
import type { ReasoningIntent } from '@oriveo/core/providers/request-preference/types';
import { GenerationParameterPanel } from '../generation/GenerationParameterPanel';
import { CustomRequestFieldsEditor } from '../generation/CustomRequestFieldsEditor';
import {
  generationParameterProfileFingerprint,
  loadGenerationParameterOverrides,
} from '../../lib/core/chat/generation-parameter-settings';
import { partitionGenerationParameterValues } from '../../lib/core/chat/generation-parameter-lifecycle';
import { capabilityRuntimeIdentity, saveCapabilityPreferences, type CapabilityWebPreference } from '../../lib/core/chat/capability-preference-settings';
import {
  customFragmentOwnerFacts,
  forwardPortCustomFragmentsIfNeeded,
  hasSafeCustomFragmentSchema,
  type CustomFragmentOwner,
} from '../../lib/core/chat/custom-fragment-settings';
import type { CapabilityControlPresentation } from '../../lib/core/chat/capability-control-presentation';
import { resolveWebAvailableIntents } from '../../lib/core/chat/capability-control-presentation';
import {
  modelControlAdvancedSettingsBadgeClassification,
  modelControlBadge,
  modelControlCardBadgeClassification,
  modelControlFooterEntries,
  modelControlReasoningLayout,
  modelControlShowsSupportedModelsAction,
  modelControlStatusIsConfigurable,
  modelControlStatusTextKey,
  modelControlTransportLabel,
  modelControlWebLayout,
  modelControlsCanPersist,
  modelControlsIdentityGapReasonKey,
  modelControlsIdentityRecovery,
  resolveModelControlStatus,
  resolveModelControlsEditability,
  resolveModelControlsIdentityGap,
  MODEL_CONTROL_AUTOMATIC_INTENT,
  type ModelControlEscape,
  type ModelControlFooterEntry,
  type ModelControlIntentOption,
  type ModelControlMessageKey,
  type ModelControlStatus,
} from '../../lib/core/chat/model-control-capability-layout';
import { getCapabilityRuntime, refreshMetadata } from '../../lib/core/metadata/metadata-client';
import { getProviderInstanceDisplayName } from '../../lib/core/providers/provider-display';
import styles from './InputComposer.module.css';

/**
 * Chat model options: the single entry point for web search, reasoning, and advanced settings.
 *
 * The container is a composer popover rather than a modal, but the information architecture is
 * ordered by frequency: web search and reasoning are one step away on the first pane, request
 * parameters move to a second pane, and custom JSON sits one level deeper inside advanced
 * settings.
 *
 * Five structural rules to keep in mind before changing anything here:
 * 1. There is no such thing as a greyed out option in this UI. Available controls render as
 *    controls; unavailable ones degrade to a status line that still responds to a tap and
 *    explains the reason plus a way forward.
 * 2. The control shape follows the semantics. Web search is a binary question, so it is a
 *    switch; reasoning is a scale from "do not think" to "take as long as needed", so it is a
 *    row of pills plus a one-line note for the selected step.
 * 3. Sub-pages switch horizontally inside the same popover and never open another layer. The
 *    user always has a way back.
 * 4. Custom fields do not live in the capability cards. They are a low-frequency developer
 *    feature and belong under advanced settings, but when an owner's custom fields are actually
 *    in effect the card must show that in place and offer a path to them.
 * 5. Copy talks about the user and the model, not about the system: no provider defaults, no
 *    recipes, no transports, no global settings.
 *
 * Every layout decision lives in the pure functions of
 * `lib/core/chat/model-control-capability-layout.ts`: what keeps breaking here is not pixels,
 * it is which options should appear, what to say when one is unavailable, and where a tap leads.
 */

type Pane =
  | { kind: 'main' }
  | { kind: 'advanced' }
  | { kind: 'customFields' }
  | { kind: 'supportedModels'; capability: CustomFragmentOwner };

/**
 * DOM id of the popover container. The composer chip that mounts it points here with
 * `aria-controls`, so a screen reader user can tell what the chip's `aria-expanded` refers to.
 */
export const MODEL_OPTIONS_POPOVER_ID = 'model-options-popover';

/** Parent pane. The back button and Esc on second- and third-level panes both use it. */
function parentPane(pane: Pane): Pane | null {
  switch (pane.kind) {
    case 'main': return null;
    // Custom fields sit behind advanced settings, so one level up is advanced, not the main pane.
    case 'customFields': return { kind: 'advanced' };
    default: return { kind: 'main' };
  }
}

/**
 * Arrow-key delta inside a radiogroup. Under RTL the left and right arrows must follow the
 * reading direction (APG radio group): on a mirrored UI "right" means the previous option.
 */
function radioArrowDelta(key: string, isRTL: boolean): number {
  switch (key) {
    case 'ArrowDown': return 1;
    case 'ArrowUp': return -1;
    case 'ArrowRight': return isRTL ? -1 : 1;
    case 'ArrowLeft': return isRTL ? 1 : -1;
    default: return 0;
  }
}

function isRTLElement(element: Element): boolean {
  return element.closest('[dir]')?.getAttribute('dir') === 'rtl'
    || element.ownerDocument.documentElement.dir === 'rtl';
}

export type ModelOptionsPopoverProps = {
  provider?: Provider;
  model?: AIModel;
  conversationId?: string;
  webControl?: CapabilityControlPresentation;
  reasoningControl?: CapabilityControlPresentation;
  generationControl?: CapabilityControlPresentation;
  webPreference?: CapabilityWebPreference;
  onWebPreferenceChange?: (next: CapabilityWebPreference) => void;
  reasoningIntent?: ReasoningIntent;
  /** `undefined` = "auto" is selected, i.e. no level is injected. */
  onReasoningIntentChange?: (intent: ReasoningIntent | undefined) => void;
  /** Read-only while sending or replaying a conversation: still viewable, but not writable. */
  runtimeIsReadOnly?: boolean;
  runtimeReadOnlyReason?: string;
  /** Full runtime identity. Gates whether writes are allowed, not whether the entry point appears. */
  transportIdentity?: string;
  webRuntimeRejected?: boolean;
  reasoningRuntimeRejected?: boolean;
  /** Models where auto configuration is actually available on this connection, keyed by capability. */
  alternativeModels?: Partial<Record<CustomFragmentOwner, AIModel[]>>;
  onSelectAlternativeModel?: (model: AIModel) => void;
  onOpenModelSwitcher?: () => void;
  /** The only way out when the relay protocol is undetermined: the popover does not route itself, the mount point opens provider details. */
  onOpenConnectionSettings?: () => void;
  onFindModelsSupportingParameter?: (parameterId: string) => void;
  onOverrideChange?: (hasOverride: boolean) => void;
  onClose: () => void;
};

const CAPABILITY_TITLE_KEYS: Record<CustomFragmentOwner, ModelControlMessageKey> = {
  web: 'common.capabilityControlWebSearch',
  reasoning: 'common.capabilityControlThinking',
  generation: 'common.modelBehavior',
};

const UNKNOWN_CONTROL: CapabilityControlPresentation = {
  state: 'unknown', availableIntents: [], viaLegacyProfile: false,
};

export function ModelOptionsPopover({
  provider,
  model,
  conversationId,
  webControl = UNKNOWN_CONTROL,
  reasoningControl = UNKNOWN_CONTROL,
  generationControl = UNKNOWN_CONTROL,
  webPreference = 'off',
  onWebPreferenceChange,
  reasoningIntent,
  onReasoningIntentChange,
  runtimeIsReadOnly = false,
  runtimeReadOnlyReason,
  transportIdentity,
  webRuntimeRejected = false,
  reasoningRuntimeRejected = false,
  alternativeModels,
  onSelectAlternativeModel,
  onOpenModelSwitcher,
  onOpenConnectionSettings,
  onFindModelsSupportingParameter,
  onOverrideChange,
  onClose,
}: ModelOptionsPopoverProps) {
  const tCommon = useTranslations('common');
  const tReasoning = useTranslations('pages.chat.reasoning');
  const tr = useCallback((key: ModelControlMessageKey, values?: Record<string, string | number>) => (
    key.startsWith('common.')
      ? tCommon(key.slice('common.'.length), values)
      : tReasoning(key.slice('pages.chat.reasoning.'.length), values)
  ), [tCommon, tReasoning]);

  const [pane, setPane] = useState<Pane>({ kind: 'main' });
  const containerRef = useRef<HTMLElement>(null);
  const backRef = useRef<HTMLButtonElement>(null);
  /**
   * Opening the popover moves focus into it; switching panes moves focus to the first landing
   * point of the new pane.
   *
   * This layer has no focus trap on purpose (the popover is non-modal, so tabbing out of it is
   * correct), but it must pull focus in: the chip sits after the popover in the DOM, so with
   * focus left alone the next Tab stop is the send button rather than the first control in the
   * panel. A keyboard user would have to Shift+Tab backwards into a panel they just opened, and
   * a screen reader user would not learn that anything appeared at all.
   *
   * The landing point is the container rather than the first focusable element: the container
   * carries `role="dialog"` plus an aria-label, so a screen reader announces the dialog before
   * the first control. Second-level panes land on the back button, which is both their only way
   * out and the first control on that screen.
   */
  useEffect(() => {
    const target = pane.kind === 'main' ? containerRef.current : (backRef.current ?? containerRef.current);
    target?.focus({ preventScroll: true });
  }, [pane.kind]);
  /**
   * Esc backs out one level on second- and third-level panes; only the main pane closes the
   * whole popover. Losing the entire panel, and having to walk two levels back down, is the
   * cost of making one key do two things.
   *
   * The listener runs on document in the capture phase: the listener that closes the popover
   * (InputComposer) is on document in the bubble phase, so capture runs first and the ordering
   * is deterministic regardless of which component mounted first.
   *
   * It uses `stopImmediatePropagation` rather than `stopPropagation`: both listeners sit on the
   * same document node, so when an event targets document itself, plain stopPropagation does
   * not stop the sibling listener and the popover would back out a level and close at once.
   */
  useEffect(() => {
    if (pane.kind === 'main') return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      const parent = parentPane(pane);
      if (!parent) return;
      event.stopImmediatePropagation();
      event.preventDefault();
      setPane(parent);
    };
    document.addEventListener('keydown', handleKeyDown, true);
    return () => document.removeEventListener('keydown', handleKeyDown, true);
  }, [pane]);
  /**
   * Recompute the "N adjusted" count when returning from a sub-pane to the main panel.
   *
   * That number is derived from local storage, while the place that changes it (the parameter
   * table under advanced settings) lives in another pane. Switching panes inside this component
   * does not change provider/model/conversationId, so the useMemo keeps hitting its cache and
   * the row still shows the count from before the user edited anything. A derived value read
   * from storage needs an explicit "back on this pane" signal; a re-render is not a dependency change.
   *
   * The condition is "the previous pane was not main" rather than a plain `pane.kind === 'main'`,
   * which would also fire once on mount for nothing.
   */
  const [behaviorRevision, setBehaviorRevision] = useState(0);
  const previousPaneKind = useRef(pane.kind);
  useEffect(() => {
    if (previousPaneKind.current !== 'main' && pane.kind === 'main') {
      setBehaviorRevision((revision) => revision + 1);
    }
    previousPaneKind.current = pane.kind;
  }, [pane.kind]);
  /**
   * The scope upgrade row appears only after a change, never as an up-front declaration.
   *
   * "These settings apply to this conversation only" in the header is a rule the user has to
   * understand before doing anything; saying "applied to this conversation, set as this model
   * default" right after a switch is flipped is the first moment scope becomes relevant to them.
   * Once it has appeared while the panel is open it stays until close, without nagging
   * persistently.
   */
  const [showsScopeUpgrade, setShowsScopeUpgrade] = useState(false);
  const [scopeUpgradeConfirmed, setScopeUpgradeConfirmed] = useState(false);
  /** Explanation shown when an unavailable status row is opened. Every unavailable state must be
   * able to produce one, otherwise the row is a control that looks like a button and does nothing. */
  const [explainedCapability, setExplainedCapability] = useState<CustomFragmentOwner | null>(null);
  const [isRefreshingRuntime, setIsRefreshingRuntime] = useState(false);
  const [runtimeRefreshFailed, setRuntimeRefreshFailed] = useState(false);

  const editability = resolveModelControlsEditability({
    ...(provider ? { providerKind: provider.kind } : {}),
    ...(transportIdentity ? { transportIdentity } : {}),
    runtimeIsReadOnly,
  });
  const canPersist = modelControlsCanPersist(editability);

  const identityGap = resolveModelControlsIdentityGap({
    ...(provider ? { providerKind: provider.kind } : {}),
    relayTransportIsDecided: Boolean(
      provider?.relayResolvedTransport?.trim()
      || (provider?.relayRequested?.transport && provider.relayRequested.transport !== 'auto'),
    ),
    runtimeIsReady: getCapabilityRuntime() != null,
  });

  const readOnlyReason = useMemo(() => {
    switch (editability) {
      case 'managedFree': case 'managedBalance': return tCommon('capabilityControlManagedViewOnly');
      case 'runtimeIdentityUnavailable': return tr(modelControlsIdentityGapReasonKey(identityGap));
      case 'runtimeReadOnly': return runtimeReadOnlyReason ?? tCommon('capabilityControlNotReadyReason');
      case 'writable': return undefined;
    }
  }, [editability, identityGap, runtimeReadOnlyReason, tCommon, tr]);

  /**
   * Whether this connection has any editable custom-field schema for the current transport (any
   * owner counts). The way out of `customOnly` depends on it; see `hasCustomSchema` in layout.
   */
  const hasCustomSchema = useMemo(() => (
    provider && model && transportIdentity
      ? hasSafeCustomFragmentSchema(provider, model, transportIdentity)
      : false
  ), [model, provider, transportIdentity]);

  const ownerFacts = useCallback((owner: CustomFragmentOwner) => (
    provider && model && transportIdentity
      ? customFragmentOwnerFacts({ provider, model, transportIdentity, owner })
      : { hasSchema: false, riskTiers: [] as string[], isActive: false }
  ), [model, provider, transportIdentity]);

  const webStatus = resolveModelControlStatus(webControl);
  const reasoningStatus = resolveModelControlStatus(reasoningControl);
  const generationStatus = resolveModelControlStatus(generationControl);

  /**
   * Available web-search levels. The decision lives in the registry surface
   * `capability-control-presentation.ts`; only a small subset of models expose a `force` level,
   * and web search and reasoning resolve their levels asymmetrically on purpose.
   */
  const webIntents = resolveWebAvailableIntents(webControl);
  const reasoningIntents = reasoningControl.availableIntents;

  const webFacts = ownerFacts('web');
  const reasoningFacts = ownerFacts('reasoning');
  const generationFacts = ownerFacts('generation');

  const webLayout = modelControlWebLayout({
    status: webStatus,
    availableIntents: webIntents,
    selection: webPreference,
    isEditable: canPersist && !webFacts.isActive,
    hasCustomSchema,
  });
  const reasoningLayout = modelControlReasoningLayout({
    status: reasoningStatus,
    intents: reasoningIntents,
    ...(reasoningIntent ? { selectedIntent: reasoningIntent } : {}),
    isEditable: canPersist && !reasoningFacts.isActive,
    hasCustomSchema,
  });

  /*
   * A stored `force` level that is absent from the current recipe is *displayed* as automatic
   * (the clamp inside `webLayout.effectiveSelection` / `modelControlWebLayout`), but opening the
   * panel writes nothing: the clamp belongs to the user-initiated `persist()` path, while
   * `restore()` does not write a single byte.
   *
   * Do not add an effect that writes the clamped value back on open. It funnels a purely
   * maintenance correction into `onWebPreferenceChange`, which also carries the mutually
   * exclusive side effect of clearing attached library documents and demotes an inherited
   * connection-level value into a conversation record. Merely opening the panel would then drop
   * the attached documents and freeze the model default onto this conversation.
   *
   * The narrowing write-back is folded into the user's next deliberate change instead:
   * `handleWebPreferenceChange` writes the legal level for the current layout, and
   * `promoteSelectionToModelDefault` writes `effectiveSelection`.
   */

  /**
   * Full runtime identity. The upgrade row writes to a scope beyond `conversationId`, and a
   * `transportIdentity` string alone is not enough to build the recordId.
   */
  const runtimeIdentity = useMemo(
    () => (provider && model ? capabilityRuntimeIdentity(provider, model) : null),
    [model, provider],
  );

  /**
   * Opening the panel and switching models are discrete events, so local custom fields run their
   * lazy forward migration here. Typed preferences migrate through their own read paths
   * (`displayCapabilityPreferences` and the send path), so they are not repeated here.
   * This must not run during render: it parses a metadata snapshot and may write to storage.
   */
  useEffect(() => {
    if (!provider || !model || !transportIdentity) return;
    forwardPortCustomFragmentsIfNeeded({ provider, model, transportIdentity });
  }, [model, provider, transportIdentity]);

  /**
   * A preference change that really persists. The confirmation state is reset every time: the
   * sentence "new conversations will use these settings by default" endorses the previous upgrade,
   * and leaving it up after a fresh change turns it into a lie.
   */
  const notePersistedChange = useCallback(() => {
    setScopeUpgradeConfirmed(false);
    if (!conversationId || !canPersist || !transportIdentity) return;
    setShowsScopeUpgrade(true);
  }, [canPersist, conversationId, transportIdentity]);

  const handleWebPreferenceChange = useCallback((next: CapabilityWebPreference) => {
    onWebPreferenceChange?.(next);
    notePersistedChange();
  }, [notePersistedChange, onWebPreferenceChange]);

  const handleReasoningIntentChange = useCallback((intent: ReasoningIntent | undefined) => {
    onReasoningIntentChange?.(intent);
    notePersistedChange();
  }, [notePersistedChange, onReasoningIntentChange]);

  /**
   * "Set as this model's default" writes the two current values into the `connection_model`
   * scope. The conversation layer stays where it is and still takes priority, so this
   * conversation behaves exactly as before.
   *
   * The write guard is the same one `persist` uses: writable plus a complete identity. The row
   * is not rendered at all for managed connections or a missing identity; this is the second
   * gate, because the callback is async and the model may have changed in between.
   */
  const promoteSelectionToModelDefault = useCallback(() => {
    if (!canPersist || !runtimeIdentity) return;
    saveCapabilityPreferences(
      { ...runtimeIdentity, scope: 'connection_model' },
      {
        web: webLayout.effectiveSelection,
        ...(reasoningIntent ? { reasoningIntent } : {}),
      },
    );
    setScopeUpgradeConfirmed(true);
  }, [canPersist, reasoningIntent, runtimeIdentity, webLayout.effectiveSelection]);

  /**
   * The confirmation sentence fades out with its row after 3 seconds. It is inline state rather
   * than a toast: toasts render at page level and this popover covers them, so the user would
   * never see the only receipt for the button they just pressed.
   */
  useEffect(() => {
    if (!scopeUpgradeConfirmed) return;
    const timer = window.setTimeout(() => {
      setScopeUpgradeConfirmed(false);
      setShowsScopeUpgrade(false);
    }, 3000);
    return () => window.clearTimeout(timer);
  }, [scopeUpgradeConfirmed]);

  const candidates = useCallback(
    (capability: CustomFragmentOwner) => alternativeModels?.[capability] ?? [],
    [alternativeModels],
  );

  /** "N adjusted" counts conversation overrides union model defaults (conversation wins on ties, dormant excluded), the same source as the chip dot. */
  const activeOverrideCount = useMemo(() => {
    if (!provider || !model) return 0;
    const profileFingerprint = generationParameterProfileFingerprint(provider, model);
    const values = {
      ...(loadGenerationParameterOverrides({ providerId: provider.id, modelId: model.id, profileFingerprint }) ?? {}),
      ...(conversationId
        ? loadGenerationParameterOverrides({ providerId: provider.id, modelId: model.id, conversationId, profileFingerprint }) ?? {}
        : {}),
    };
    if (Object.keys(values).length === 0) return 0;
    const active = partitionGenerationParameterValues({ provider, model, values }).active;
    return Object.values(active ?? {}).filter((item) => item?.state !== 'inherit').length;
  }, [behaviorRevision, conversationId, model, provider]);

  const refetchRuntime = useCallback(async () => {
    setIsRefreshingRuntime(true);
    setRuntimeRefreshFailed(false);
    await refreshMetadata();
    setIsRefreshingRuntime(false);
    // Still nothing after refetching means a real failure, and it has to be stated. Saying nothing
    // leaves the user unable to tell whether the button did nothing or they pressed the wrong one.
    setRuntimeRefreshFailed(!(provider && model && capabilityRuntimeIdentity(provider, model)));
  }, [model, provider]);

  // -- Render helpers --

  /**
   * The two projections must not be mixed: capability cards collapse `unavailable` (the status
   * line already says it in full), while advanced-settings rows collapse `notReady` (request
   * parameter editing does not read the recipe, so that badge would be false). Both decisions
   * live in pure functions in layout; this only dispatches.
   */
  const renderBadge = (
    status: ModelControlStatus,
    overridden: boolean,
    surface: 'capabilityCard' | 'advancedSettings',
  ) => {
    const badge = modelControlBadge(
      surface === 'capabilityCard'
        ? modelControlCardBadgeClassification(status)
        : modelControlAdvancedSettingsBadgeClassification(status),
      overridden,
    );
    if (!badge) return null;
    return <span className={styles.modelControlBadge} data-tone={badge.tone}>{tr(badge.textKey)}</span>;
  };

  /**
   * The replacement row shown when a capability is unavailable. With no explanation to give it
   * does not build a button: a control that does nothing when tapped is as bad as a greyed out
   * option.
   */
  const renderStatusRow = (
    capability: CustomFragmentOwner,
    textKey: ModelControlMessageKey,
    explanationKey: ModelControlMessageKey | undefined,
    escape: ModelControlEscape,
  ) => {
    const expanded = explainedCapability === capability;
    // "No candidate models" has to be appended here: it depends on the model list of the whole
    // connection, a fact the pure layout function cannot reach. Without it, tapping "see supported
    // models" leads into an empty list.
    const noCandidates = escape === 'supportedModels' && candidates(capability).length === 0;
    const resolvedEscape: ModelControlEscape = noCandidates ? 'none' : escape;
    /**
     * The explanation and the status line for `customOnly` are the same sentence (layout keeps
     * them in one place on purpose). Repeating it inside the disclosure hands the user the line
     * they just read, so the tap pays back nothing and the UI looks stuck. On a matching key the
     * disclosure renders only the way out.
     */
    const explanationRepeatsStatus = explanationKey === textKey;
    const hasExpandedContent = Boolean(explanationKey)
      && (!explanationRepeatsStatus || noCandidates || resolvedEscape !== 'none');
    // With neither an explanation nor a way out, do not build a button: a control that does
    // nothing when tapped is as bad as a greyed out option.
    if (!hasExpandedContent) {
      return <p className={styles.modelControlStatusRow}>{tr(textKey)}</p>;
    }
    return (
      <>
        <button
          type="button"
          className={styles.modelControlStatusRow}
          data-interactive="true"
          aria-expanded={expanded}
          onClick={() => setExplainedCapability(expanded ? null : capability)}
        >
          <span>{tr(textKey)}</span>
          <ChevronRight size={14} aria-hidden="true" className={styles.modelControlForwardChevron} />
        </button>
        {expanded && (
          <div className={styles.modelControlExplanation}>
            {!explanationRepeatsStatus && <p>{tr(explanationKey!)}</p>}
            {noCandidates && <p>{tCommon('capabilityControlNoSupportedModels')}</p>}
            {resolvedEscape === 'supportedModels' && (
              <button
                type="button"
                className={styles.modelControlInlineAction}
                onClick={() => setPane({ kind: 'supportedModels', capability })}
              >
                {tCommon('capabilityControlViewSupportedModels')}
              </button>
            )}
            {resolvedEscape === 'advancedSettings' && (
              <button
                type="button"
                className={styles.modelControlInlineAction}
                onClick={() => setPane({ kind: 'advanced' })}
              >
                {tCommon('capabilityControlGoToAdvancedSettings')}
              </button>
            )}
          </div>
        )}
      </>
    );
  };

  /**
   * With no entries at all the whole group is skipped: rendering a zero-height container gives
   * the card an extra bottom margin out of nowhere.
   */
  const renderFooterEntries = (entries: ModelControlFooterEntry[], capability: CustomFragmentOwner) => {
    if (entries.length === 0) return null;
    return (
      <div className={styles.modelControlNotes}>
        {entries.map((entry, index) => {
          if (entry.kind === 'supportedModelsLink') {
            return (
              <button
                key={`supported-${index}`}
                type="button"
                className={styles.modelControlInlineAction}
                onClick={() => setPane({ kind: 'supportedModels', capability })}
              >
                {tCommon('capabilityControlViewSupportedModels')}
              </button>
            );
          }
          if (entry.kind === 'advancedSettingsLink') {
            return (
              <button
                key={`advanced-${index}`}
                type="button"
                className={styles.modelControlInlineAction}
                onClick={() => setPane({ kind: 'advanced' })}
              >
                {tCommon('capabilityControlGoToAdvancedSettings')}
              </button>
            );
          }
          return (
            <p key={`note-${index}`} className={styles.modelControlNote} data-tone={entry.tone}>
              {entry.text ?? (entry.textKey ? tr(entry.textKey) : '')}
            </p>
          );
        })}
      </div>
    );
  };

  const footerEntriesFor = (input: {
    status: ModelControlStatus;
    capability: CustomFragmentOwner;
    overridden: boolean;
    riskTiers: readonly string[];
    upstreamRejected: boolean;
    statusRowEscape: ModelControlEscape;
  }) => {
    const showsSupportedModels = modelControlShowsSupportedModelsAction(input.status);
    return modelControlFooterEntries({
      context: 'panelCard',
      overridden: input.overridden,
      ...(readOnlyReason ? { readOnlyReason } : {}),
      isConfigurable: modelControlStatusIsConfigurable(input.status),
      statusTextKey: modelControlStatusTextKey(input.status),
      upstreamRejected: input.upstreamRejected,
      riskTiers: input.riskTiers,
      showsSupportedModelsAction: showsSupportedModels,
      hasSupportedModelCandidates: showsSupportedModels && candidates(input.capability).length > 0,
      showsAdvancedSettingsAction: input.overridden,
      statusRowEscape: input.statusRowEscape,
    });
  };

  // -- Pane content --

  const subtitle = useMemo(() => {
    if (!provider) return '';
    const parts = [getProviderInstanceDisplayName(provider)];
    const transport = model ? capabilityRuntimeIdentity(provider, model)?.finalTransport : undefined;
    if (transport) parts.push(modelControlTransportLabel(transport) ?? tCommon('capabilityControlProtocol'));
    return parts.join(' - ');
  }, [model, provider, tCommon]);

  const missingModelPanel = (
    <>
      <header className={styles.modelControlsHeader}>
        <strong className={styles.modelControlsTitle}>
          {provider ? getProviderInstanceDisplayName(provider) : tCommon('modelControls')}
        </strong>
      </header>
      <div className={styles.modelControlSections}>
        <div className={styles.modelControlBanner}>
          {/*
            This wording is deliberately different from `capabilityPreferencesUnavailable`
            ("connection, model and request route must be ready before saving"). That one is
            about writes being blocked; here no model has been picked yet, and the ask is to
            pick one. Save-state wording would send the user off to inspect a request route that
            has never been established.
          */}
          <p className={styles.modelControlNote} data-tone="tertiary">
            <Lock size={13} aria-hidden="true" />
            {tCommon('capabilityControlMissingModelReadOnly')}
          </p>
          {onOpenModelSwitcher && (
            <button type="button" className={styles.modelControlInlineAction} onClick={onOpenModelSwitcher}>
              {tCommon('capabilityControlChooseAnotherModel')}
            </button>
          )}
        </div>
        <ul className={styles.modelControlPlaceholderList}>
          {(['web', 'reasoning', 'generation'] as const).map((capability) => (
            <li key={capability} className={styles.modelControlPlaceholderRow}>
              <span>{tr(CAPABILITY_TITLE_KEYS[capability])}</span>
              <span className={styles.modelControlPlaceholderState}>{tReasoning('notReady')}</span>
            </li>
          ))}
        </ul>
      </div>
    </>
  );

  const webCard = (
    <section className={styles.modelControlCard} aria-label={tCommon('capabilityControlWebSearch')}>
      <div className={styles.modelControlCardHeader}>
        <Globe size={15} aria-hidden="true" className={styles.modelControlCardIcon} data-accent="web" />
        <span className={styles.modelControlCardTitle}>{tCommon('capabilityControlWebSearch')}</span>
        {/* Switch and badge are mutually exclusive and the switch wins: the card title is already the label for the switch, and a second line would say "web search" twice. */}
        {webLayout.form === 'toggle' ? (
          // The native input covers the whole 44px hit area, keeping keyboard, screen reader and
          // checked semantics; the span after it only unifies the look across browsers. The label
          // carries no text, so the accessible name still comes from the input and the header does
          // not announce "web search" twice.
          <label className={styles.modelControlSwitchHit}>
            <input
              type="checkbox"
              role="switch"
              className={styles.modelControlSwitch}
              aria-label={tCommon('capabilityControlWebSearch')}
              checked={webLayout.isOn}
              onChange={(event) => {
                // Off maps to `off`; on returns to "search when needed". Switching to "search on
                // every message" is the job of the two pills below; the switch carries no strength.
                handleWebPreferenceChange(event.target.checked ? 'automatic' : 'off');
              }}
            />
            <span className={styles.modelControlSwitchTrack} aria-hidden="true">
              <span className={styles.modelControlSwitchThumb}>
                <Check className={styles.modelControlSwitchCheck} strokeWidth={3} />
              </span>
            </span>
          </label>
        ) : renderBadge(webStatus, webFacts.isActive, 'capabilityCard')}
      </div>
      {webLayout.form === 'toggle' ? (
        <>
          {webLayout.captionKey && (
            <p className={styles.modelControlNote} data-tone="tertiary">{tr(webLayout.captionKey)}</p>
          )}
          {webLayout.timingOptions.length > 0 && (
            <ModelControlRadioGroup
              label={tCommon('capabilityControlSearchTiming')}
              options={webLayout.timingOptions}
              selection={webLayout.timingSelection}
              translate={tr}
              onSelect={(id) => handleWebPreferenceChange(id as CapabilityWebPreference)}
            />
          )}
        </>
      ) : renderStatusRow('web', webLayout.statusTextKey!, webLayout.explanationKey, webLayout.escape)}
      {renderFooterEntries(footerEntriesFor({
        status: webStatus,
        capability: 'web',
        overridden: webFacts.isActive,
        riskTiers: webFacts.riskTiers,
        upstreamRejected: webRuntimeRejected,
        statusRowEscape: webLayout.form === 'statusRow' ? webLayout.escape : 'none',
      }), 'web')}
    </section>
  );

  const reasoningCard = (
    <section className={styles.modelControlCard} aria-label={tCommon('capabilityControlThinking')}>
      <div className={styles.modelControlCardHeader}>
        <Sparkles size={15} aria-hidden="true" className={styles.modelControlCardIcon} data-accent="reasoning" />
        <span className={styles.modelControlCardTitle}>{tCommon('capabilityControlThinking')}</span>
        {renderBadge(reasoningStatus, reasoningFacts.isActive, 'capabilityCard')}
      </div>
      {reasoningLayout.form === 'pillRow' ? (
        <>
          <ModelControlRadioGroup
            label={tCommon('capabilityControlThinking')}
            options={reasoningLayout.options}
            selection={reasoningLayout.selection}
            translate={tr}
            onSelect={(id) => handleReasoningIntentChange(
              // "Automatic" is a pseudo intent: choosing it injects no level, so it has to persist as empty.
              id === MODEL_CONTROL_AUTOMATIC_INTENT ? undefined : id as ReasoningIntent,
            )}
          />
          {/* The annotation follows the selected step. A pill only fits one noun, so this line carries whatever separates the steps. */}
          {reasoningLayout.selectedAnnotationKey && (
            <p className={styles.modelControlNote} data-tone="tertiary">
              {tr(reasoningLayout.selectedAnnotationKey)}
            </p>
          )}
        </>
      ) : renderStatusRow(
        'reasoning', reasoningLayout.statusTextKey!, reasoningLayout.explanationKey, reasoningLayout.escape,
      )}
      {reasoningLayout.footnoteKey && (
        <p className={styles.modelControlNote} data-tone="tertiary">{tr(reasoningLayout.footnoteKey)}</p>
      )}
      {renderFooterEntries(footerEntriesFor({
        status: reasoningStatus,
        capability: 'reasoning',
        overridden: reasoningFacts.isActive,
        riskTiers: reasoningFacts.riskTiers,
        upstreamRejected: reasoningRuntimeRejected,
        statusRowEscape: reasoningLayout.form === 'statusRow' ? reasoningLayout.escape : 'none',
      }), 'reasoning')}
    </section>
  );

  /**
   * Advanced settings is the only entry that keeps a second pane: behind it is a variable-length
   * parameter table that would swamp the other two if expanded in place. The subtitle turns the
   * row from an arrow pointing nowhere in particular into an entry the user can predict. The
   * trailing text says only how many items are adjusted; read-only reasons belong to the banner
   * at the top of the panel.
   */
  const advancedRow = (
    <button
      type="button"
      className={styles.modelControlNavigationRow}
      onClick={() => setPane({ kind: 'advanced' })}
    >
      <SlidersHorizontal size={15} aria-hidden="true" className={styles.modelControlCardIcon} data-accent="generation" />
      <span className={styles.modelControlNavigationCopy}>
        <span className={styles.modelControlCardTitle}>{tCommon('modelBehavior')}</span>
        <span className={styles.modelControlNavigationSubtitle}>
          {tCommon('capabilityControlAdvancedSettingsSubtitle')}
        </span>
      </span>
      {activeOverrideCount > 0 && (
        <span className={styles.modelControlNavigationTrailing}>
          {tCommon('capabilityControlAdjustedCount', { count: activeOverrideCount })}
        </span>
      )}
      {renderBadge(generationStatus, generationFacts.isActive, 'advancedSettings')}
      <ChevronRight size={14} aria-hidden="true" className={styles.modelControlForwardChevron} />
    </button>
  );

  /** Each read-only reason gets the action that can actually resolve it. All three have to pass the question "does tapping this really change the state". */
  const identityRecoveryAction = () => {
    switch (modelControlsIdentityRecovery(identityGap)) {
      case 'refetchRuntime':
        return (
          <>
            <button
              type="button"
              className={styles.modelControlInlineAction}
              disabled={isRefreshingRuntime}
              onClick={() => { void refetchRuntime(); }}
            >
              <RefreshCw size={13} aria-hidden="true" />
              {tCommon(isRefreshingRuntime ? 'capabilityControlFetching' : 'capabilityControlFetchAgain')}
            </button>
            {runtimeRefreshFailed && (
              <p className={styles.modelControlNote} data-tone="tertiary">
                {tCommon('capabilityControlFetchFailed')}
              </p>
            )}
          </>
        );
      case 'openConnectionSettings':
        // The protocol really is configured in the connection settings, which is the case this "check the connection" entry exists for.
        return onOpenConnectionSettings ? (
          <button type="button" className={styles.modelControlInlineAction} onClick={onOpenConnectionSettings}>
            <Settings2 size={13} aria-hidden="true" />
            {tCommon('capabilityControlSetProtocol')}
          </button>
        ) : null;
      case 'chooseAnotherModel':
        return onOpenModelSwitcher ? (
          <button type="button" className={styles.modelControlInlineAction} onClick={onOpenModelSwitcher}>
            {tCommon('capabilityControlChooseAnotherModel')}
          </button>
        ) : null;
    }
  };

  /**
   * Read-only banner: one sentence of reason plus the action that resolves that reason.
   *
   * It has to render on the main pane and on the advanced settings pane. With it on the main
   * pane only, a user pushed into advanced settings under `runtimeReadOnly` or
   * `runtimeIdentityUnavailable` would face a page of dimmed parameters with no explanation and
   * no way out, unable to tell whether a send is in flight or the identity is not ready. Both
   * places share one component, so the wording and the action cannot drift apart.
   */
  const readOnlyBanner = readOnlyReason ? (
    <div className={styles.modelControlBanner} data-testid="model-control-read-only-banner">
      <p className={styles.modelControlNote} data-tone="tertiary">
        <Lock size={13} aria-hidden="true" />
        {readOnlyReason}
      </p>
      {(editability === 'managedFree' || editability === 'managedBalance') && onOpenModelSwitcher && (
        <button type="button" className={styles.modelControlInlineAction} onClick={onOpenModelSwitcher}>
          {tCommon('capabilityControlChooseAnotherModel')}
        </button>
      )}
      {editability === 'runtimeIdentityUnavailable' && identityRecoveryAction()}
    </div>
  ) : null;

  const mainPane = (
    <>
      <header className={styles.modelControlsHeader}>
        {/* The title is the model name: the user opened this page to change settings for this
            model, and repeating "model options" spends the most informative line on a category. */}
        <strong className={styles.modelControlsTitle}>{model?.name}</strong>
        {subtitle && <span className={styles.modelControlsSubtitle}>{subtitle}</span>}
      </header>
      <div className={styles.modelControlSections}>
        {readOnlyBanner}
        {webCard}
        {reasoningCard}
        {advancedRow}
      </div>
    </>
  );

  const advancedPane = (
    <>
      <header className={styles.modelControlsHeader} data-secondary="true">
        <button
          ref={backRef}
          type="button"
          className={styles.modelControlsBack}
          aria-label={tCommon('back')}
          onClick={() => setPane({ kind: 'main' })}
        >
          <ChevronLeft size={16} aria-hidden="true" />
        </button>
        <strong className={styles.modelControlsTitle}>{tCommon('modelBehavior')}</strong>
      </header>
      <div className={styles.modelControlSections}>
        {readOnlyBanner}
        {provider && model && conversationId ? (
          <GenerationParameterPanel
            provider={provider}
            model={model}
            conversationId={conversationId}
            scope="session"
            // The popover already has its own title bar, so the panel does not print "advanced settings" a second time.
            hidesTitle
            // The outer `.modelControlSections` is already the only scroll container on this screen;
            // a second max-height plus overflow inside the panel gives two nested scrollers that do
            // not know about each other, and the screen locks up at the inner boundary.
            embedded
            // Read-only is passed through. A managed connection or an in-flight send only means "not editable right now"; the page structure stays complete.
            isReadOnly={!canPersist}
            onOpenCustomFields={() => setPane({ kind: 'customFields' })}
            // After a model switch this screen describes a different model, so it closes on selection, like the candidate list.
            {...(onSelectAlternativeModel
              ? { onSelectCustomFieldsModel: (next: AIModel) => { onSelectAlternativeModel(next); onClose(); } }
              : {})}
            {...(onOverrideChange ? { onOverrideChange } : {})}
            {...(onFindModelsSupportingParameter ? { onFindSupportedModels: onFindModelsSupportingParameter } : {})}
          />
        ) : (
          <p className={styles.modelControlNote} data-tone="tertiary">
            {tCommon('capabilityPreferencesUnavailable')}
          </p>
        )}
      </div>
    </>
  );

  /**
   * Third level: custom request fields. A low-frequency developer feature, so it sits behind
   * advanced settings; depth follows frequency. Back returns to advanced settings rather than
   * the main panel, because that is where the user came from.
   */
  const customFieldsPane = (
    <>
      <header className={styles.modelControlsHeader} data-secondary="true">
        <button
          ref={backRef}
          type="button"
          className={styles.modelControlsBack}
          aria-label={tCommon('back')}
          onClick={() => setPane({ kind: 'advanced' })}
        >
          <ChevronLeft size={16} aria-hidden="true" />
        </button>
        <strong className={styles.modelControlsTitle}>{tCommon('customRequestFieldsCustom')}</strong>
      </header>
      <div className={styles.modelControlSections}>
        {provider && model ? (
          <CustomRequestFieldsEditor
            provider={provider}
            model={model}
            {...(conversationId ? { conversationId } : {})}
          />
        ) : (
          <p className={styles.modelControlNote} data-tone="tertiary">
            {tCommon('capabilityPreferencesUnavailable')}
          </p>
        )}
      </div>
    </>
  );

  const supportedModelsPane = (capability: CustomFragmentOwner) => (
    <>
      <header className={styles.modelControlsHeader} data-secondary="true">
        <button
          ref={backRef}
          type="button"
          className={styles.modelControlsBack}
          aria-label={tCommon('back')}
          onClick={() => setPane({ kind: 'main' })}
        >
          <ChevronLeft size={16} aria-hidden="true" />
        </button>
        <strong className={styles.modelControlsTitle}>{tr(CAPABILITY_TITLE_KEYS[capability])}</strong>
      </header>
      <div className={styles.modelControlSections}>
        <p className={styles.modelControlNote} data-tone="tertiary">
          {tCommon('capabilityControlSupportedModelsIntro')}
        </p>
        {candidates(capability).length === 0 ? (
          <p className={styles.modelControlNote} data-tone="tertiary">
            {tCommon('capabilityControlNoSupportedModels')}
          </p>
        ) : (
          <ul className={styles.modelControlCandidateList}>
            {candidates(capability).map((candidate) => (
              <li key={candidate.id}>
                <button
                  type="button"
                  className={styles.modelControlCandidateRow}
                  onClick={() => { onSelectAlternativeModel?.(candidate); onClose(); }}
                >
                  <span className={styles.modelControlCandidateName}>{candidate.name}</span>
                  <span className={styles.modelControlCandidateAction}>
                    {tCommon('capabilityControlSwitchToModel')}
                  </span>
                  <ChevronRight size={14} aria-hidden="true" className={styles.modelControlForwardChevron} />
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </>
  );

  return (
    /*
     * `role="dialog"` rather than a bare `<section>`: the entry chip points here with
     * `aria-expanded` and `aria-controls`, so a screen reader has to be able to answer "what is
     * this expanded region". No `aria-modal` and no focus trap - this is a non-modal popover and
     * tabbing out to the other composer controls is the correct behavior; trapping focus strands
     * the user in a panel that has no confirm or cancel button.
     *
     * `tabIndex={-1}`: the container stays out of the Tab ring and only serves as the landing
     * point when focus is moved in on open.
     */
    <section
      ref={containerRef}
      id={MODEL_OPTIONS_POPOVER_ID}
      role="dialog"
      tabIndex={-1}
      className={styles.modelControlsPopover}
      aria-label={tCommon('modelControls')}
    >
      {!model ? missingModelPanel
        : pane.kind === 'advanced' ? advancedPane
        : pane.kind === 'customFields' ? customFieldsPane
        : pane.kind === 'supportedModels' ? supportedModelsPane(pane.capability)
        : mainPane}
      {/*
        Fixed bottom area. The scope upgrade row is pinned directly above the close bar and forms
        one block with it: it is immediate feedback for what was just changed and has to be
        visible unconditionally, which the scrolling area above cannot guarantee.

        Main pane only: after pushing into advanced settings the row would still describe the
        previous screen. It reappears unchanged on the way back.
      */}
      <footer className={styles.modelControlsFooter}>
        {showsScopeUpgrade && pane.kind === 'main' && (
          <div className={styles.modelControlScopeUpgrade} data-testid="model-control-scope-upgrade">
            {scopeUpgradeConfirmed ? (
              <p className={styles.modelControlScopeUpgradeConfirmed}>
                <Check size={13} aria-hidden="true" />
                {tCommon('capabilityControlScopeDefaultConfirmed')}
              </p>
            ) : (
              <>
                <span className={styles.modelControlScopeUpgradeNote}>
                  {tCommon('capabilityControlScopeAppliedToConversation')}
                </span>
                <button
                  type="button"
                  className={styles.modelControlScopeUpgradeAction}
                  onClick={promoteSelectionToModelDefault}
                >
                  {tCommon('capabilityControlScopeSetAsModelDefault')}
                </button>
              </>
            )}
          </div>
        )}
        <div className={styles.modelControlsCloseBar}>
          <button type="button" onClick={onClose}>{tCommon('close')}</button>
        </div>
      </footer>
    </section>
  );
}

/**
 * The mutually exclusive pill group shared by "when to search" and "reasoning level"
 * (APG radio group).
 *
 * `role="radiogroup"` is a promise: a screen reader tells the user this is a single-choice group
 * driven by the arrow keys. Both halves have to hold, or the role is lying:
 * - roving tabindex: the group takes a single stop in the Tab ring, landing on the selected pill;
 * - arrow keys move focus and change the selection (radio group behavior, not the tablist "move
 *   focus only" rule), with Home/End jumping to either end.
 *
 * Under RTL the left and right arrows follow the reading direction; see `radioArrowDelta`.
 */
function ModelControlRadioGroup({ label, options, selection, translate, onSelect }: {
  label: string;
  options: readonly ModelControlIntentOption[];
  /** The currently selected id. Layout guarantees it is one of `options` (stale levels are clamped). */
  selection: string;
  translate: (key: ModelControlMessageKey) => string;
  onSelect: (id: string) => void;
}) {
  const groupRef = useRef<HTMLDivElement>(null);
  const selectedIndex = Math.max(0, options.findIndex((option) => option.id === selection));

  const handleKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const container = groupRef.current;
    if (!container) return;
    const delta = radioArrowDelta(event.key, isRTLElement(container));
    const isEdgeKey = event.key === 'Home' || event.key === 'End';
    if (delta === 0 && !isEdgeKey) return;
    // Arrow keys would otherwise scroll `.modelControlSections`; this group claims them as selection actions.
    event.preventDefault();
    const nextIndex = event.key === 'Home' ? 0
      : event.key === 'End' ? options.length - 1
      : (selectedIndex + delta + options.length) % options.length;
    const next = options[nextIndex];
    if (!next) return;
    container.querySelectorAll<HTMLButtonElement>('[role="radio"]')[nextIndex]?.focus();
    onSelect(next.id);
  };

  return (
    <div
      ref={groupRef}
      className={styles.modelControlPills}
      role="radiogroup"
      aria-label={label}
      onKeyDown={handleKeyDown}
    >
      {options.map((option, index) => (
        <button
          key={option.id}
          type="button"
          role="radio"
          aria-checked={selection === option.id}
          aria-label={translate(option.labelKey)}
          tabIndex={index === selectedIndex ? 0 : -1}
          className={styles.modelControlPill}
          data-active={selection === option.id}
          onClick={() => onSelect(option.id)}
        >
          {translate(option.labelKey)}
        </button>
      ))}
    </div>
  );
}
