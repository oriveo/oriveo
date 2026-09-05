import { describe, expect, it } from 'vitest';
import {
  clampModelControlWebPreference,
  modelControlBadge,
  modelControlAdvancedSettingsBadgeClassification,
  modelControlBadgeClassification,
  modelControlCardBadgeClassification,
  modelControlFooterEntries,
  modelControlReasoningLayout,
  modelControlShowsSupportedModelsAction,
  modelControlStatusIsConfigurable,
  modelControlTransportLabel,
  modelControlWebLayout,
  modelControlWebReachesTheWire,
  modelControlsIdentityRecovery,
  resolveModelControlStatus,
  resolveModelControlsEditability,
  resolveModelControlsIdentityGap,
  MODEL_CONTROL_REASONING_TIER_ORDER,
  type ModelControlStatus,
} from './model-control-capability-layout';

/**
 * Layout rules for the model options panel.
 *
 * Checked one by one: web W1-W20, thinking R1-R18, footer F1-F15. Written into JSX these rules
 * could only be verified by looking at a browser, and the number of combinations is far past what
 * the eye can track -- so they are pure functions, and this is the only place they are asserted.
 */

const ALL_STATUSES: ModelControlStatus[] = [
  'automaticAvailable', 'forceUnsupported', 'managedFree', 'managedBalance',
  'customOnly', 'pending', 'externalConnectorOnly', 'unsupported', 'unknown',
];

describe('server control state -> panel presentation', () => {
  it('expands state + reasonCode into the full shape table', () => {
    expect(resolveModelControlStatus({ state: 'auto_available' })).toBe('automaticAvailable');
    expect(resolveModelControlStatus({ state: 'managed_only' })).toBe('managedFree');
    expect(resolveModelControlStatus({ state: 'managed_only', reasonCode: 'managed_balance_server_authority' }))
      .toBe('managedBalance');
    expect(resolveModelControlStatus({ state: 'custom_only' })).toBe('customOnly');
    expect(resolveModelControlStatus({ state: 'unavailable' })).toBe('unsupported');
    expect(resolveModelControlStatus({ state: 'unavailable', reasonCode: 'external_connector_only' }))
      .toBe('externalConnectorOnly');
    expect(resolveModelControlStatus({ state: 'unknown' })).toBe('unknown');
  });

  it('reasonCode only refines the unknown sub-states and never promotes it to unavailable', () => {
    for (const reasonCode of ['endpoint_route_pending', 'model_route_pending', 'official_source_insufficient',
      'source_review_expired', 'provider_kill_switch']) {
      expect(resolveModelControlStatus({ state: 'unknown', reasonCode })).toBe('pending');
    }
    expect(resolveModelControlStatus({ state: 'unknown', reasonCode: 'untrusted server prose' })).toBe('unknown');
  });

  /**
   * `forceUnsupported` is a state the panel path cannot produce -- it belongs to the
   * `forceRequested` subdivision used by one specific caller. The branch exists only to keep the
   * nine-state shape table strictly isomorphic across clients.
   *
   * Why pin it explicitly: W1 does not use the status sentence
   * `capabilityControlForceUnavailable` ("Every time requires an official recipe for this
   * connection.") precisely because this state cannot reach F5 --
   * `modelControlStatusIsConfigurable(forceUnsupported) === true`, and F5 says that sentence only
   * when `!isConfigurable`. That reasoning rests on two premises, and changing either one lets
   * the default branch of `modelControlStatusTextKey` quietly turn "the force tier has no
   * official recipe" into "no automatic configuration yet" -- a completely different statement
   * that nobody would notice. Both premises are pinned here: anyone who wants this state to be
   * reachable has to restore that copy first.
   */
  it('forceUnsupported cannot be produced, and would not reach the F5 status sentence even if it were', () => {
    const states = ['auto_available', 'managed_only', 'custom_only', 'unavailable', 'unknown'] as const;
    const reasonCodes = [undefined, 'managed_balance_server_authority', 'external_connector_only',
      'endpoint_route_pending', 'model_route_pending', 'official_source_insufficient',
      'source_review_expired', 'provider_kill_switch', 'anything else'];
    for (const state of states) {
      for (const reasonCode of reasonCodes) {
        expect(resolveModelControlStatus({ state, ...(reasonCode ? { reasonCode } : {}) }))
          .not.toBe('forceUnsupported');
      }
    }
    expect(modelControlStatusIsConfigurable('forceUnsupported')).toBe(true);
  });
});

