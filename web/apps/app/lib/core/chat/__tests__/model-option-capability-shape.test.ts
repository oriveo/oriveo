/**
 * Capability card shapes: one test per card, the automatic tier in the first slot, and fallback after a rejected tier.
 */
import { describe, expect, it, vi } from 'vitest';

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import {
  resolveModelOptionCapabilityCard,
  resolveModelOptionCapabilityShape,
  type ModelOptionCapabilityInput,
} from '../model-option-capability-shape';

function input(overrides: Partial<ModelOptionCapabilityInput>): ModelOptionCapabilityInput {
  return {
    capability: 'reasoning',
    status: 'automaticAvailable',
    availableIntents: [],
    connection: 'official',
    isWritable: true,
    protocolUndecided: false,
    rejectedIntents: [],
    chatTemplateThinkingIsOn: false,
    supportsChatTemplate: false,
    ...overrides,
  };
}

const shape = (overrides: Partial<ModelOptionCapabilityInput>) => resolveModelOptionCapabilityShape(input(overrides));

describe('capability card shapes', () => {
  it('on/off only: renders a plain switch', () => {
    expect(shape({ availableIntents: ['off', 'deep'], selectedIntent: 'deep' })).toEqual({
      kind: 'toggle', capability: 'reasoning', isOn: true,
      target: { kind: 'capabilityPreference', on: 'deep', off: 'off' }, caption: 'thinksFirst',
    });
  });

  it('several tiers, can be turned off: trailing shows the note of the selected tier', () => {
    expect(shape({ availableIntents: ['off', 'low', 'deep', 'max'], selectedIntent: 'off' })).toEqual({
      kind: 'tiers', capability: 'reasoning', includesOff: true,
      options: ['off', 'low', 'deep', 'max'], selection: 'off',
      trailing: { kind: 'tierNote', intent: 'off' }, footnotes: [], rejected: [],
    });
  });

  it('several tiers, cannot be turned off: trailing says it always thinks first, footnotes are [tier note, cost note]', () => {
    expect(shape({ availableIntents: ['low', 'balanced', 'deep', 'max'], selectedIntent: 'balanced' })).toEqual({
      kind: 'tiers', capability: 'reasoning', includesOff: false,
      options: ['low', 'balanced', 'deep', 'max'], selection: 'balanced',
      trailing: { kind: 'alwaysThinks' },
      footnotes: [{ kind: 'tierNote', intent: 'balanced' }, { kind: 'costNote' }], rejected: [],
    });
  });

  it('no official configuration yet: thinking follows the model default, the way out points to supported models', () => {
    for (const status of ['pending', 'unknown'] as const) {
      expect(shape({ status })).toEqual({
        kind: 'notice', capability: 'reasoning', status: 'modelDefault',
        body: { kind: 'notCatalogued', capability: 'reasoning' }, link: 'openSupportedModels',
      });
    }
    expect(shape({ capability: 'web', status: 'pending' })).toEqual({
      kind: 'notice', capability: 'web', status: 'temporarilyUnavailable',
      body: { kind: 'notCatalogued', capability: 'web' }, link: 'openSupportedModels',
    });
  });

  it('the model itself does not think', () => {
    expect(shape({ status: 'unsupported' })).toEqual({
      kind: 'disclosure', capability: 'reasoning', status: { kind: 'modelLacksCapability' }, link: 'openSupportedModels',
    });
  });

  it('web search on: adds a timing row', () => {
    expect(shape({ capability: 'web', availableIntents: ['automatic', 'force'], selectedIntent: 'force' })).toEqual({
      kind: 'toggleWithTiming', capability: 'web', isOn: true,
      target: { kind: 'capabilityPreference', on: 'automatic', off: 'off' },
      timing: { options: ['automatic', 'force'], selection: 'force' },
    });
    const automatic = shape({ capability: 'web', availableIntents: ['automatic', 'force'], selectedIntent: 'automatic' });
    expect(automatic.kind === 'toggleWithTiming' && automatic.timing.selection).toBe('automatic');
  });

  it('web search without a force tier, or turned off: plain switch with caption', () => {
    expect(shape({ capability: 'web', availableIntents: ['automatic', 'force'], selectedIntent: 'off' })).toEqual({
      kind: 'toggle', capability: 'web', isOn: false,
      target: { kind: 'capabilityPreference', on: 'automatic', off: 'off' }, caption: 'searchesTheWeb',
    });
    const on = shape({ capability: 'web', availableIntents: ['automatic'], selectedIntent: 'automatic' });
    expect(on.kind === 'toggle' && on.isOn).toBe(true);
  });

  it('web search has to be configured manually', () => {
    expect(shape({ capability: 'web', status: 'customOnly' })).toEqual({
      kind: 'notice', capability: 'web', status: 'needsOwnConfiguration',
      body: { kind: 'customOnly', capability: 'web' }, link: 'openAdditionalRequestBody',
    });
  });

  it('the model cannot search the web (official connection)', () => {
    for (const status of ['unsupported', 'externalConnectorOnly'] as const) {
      expect(shape({ capability: 'web', status })).toEqual({
        kind: 'disclosure', capability: 'web', status: { kind: 'modelLacksCapability' }, link: 'openSupportedModels',
      });
    }
  });

  it('custom LLM with undecided protocol: collapses the whole card into one item', () => {
    const card = resolveModelOptionCapabilityCard({
      web: input({ capability: 'web', status: 'unknown', connection: 'custom', protocolUndecided: true }),
      reasoning: input({ status: 'unknown', connection: 'custom', protocolUndecided: true, supportsChatTemplate: true }),
    });
    expect(card).toEqual({ kind: 'protocolUndecided', link: 'openConnectionProtocol' });
  });

  it('custom LLM / local engine: thinking follows the chat template switch, web search is not available on this connection', () => {
    const card = resolveModelOptionCapabilityCard({
      web: input({ capability: 'web', status: 'unknown', connection: 'custom' }),
      reasoning: input({ status: 'unknown', connection: 'custom', supportsChatTemplate: true, chatTemplateThinkingIsOn: true }),
    });
    expect(card).toEqual({
      kind: 'rows',
      web: { kind: 'disclosure', capability: 'web', status: { kind: 'cannotDoOnThisConnection' }, link: 'switchConnection' },
      reasoning: {
        kind: 'toggle', capability: 'reasoning', isOn: true, target: { kind: 'chatTemplateThinking' },
        caption: 'chatTemplateThinking', link: 'openAdditionalRequestBody',
      },
    });
  });

  it('the provider rejected this option: warning on the trailing side, footnote names the fallback tier', () => {
    expect(shape({ availableIntents: ['low', 'balanced', 'deep', 'max'], selectedIntent: 'max', rejectedIntents: ['max'] })).toEqual({
      kind: 'tiers', capability: 'reasoning', includesOff: false,
      options: ['low', 'balanced', 'deep'], selection: 'deep',
      trailing: { kind: 'rejected', intent: 'max' },
      footnotes: [{ kind: 'rejectedFallback', rejected: 'max', fallback: 'deep' }], rejected: ['max'],
    });
  });
});