describe(' W1-W20 ', () => {
  const layout = (overrides: Partial<Parameters<typeof modelControlWebLayout>[0]> = {}) =>
    modelControlWebLayout({
      status: 'automaticAvailable', availableIntents: [], selection: 'off', isEditable: true, ...overrides,
    });

  it('W1 a managed connection gets one non-interactive "managed by Oriveo" line', () => {
    for (const status of ['managedFree', 'managedBalance'] as const) {
      const result = layout({ status });
      expect(result.form).toBe('statusRow');
      expect(result.statusTextKey).toBe('common.managedByOriveo');
      expect(result.explanationKey).toBeUndefined();
      expect(result.escape).toBe('none');
    }
  });

  it('W2 unsupported / externalConnectorOnly attribute to "no official configuration" and offer a model switch', () => {
    for (const status of ['unsupported', 'externalConnectorOnly'] as const) {
      const result = layout({ status });
      expect(result.statusTextKey).toBe('common.capabilityControlNotSupportedByModel');
      expect(result.explanationKey).toBe('common.capabilityControlWebNoOfficialConfig');
      expect(result.escape).toBe('supportedModels');
    }
  });

  it('W3 customOnly branches on hasCustomSchema -- with no schema the user must not be sent down a dead end', () => {
    expect(layout({ status: 'customOnly', hasCustomSchema: true }).escape).toBe('advancedSettings');
    expect(layout({ status: 'customOnly', hasCustomSchema: false }).escape).toBe('supportedModels');
    expect(layout({ status: 'customOnly' }).statusTextKey).toBe('common.capabilityControlCustomOnlyReason');
  });

  it('W4 pending / unknown degrade to an honest status line with no escape-hatch switch', () => {
    for (const status of ['pending', 'unknown'] as const) {
      const result = layout({ status, selection: 'automatic' });
      expect(result.form).toBe('statusRow');
      expect(result.statusTextKey).toBe('common.capabilityControlCannotAdjustYet');
      expect(result.escape).toBe('supportedModels');
    }
  });

  it('W5 read-only shows the current value in the status line, not a status sentence', () => {
    expect(layout({ isEditable: false, selection: 'off' }).statusTextKey).toBe('pages.chat.reasoning.off');
    expect(layout({ isEditable: false, selection: 'automatic' }).statusTextKey).toBe('pages.chat.reasoning.auto');
    expect(layout({ isEditable: false, selection: 'force', availableIntents: ['force'] }).statusTextKey)
      .toBe('pages.chat.reasoning.force');
  });

  it('W7/W8 the on state of the switch covers automatic and force, and the caption is always present', () => {
    expect(layout({ selection: 'off' }).isOn).toBe(false);
    expect(layout({ selection: 'automatic' }).isOn).toBe(true);
    expect(layout({ selection: 'force', availableIntents: ['force'] }).isOn).toBe(true);
    expect(layout({ selection: 'automatic' }).captionKey).toBe('common.capabilityControlWebSwitchNote');
  });

  it('W9/W10 "search timing" appears only when the recipe declares force and the switch is on, with a frozen vocabulary', () => {
    expect(layout({ selection: 'automatic', availableIntents: [] }).timingOptions).toEqual([]);
    expect(layout({ selection: 'off', availableIntents: ['force'] }).timingOptions).toEqual([]);
    expect(layout({ selection: 'automatic', availableIntents: ['force'] }).timingOptions).toEqual([
      { id: 'automatic', labelKey: 'pages.chat.reasoning.auto' },
      { id: 'force', labelKey: 'pages.chat.reasoning.force' },
    ]);
  });

  it('W11 timingSelection is still computable in the status line layout', () => {
    expect(layout({ status: 'unsupported', selection: 'force' }).timingSelection).toBe('force');
    expect(layout({ status: 'unsupported', selection: 'off' }).timingSelection).toBe('automatic');
  });

  it('W14/W15 the F9 clamp narrows only when automatic configuration exists and the recipe has no force', () => {
    expect(clampModelControlWebPreference('force', 'automaticAvailable', [])).toBe('automatic');
    expect(clampModelControlWebPreference('force', 'forceUnsupported', [])).toBe('automatic');
    expect(clampModelControlWebPreference('force', 'automaticAvailable', ['force'])).toBe('force');
    // Overwriting a stored user choice before the snapshot arrives is the hardest kind of silent loss to prove after the fact.
    for (const status of ['managedFree', 'managedBalance', 'customOnly', 'pending',
      'externalConnectorOnly', 'unsupported', 'unknown'] as const) {
      expect(clampModelControlWebPreference('force', status, [])).toBe('force');
    }
    for (const status of ALL_STATUSES) {
      expect(clampModelControlWebPreference('automatic', status, [])).toBe('automatic');
      expect(clampModelControlWebPreference('off', status, [])).toBe('off');
    }
  });

  it('W16 the clamp result is exposed to the caller through effectiveSelection for write-back', () => {
    const result = layout({ selection: 'force', availableIntents: [] });
    expect(result.effectiveSelection).toBe('automatic');
    expect(result.isOn).toBe(true);
    expect(result.timingOptions).toEqual([]);
  });
});

describe(' R1-R18 ', () => {
  const layout = (overrides: Partial<Parameters<typeof modelControlReasoningLayout>[0]> = {}) =>
    modelControlReasoningLayout({
      status: 'automaticAvailable', intents: ['off', 'low', 'balanced', 'deep', 'max'], isEditable: true, ...overrides,
    });

  it('R1 the tier order is frozen to the five tiers in the shared contract', () => {
    expect(MODEL_CONTROL_REASONING_TIER_ORDER).toEqual(['off', 'low', 'balanced', 'deep', 'max']);
  });

  it('R2-R5 each non-configurable state has its own status line and way out', () => {
    expect(layout({ status: 'managedFree' }).statusTextKey).toBe('common.managedByOriveo');
    expect(layout({ status: 'managedFree' }).escape).toBe('none');
    expect(layout({ status: 'unsupported' }).explanationKey).toBe('common.capabilityControlUnavailableForConnection');
    expect(layout({ status: 'unsupported' }).escape).toBe('supportedModels');
    expect(layout({ status: 'customOnly', hasCustomSchema: false }).escape).toBe('supportedModels');
    const pending = layout({ status: 'pending' });
    expect(pending.form).toBe('statusRow');
    expect(pending.statusTextKey).toBe('common.capabilityControlCannotAdjustYet');
    expect(pending.explanationKey).toBe('common.capabilityControlReasoningNoOfficialConfig');
    expect(pending.escape).toBe('supportedModels');
    // Thinking's unknown has neither an "automatic" single line nor a switch: with no recipe there is no outbound field to compile.
    expect(pending.options).toEqual([]);
  });

  it('R6 read-only shows the current tier name in the status line', () => {
    expect(layout({ isEditable: false, selectedIntent: 'deep' }).statusTextKey).toBe('pages.chat.reasoning.deep');
    expect(layout({ isEditable: false }).statusTextKey).toBe('pages.chat.reasoning.supplierDefault');
  });

  it('R7 a single fixed tier is one whole sentence and is deliberately not clickable', () => {
    const result = layout({ intents: [] });
    expect(result.form).toBe('statusRow');
    expect(result.statusTextKey).toBe('common.capabilityControlReasoningFixedLevel');
    expect(result.explanationKey).toBeUndefined();
    expect(result.escape).toBe('none');
  });

  it('only the tiers the recipe actually sends are rendered; "automatic" is always present and sits after off', () => {
    expect(layout({ intents: ['off', 'low', 'deep'] }).options.map((option) => option.id))
      .toEqual(['off', 'automatic', 'low', 'deep']);
    expect(layout({ intents: ['balanced'] }).options.map((option) => option.id))
      .toEqual(['automatic', 'balanced']);
    // A missing tier is not rendered at all rather than greyed out: a row of dead grey pills cannot answer whether switching models would help.
    expect(layout({ intents: ['balanced'] }).options.some((option) => option.id === 'max')).toBe(false);
  });

  it('R10/R11 "automatic" is the default selection; a stored tier missing from the recipe falls back rather than leaving nothing highlighted', () => {
    expect(layout({ intents: ['low'] }).selection).toBe('automatic');
    expect(layout({ intents: ['low'], selectedIntent: 'low' }).selection).toBe('low');
    expect(layout({ intents: ['low'], selectedIntent: 'max' }).selection).toBe('automatic');
  });

  it('R12/R13 the annotation follows the effective selection, one distinct sentence per tier', () => {
    expect(layout({ selectedIntent: 'low' }).selectedAnnotationKey)
      .toBe('common.capabilityControlReasoningNoteFast');
    expect(layout({ selectedIntent: 'max' }).selectedAnnotationKey)
      .toBe('common.capabilityControlReasoningNoteMax');
    // The annotation has to fall back with the selection, or the UI describes a tier that is not selected.
    expect(layout({ intents: ['low'], selectedIntent: 'max' }).selectedAnnotationKey)
      .toBe('common.capabilityControlReasoningNoteAutomatic');
    const notes = new Set(['off', 'automatic', 'low', 'balanced', 'deep', 'max']
      .map((intent) => layout({ selectedIntent: intent }).selectedAnnotationKey));
    expect(notes.size).toBe(6);
  });

  it('R15 "thinking cannot be turned off" is permanent when the recipe has no off, and absent when it has one', () => {
    expect(layout({ intents: ['low', 'deep'] }).footnoteKey)
      .toBe('common.capabilityControlReasoningOffUnavailable');
    expect(layout({ intents: ['off', 'low'] }).footnoteKey).toBeUndefined();
  });

  it('R17 the panel does not render "higher tiers are slower and cost more", which has no consumer', () => {
    const rendered = ALL_STATUSES.flatMap((status) => {
      const result = layout({ status });
      return [result.footnoteKey, result.selectedAnnotationKey, result.statusTextKey, result.explanationKey];
    });
    expect(rendered).not.toContain('common.capabilityControlTierCostNote');
  });
});