describe('tier details', () => {
  it('the automatic tier appears only when declared, takes the first slot and is selected by default', () => {
    const tiers = shape({ availableIntents: ['max', 'off', 'automatic', 'low'] });
    expect(tiers.kind === 'tiers' && tiers.options).toEqual(['automatic', 'off', 'low', 'max']);
    expect(tiers.kind === 'tiers' && tiers.selection).toBe('automatic');
    expect(tiers.kind === 'tiers' && tiers.trailing).toEqual({ kind: 'tierNote', intent: 'automatic' });
  });

  it('no off, no automatic, nothing selected: trailing follows the model default and the footnote has only the cost note', () => {
    const tiers = shape({ availableIntents: ['low', 'deep'] });
    expect(tiers.kind === 'tiers' && [tiers.selection, tiers.trailing, tiers.footnotes])
      .toEqual([undefined, { kind: 'modelDefault' }, [{ kind: 'costNote' }]]);
  });

  it('with off, nothing selected: trailing follows the model default', () => {
    const tiers = shape({ availableIntents: ['off', 'low', 'deep'] });
    expect(tiers.kind === 'tiers' && tiers.trailing).toEqual({ kind: 'modelDefault' });
  });

  it('rejected tier fallback: looks higher when no lower tier remains', () => {
    const tiers = shape({ availableIntents: ['off', 'low', 'balanced', 'deep'], selectedIntent: 'low', rejectedIntents: ['low'] });
    expect(tiers.kind === 'tiers' && [tiers.selection, tiers.footnotes])
      .toEqual(['balanced', [{ kind: 'rejectedFallback', rejected: 'low', fallback: 'balanced' }]]);
  });

  it('the automatic tier is never rejected: even if listed in rejectedIntents it stays in the first slot and selectable', () => {
    const tiers = shape({ availableIntents: ['automatic', 'off', 'low', 'deep'], selectedIntent: 'automatic', rejectedIntents: ['automatic'] });
    expect(tiers.kind === 'tiers' && [tiers.options, tiers.selection, tiers.trailing, tiers.rejected])
      .toEqual([['automatic', 'off', 'low', 'deep'], 'automatic', { kind: 'tierNote', intent: 'automatic' }, []]);
  });

  it('rejected tier is not the selected one: warns about the highest rejected tier', () => {
    const tiers = shape({ availableIntents: ['off', 'low', 'deep', 'max'], selectedIntent: 'low', rejectedIntents: ['deep', 'max'] });
    expect(tiers.kind === 'tiers' && [tiers.selection, tiers.trailing, tiers.rejected])
      .toEqual(['low', { kind: 'rejected', intent: 'max' }, ['deep', 'max']]);
  });

  it('only one tier available: notice "always thinks first" plus a fixed tier note', () => {
    expect(shape({ availableIntents: ['deep'] })).toEqual({
      kind: 'notice', capability: 'reasoning', status: 'alwaysThinks', body: { kind: 'fixedTier', intent: 'deep' },
    });
  });

  it('off plus one tier but automatic declared: tiers, not a switch', () => {
    expect(shape({ availableIntents: ['automatic', 'off', 'deep'] }).kind).toBe('tiers');
  });

  it('not writable: shows the current value read-only', () => {
    expect(shape({ isWritable: false, availableIntents: ['automatic', 'low'] }))
      .toEqual({ kind: 'disclosure', capability: 'reasoning', status: { kind: 'currentValue', value: { kind: 'reasoningTier', intent: 'automatic' } } });
    expect(shape({ isWritable: false, availableIntents: ['low'] }).kind === 'disclosure'
      && shape({ isWritable: false, availableIntents: ['low'] })).toMatchObject({ status: { value: { kind: 'modelDefault' } } });
    expect(shape({ capability: 'web', isWritable: false, status: 'forceUnsupported', selectedIntent: 'force' }))
      .toMatchObject({ kind: 'disclosure', status: { value: { kind: 'webPreference', preference: 'force' } } });
    expect(shape({ status: 'unknown', connection: 'custom', supportsChatTemplate: true, isWritable: false }))
      .toEqual({ kind: 'disclosure', capability: 'reasoning', status: { kind: 'currentValue', value: { kind: 'chatTemplateThinking', isOn: false } } });
  });

  it('custom connection, unknown status, no chat template support: thinking is the same as "needs your own configuration"', () => {
    expect(shape({ status: 'pending', connection: 'custom' })).toEqual({
      kind: 'notice', capability: 'reasoning', status: 'needsOwnConfiguration',
      body: { kind: 'customOnly', capability: 'reasoning' }, link: 'openAdditionalRequestBody',
    });
  });

  it('only one row has an undecided protocol: two rows plus the way out for that row', () => {
    const card = resolveModelOptionCapabilityCard({
      web: input({ capability: 'web', status: 'unknown', connection: 'custom', protocolUndecided: true }),
      reasoning: input({ status: 'unsupported' }),
    });
    expect(card).toMatchObject({
      kind: 'rows',
      web: { kind: 'protocolUndecided', link: 'openConnectionProtocol' },
      reasoning: { kind: 'disclosure', status: { kind: 'modelLacksCapability' } },
    });
  });
});