describe(' F1-F15 ', () => {
  it('F13 the normal state (writable, configurable, no risk) is an empty array in both contexts', () => {
    for (const context of ['panelCard', 'behaviorPageHeader'] as const) {
      expect(modelControlFooterEntries({ context })).toEqual([]);
    }
  });

  it('F3 a custom takeover swallows the read-only and status lines and offers the route to advanced settings', () => {
    expect(modelControlFooterEntries({
      overridden: true, readOnlyReason: 'read only', isConfigurable: false,
      statusTextKey: 'common.capabilityControlReasonPending', showsAdvancedSettingsAction: true,
      showsSupportedModelsAction: true, hasSupportedModelCandidates: true,
    })).toEqual([
      { kind: 'note', textKey: 'common.customRequestFieldsActiveNote', tone: 'warning' },
      { kind: 'advancedSettingsLink' },
    ]);
  });

  it('F4/F5 the read-only reason and status sentence appear only in the advanced settings context, since the main panel already said it', () => {
    expect(modelControlFooterEntries({ context: 'panelCard', readOnlyReason: 'read only' })).toEqual([]);
    expect(modelControlFooterEntries({ context: 'behaviorPageHeader', readOnlyReason: 'read only' }))
      .toEqual([{ kind: 'note', text: 'read only', tone: 'tertiary' }]);
    expect(modelControlFooterEntries({
      context: 'panelCard', isConfigurable: false, statusTextKey: 'common.capabilityControlReasonPending',
    })).toEqual([]);
  });

  it('F6 an upstream rejection is reported as it is', () => {
    expect(modelControlFooterEntries({ upstreamRejected: true }))
      .toEqual([{ kind: 'note', textKey: 'common.capabilityControlUpstreamRejected', tone: 'warning' }]);
  });

  it('F7/F8 risk hints follow custom fields only and never appear in the normal main panel', () => {
    expect(modelControlFooterEntries({ context: 'panelCard', riskTiers: ['cost_impacting'] })).toEqual([]);
    expect(modelControlFooterEntries({ context: 'behaviorPageHeader', riskTiers: ['privacy_impacting', 'x'] }))
      .toEqual([
        { kind: 'note', textKey: 'common.capabilityRiskPrivacy', tone: 'warning' },
        { kind: 'note', textKey: 'common.capabilityRiskCost', tone: 'warning' },
      ]);
  });

  it('F9/F10 a link when candidates exist, and a more informative sentence when they do not', () => {
    expect(modelControlFooterEntries({ showsSupportedModelsAction: true, hasSupportedModelCandidates: true }))
      .toEqual([{ kind: 'supportedModelsLink' }]);
    expect(modelControlFooterEntries({ showsSupportedModelsAction: true, hasSupportedModelCandidates: false }))
      .toEqual([{ kind: 'note', textKey: 'common.capabilityControlNoSupportedModels', tone: 'tertiary' }]);
  });

  it('F12 the footer gives way when the status line already offers the same route, and stays for a different one', () => {
    expect(modelControlFooterEntries({
      showsSupportedModelsAction: true, hasSupportedModelCandidates: true, statusRowEscape: 'supportedModels',
    })).toEqual([]);
    expect(modelControlFooterEntries({
      showsSupportedModelsAction: true, hasSupportedModelCandidates: true, statusRowEscape: 'advancedSettings',
    })).toEqual([{ kind: 'supportedModelsLink' }]);
  });

  it('F14 the state set where "view supported models" applies, customOnly included', () => {
    const shows = ALL_STATUSES.filter(modelControlShowsSupportedModelsAction);
    expect(shows.sort()).toEqual(
      ['customOnly', 'externalConnectorOnly', 'pending', 'unknown', 'unsupported'].sort(),
    );
  });
});

describe('badges', () => {
  it(' ', () => {
    expect(modelControlBadge(modelControlBadgeClassification('automaticAvailable'), false)).toBeNull();
    expect(modelControlBadge(modelControlBadgeClassification('forceUnsupported'), false)).toBeNull();
  });

  it('the capability card does not stack an "unavailable" badge on unsupported / externalConnectorOnly', () => {
    for (const status of ['unsupported', 'externalConnectorOnly'] as const) {
      expect(modelControlBadgeClassification(status)).toBe('unavailable');
      expect(modelControlCardBadgeClassification(status)).toBe('none');
      expect(modelControlBadge(modelControlCardBadgeClassification(status), false)).toBeNull();
    }
  });

  it('the other badges are kept: managed / needs manual setup / not ready / custom', () => {
    expect(modelControlBadge(modelControlCardBadgeClassification('managedFree'), false)?.textKey)
      .toBe('common.managedByOriveo');
    expect(modelControlBadge(modelControlCardBadgeClassification('customOnly'), false)?.textKey)
      .toBe('common.capabilityControlBadgeManual');
    expect(modelControlBadge(modelControlCardBadgeClassification('pending'), false)?.textKey)
      .toBe('pages.chat.reasoning.notReady');
    expect(modelControlBadge(modelControlCardBadgeClassification('unknown'), false)?.textKey)
      .toBe('pages.chat.reasoning.notReady');
    // A custom takeover wins over everything: it says the preference chosen above will not be sent.
    expect(modelControlBadge(modelControlCardBadgeClassification('automaticAvailable'), true)?.textKey)
      .toBe('common.capabilityControlBadgeCustom');
  });

  /**
   * Request parameter editing on the advanced settings row goes through the generation profile
   * and reads no recipe at all. Relay (capabilityControls always empty) and official models with
   * no generation control sent both land on `unknown`, which would otherwise leave a permanent
   * "not ready" badge on a row whose parameters are in fact adjustable and which says "N
   * adjusted" right next to it.
   */
  it('AQA-11 the advanced settings row does not hang a "not ready" badge on pending / unknown', () => {
    for (const status of ['pending', 'unknown'] as const) {
      // Counter-check: the rule itself is untouched; only this card's projection of it changes.
      expect(modelControlBadgeClassification(status)).toBe('notReady');
      expect(modelControlAdvancedSettingsBadgeClassification(status)).toBe('none');
      expect(modelControlBadge(modelControlAdvancedSettingsBadgeClassification(status), false)).toBeNull();
    }
  });

  it('AQA-11 only notReady is suppressed: unavailable / managed / needs manual setup / custom still show on the advanced settings row', () => {
    // "Unavailable" is the server stating it cannot be done, and this row has no status line to
    // say so on its behalf: the two projections suppress different tiers.
    for (const status of ['unsupported', 'externalConnectorOnly'] as const) {
      expect(modelControlAdvancedSettingsBadgeClassification(status)).toBe('unavailable');
      expect(modelControlBadge(modelControlAdvancedSettingsBadgeClassification(status), false)?.textKey)
        .toBe('pages.chat.reasoning.unavailable');
    }
    expect(modelControlBadge(modelControlAdvancedSettingsBadgeClassification('managedFree'), false)?.textKey)
      .toBe('common.managedByOriveo');
    expect(modelControlBadge(modelControlAdvancedSettingsBadgeClassification('managedBalance'), false)?.textKey)
      .toBe('common.managedByOriveo');
    expect(modelControlBadge(modelControlAdvancedSettingsBadgeClassification('customOnly'), false)?.textKey)
      .toBe('common.capabilityControlBadgeManual');
    expect(modelControlBadge(modelControlAdvancedSettingsBadgeClassification('automaticAvailable'), true)?.textKey)
      .toBe('common.capabilityControlBadgeCustom');
  });

  it('AQA-11 the two projections suppress different tiers and must not be written as one function', () => {
    expect(modelControlCardBadgeClassification('unsupported')).toBe('none');
    expect(modelControlAdvancedSettingsBadgeClassification('unsupported')).toBe('unavailable');
    expect(modelControlCardBadgeClassification('pending')).toBe('notReady');
    expect(modelControlAdvancedSettingsBadgeClassification('pending')).toBe('none');
  });
});

describe('writability and identity gaps', () => {
  it('a managed connection is never writable, whether or not identity is ready', () => {
    expect(resolveModelControlsEditability({ providerKind: 'openAI', runtimeIsReadOnly: true }))
      .toBe('runtimeIdentityUnavailable');
    expect(resolveModelControlsEditability({
      providerKind: 'openAI', transportIdentity: 'r1.a.b', runtimeIsReadOnly: true,
    })).toBe('runtimeReadOnly');
    expect(resolveModelControlsEditability({
      providerKind: 'openAI', transportIdentity: 'r1.a.b', runtimeIsReadOnly: false,
    })).toBe('writable');
  });

  it('each of the three identity gaps gets the action that actually resolves it', () => {
    const gap = (input: Parameters<typeof resolveModelControlsIdentityGap>[0]) =>
      modelControlsIdentityRecovery(resolveModelControlsIdentityGap(input));
    // runtime is the first guard: while it is not ready the other two cannot be decided, so neither may come first.
    expect(gap({ providerKind: 'relay', relayTransportIsDecided: false, runtimeIsReady: false }))
      .toBe('refetchRuntime');
    expect(gap({ providerKind: 'relay', relayTransportIsDecided: false, runtimeIsReady: true }))
      .toBe('openConnectionSettings');
    expect(gap({ providerKind: 'openAI', relayTransportIsDecided: false, runtimeIsReady: true }))
      .toBe('chooseAnotherModel');
  });
});

describe('transport presentation', () => {
  it('recognizes both the catalog and the relay vocabulary', () => {
    expect(modelControlTransportLabel('openai_chat')).toBe('Chat Completions');
    expect(modelControlTransportLabel('openai_chat_completions')).toBe('Chat Completions');
    expect(modelControlTransportLabel('gemini_generate')).toBe('generateContent');
    expect(modelControlTransportLabel('gemini_generate_content')).toBe('generateContent');
    expect(modelControlTransportLabel('llamacpp_native')).toBe('llama.cpp');
    expect(modelControlTransportLabel('something_new')).toBeUndefined();
  });
});

/**
 * W3 - stale web preference liveness.
 *
 * This is the only rule of its kind, and all three consumers (chip highlight, restored state,
 * explicit outbound intent key) ask it. A second copy of `web !== 'off'` anywhere would grow back
 * "a lit globe that never searches" at that spot.
 */
describe('W3 - CapabilityWebPreferenceLiveness LV1-LV3', () => {
  it('LV1 only automaticAvailable or a custom takeover counts as reaching the network', () => {
    expect(modelControlWebReachesTheWire({ status: 'automaticAvailable', customIsActive: false })).toBe(true);
    expect(modelControlWebReachesTheWire({ status: 'unsupported', customIsActive: true })).toBe(true);
  });

  it('LV2 the unlit state set: never lit when there is no official configuration and no custom takeover', () => {
    const dark: ModelControlStatus[] = [
      'pending', 'unknown', 'unsupported', 'externalConnectorOnly', 'customOnly',
      'managedFree', 'managedBalance',
    ];
    for (const status of dark) {
      expect(modelControlWebReachesTheWire({ status, customIsActive: false })).toBe(false);
    }
  });

  it('LV3 forceUnsupported is unlit too -- it is not the same set as isConfigurable', () => {
    expect(modelControlWebReachesTheWire({ status: 'forceUnsupported', customIsActive: false })).toBe(false);
    // Control group: the same state is configurable when the question is whether an intent can be expressed.
    expect(modelControlStatusIsConfigurable('forceUnsupported')).toBe(true);
  });
});
