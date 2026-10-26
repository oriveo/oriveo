import 'fake-indexeddb/auto';
/**
  * Structure of the "Model options" board (three-client comparison; BOARD-OPTIONS-01 to 10).
 *
  * The web / reasoning inputs of 01 to 05 go through the production form functions (`modelOptionsPanelModel` -> `resolveModelOptionCapabilityCard`);
  * the file wire comes from the production `resolveAttachmentLine`, and the vision card facts from the production `visionCardFacts` (which reads the vision projection).
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import type { ModelOptionCapabilityInput } from '../model-option-capability-shape';
import { resolveAttachmentLine } from '../../attachments/attachment-transport-resolver';
import { visionCardFacts } from '../attachment-policy';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../stream-options';
import { recordInputNegativeCache } from '../../capability/input-negative-cache';
import { inputNegativeCacheTarget } from '../../capability/truth/input-truth-adapter';
import { createRelayManualModel } from '../../provider-model-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { resolveGenerationParameterOverridesWithSources, saveGenerationParameterOverrides } from '../generation-parameter-settings';
import { generationParameterRows } from '../generation-parameter-rows';
import { localEngineGenerationProfile } from '../local-engine-profiles';
import {
  modelOptionsPanelModel,
  modelOptionsTiles,
  type ModelOptionsFileFacts,
  type ModelOptionsPanelFacts,
  type ModelOptionsPanelModel,
  type ModelOptionsVisionFacts,
} from '../model-options-panel-model';
import {
  modelOptionDisclosureStatusCopy,
  modelOptionsSummaryItemCopy,
  modelOptionsTileBodyCopy,
  modelOptionsTileStatusCopy,
} from '../model-options-copy';

const PDF = 'application/pdf';
const DOCX = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

function capability(overrides: Partial<ModelOptionCapabilityInput>): ModelOptionCapabilityInput {
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

const NO_NOTES = { overridden: false, riskTiers: [], upstreamRejected: false };
const VISIBLE: ModelOptionsVisionFacts = { entryVisible: true, isRelayForm: false, noPositiveEvidence: false };
const TEXT_FILE: ModelOptionsFileFacts = { nativeFileMimes: [], pdfNativeDefault: false };

function facts(overrides: Partial<ModelOptionsPanelFacts> = {}): ModelOptionsPanelFacts {
  return {
    isManaged: false,
    connection: 'official',
    connectionName: 'OpenAI',
    web: capability({ capability: 'web', availableIntents: ['off', 'automatic'], selectedIntent: 'off' }),
    reasoning: capability({ availableIntents: ['automatic', 'off', 'low', 'deep'] }),
    chatTemplateState: 'off',
    hasAlternativeModels: { web: true, reasoning: true },
    hasReadOnlyReason: false,
    generationRows: [],
    notes: { web: NO_NOTES, reasoning: NO_NOTES },
    vision: VISIBLE,
    file: TEXT_FILE,
    ...overrides,
  };
}

/** "Kind:top-right" of each card; capability cards carry the capability name. */
const board = (model: ModelOptionsPanelModel) => model.tiles.map((tile) => (
  tile.kind === 'capability' ? `${tile.capability}:${tile.corner}` : `${tile.kind}:${tile.corner}`
));
const statuses = (model: ModelOptionsPanelModel) => model.tiles.map((tile) => modelOptionsTileStatusCopy(tile));

const provider = (overrides: Partial<Provider>): Provider => ({
  id: 'p1', kind: 'openAI', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '',
  ...overrides,
}) as unknown as Provider;
const fileModel = { id: 'm1', upstreamApiBackend: undefined } as unknown as AIModel;

beforeEach(() => {
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
});

describe('BOARD-OPTIONS-01 to 05 five forms (inputs go through the production form functions)', () => {
  it('BOARD-OPTIONS-01 official BYOK: web toggle + reasoning tiers + vision available + files native per allowlist', () => {
    const out = modelOptionsPanelModel(facts({
      file: { line: { transport: 'openai_responses', exact: true }, nativeFileMimes: [PDF, DOCX], pdfNativeDefault: false },
    }));
    expect(board(out)).toEqual(['web:switch', 'reasoning:levels', 'vision:check', 'file:check']);
    expect(statuses(out)).toEqual([
      { key: 'common.modelOptionsWebNote' },
      // The selected tier is auto: the status line shows the tier word.
      { key: 'pages.chat.reasoning.supplierDefault' },
      { key: 'common.modelOptionsVisionAvailable' },
      { key: 'common.modelOptionsFileNativeWhenSupported' },
    ]);
  });

  it('BOARD-OPTIONS-02 relay: reasoning Chat toggle first, web not possible but tappable, vision unknown, files converted to text', async () => {
    const relay = provider({
      id: 'relay-1', kind: 'relay', baseURLText: 'https://relay.example/v1',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' } as never,
    });
    const relayModel = createRelayManualModel('relay-model', true);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), relay.id);
    const line = await resolveAttachmentLine({ provider: relay, model: relayModel });
    const out = modelOptionsPanelModel(facts({
      connection: 'custom',
      web: capability({ capability: 'web', status: 'unknown', connection: 'custom' }),
      reasoning: capability({ status: 'unknown', connection: 'custom', supportsChatTemplate: true }),
      vision: visionCardFacts(relay, relayModel, { image: true, nativeFile: false, textFileInline: true }),
      file: { line, nativeFileMimes: relayModel.nativeFileMimes ?? [], pdfNativeDefault: false },
    }));
    expect(board(out)).toEqual(['reasoning:switch', 'web:chevron', 'vision:question', 'file:check']);
    expect(out.tiles[1]).toMatchObject({ kind: 'capability', action: 'switchConnection' });
    expect(statuses(out)).toEqual([
      { key: 'common.modelOptionsTemplateThinkingNote' },
      modelOptionDisclosureStatusCopy({ kind: 'cannotDoOnThisConnection' }, 'web'),
      { key: 'common.modelOptionsVisionUnknown' },
      { key: 'common.modelOptionsFileText' },
    ]);
  });

  it('BOARD-OPTIONS-05 subscription: no reasoning tier selected -> the status line uses the top-right status sentence of that form; web missing capability is tappable; files native per allowlist', async () => {
    const line = await resolveAttachmentLine({
      provider: provider({ kind: 'openAI', authMode: 'subscription' } as Partial<Provider>), model: fileModel,
    });
    const out = modelOptionsPanelModel(facts({
      web: capability({ capability: 'web', status: 'unsupported' }),
      reasoning: capability({ availableIntents: ['low', 'balanced', 'deep'] }),
      file: { line, nativeFileMimes: [PDF], pdfNativeDefault: false },
    }));
    expect(board(out)).toEqual(['web:chevron', 'reasoning:levels', 'vision:check', 'file:check']);
    expect(statuses(out)).toEqual([
      modelOptionDisclosureStatusCopy({ kind: 'modelLacksCapability' }, 'web'),
      { key: 'common.modelOptionsUsesModelDefault' },
      { key: 'common.modelOptionsVisionAvailable' },
      { key: 'common.modelOptionsFileNativeWhenSupported' },
    ]);
  });
});

describe('BOARD-OPTIONS-06 protocol undetermined', () => {
  it('BOARD-OPTIONS-06 both rows undetermined -> only a full-width callout, no four cards, no summary bar', () => {
    const out = modelOptionsPanelModel(facts({
      connection: 'custom',
      web: capability({ capability: 'web', status: 'unknown', connection: 'custom', protocolUndecided: true, selectedIntent: 'automatic' }),
      reasoning: capability({ status: 'unknown', connection: 'custom', protocolUndecided: true }),
    }));
    expect(out.card).toEqual({ kind: 'protocolUndecided', link: 'openConnectionProtocol' });
    expect(out.tiles).toEqual([]);
    expect(out.summary).toEqual([]);
  });

  it('BOARD-OPTIONS-06 only one row undetermined -> that card is drawn as a note card: status line = callout title, small text = body, whole card tappable', () => {
    const out = modelOptionsPanelModel(facts({
      web: capability({ capability: 'web', protocolUndecided: true }),
    }));
    expect(board(out)).toEqual(['web:chevron', 'reasoning:levels', 'vision:check', 'file:check']);
    const tile = out.tiles[0]!;
    expect(tile).toMatchObject({ kind: 'capability', action: 'openConnectionProtocol' });
    expect(modelOptionsTileStatusCopy(tile)).toEqual({ key: 'common.modelOptionsChooseProtocolFirst' });
    expect(modelOptionsTileBodyCopy(tile)).toEqual({ key: 'common.modelOptionsProtocolAutoNote' });
  });
});

describe('BOARD-OPTIONS-07 summary bar', () => {
  const summaryOf = (overrides: Partial<ModelOptionsPanelFacts>) => modelOptionsPanelModel(facts(overrides)).summary;

  it('BOARD-OPTIONS-07 web on + reasoning set to a non-auto tier -> two items, web always first', () => {
    const summary = summaryOf({
      web: capability({ capability: 'web', availableIntents: ['off', 'automatic'], selectedIntent: 'automatic' }),
      reasoning: capability({ availableIntents: ['automatic', 'off', 'low', 'deep'], selectedIntent: 'deep' }),
    });
    expect(summary).toEqual([{ kind: 'webOn' }, { kind: 'thinkingLevel', intent: 'deep' }]);
    expect(summary.map(modelOptionsSummaryItemCopy)).toEqual([
      { key: 'common.modelOptionsSummaryWebOn' },
      { key: 'common.modelOptionsSummaryThinkingLevel', args: { level: { key: 'pages.chat.reasoning.deep' } } },
    ]);
  });

  it('BOARD-OPTIONS-07 web timing segment (on) + reasoning toggle on -> "Web on · Reasoning on"', () => {
    expect(summaryOf({
      web: capability({ capability: 'web', availableIntents: ['off', 'automatic', 'force'], selectedIntent: 'force' }),
      reasoning: capability({ availableIntents: ['off', 'deep'], selectedIntent: 'deep' }),
    })).toEqual([{ kind: 'webOn' }, { kind: 'thinkingOn' }]);
  });

  it('BOARD-OPTIONS-07 reasoning set to "Off" is also a real outbound item -> "Thinking: Off"', () => {
    const summary = summaryOf({ reasoning: capability({ availableIntents: ['automatic', 'off', 'low'], selectedIntent: 'off' }) });
    expect(summary).toEqual([{ kind: 'thinkingLevel', intent: 'off' }]);
    expect(modelOptionsSummaryItemCopy(summary[0]!)).toEqual({
      key: 'common.modelOptionsSummaryThinkingLevel', args: { level: { key: 'pages.chat.reasoning.off' } },
    });
  });

  it('BOARD-OPTIONS-07 chat template toggle on: the order of cards (reasoning placed before) does not affect the summary order', () => {
    expect(summaryOf({
      connection: 'custom',
      web: capability({ capability: 'web', status: 'unknown', connection: 'custom' }),
      reasoning: capability({ status: 'unknown', connection: 'custom', supportsChatTemplate: true, chatTemplateThinkingIsOn: true }),
    })).toEqual([{ kind: 'thinkingOn' }]);
  });

  it('BOARD-OPTIONS-07 web off, reasoning auto -> no items at all, no bar', () => {
    expect(summaryOf({})).toEqual([]);
  });
});

describe('BOARD-OPTIONS-08 three file states', () => {
  const fileState = (file: ModelOptionsFileFacts) => modelOptionsTiles({
    card: { kind: 'rows', rows: [] }, vision: VISIBLE, file, generationRows: [],
  }).tiles.find((tile) => tile.kind === 'file');

  it('BOARD-OPTIONS-08 wire cannot be determined / not resolved yet / wire off / no native allowlist -> converted to text', () => {
    expect(fileState({ nativeFileMimes: [PDF], pdfNativeDefault: true })).toEqual({ kind: 'file', state: 'text', corner: 'check' });
    expect(fileState({ line: { transport: 'openai_compatible_chat', exact: false }, nativeFileMimes: [PDF], pdfNativeDefault: true })?.state).toBe('text');
    expect(fileState({ line: { transport: 'openai_chat', exact: true }, nativeFileMimes: [PDF], pdfNativeDefault: true })?.state).toBe('text');
    expect(fileState({ line: { transport: 'openai_responses', exact: true }, nativeFileMimes: [], pdfNativeDefault: true })?.state).toBe('text');
  });

  it('BOARD-OPTIONS-08 pdfNativeDefault -> PDF native; otherwise -> supported formats native', () => {
    const line = { transport: 'anthropic_messages' as const, exact: true };
    expect(fileState({ line, nativeFileMimes: [PDF], pdfNativeDefault: true })?.state).toBe('pdfNative');
    expect(fileState({ line, nativeFileMimes: [PDF], pdfNativeDefault: false })?.state).toBe('nativeWhenSupported');
  });

  it('BOARD-OPTIONS-08 Relay file negative cache not expired -> production wire resolution gives off -> converted to text', async () => {
    const relayModel = { ...createRelayManualModel('gpt-file', true), relayTransport: 'openai_responses', nativeFileMimes: [PDF] } as AIModel;
    const relay = provider({
      id: 'relay-file', kind: 'relay', baseURLText: 'https://relay.example/v1',
      relayRequested: { transport: 'openai_responses', authMode: 'bearer' } as never,
    });
    // Same inputs as the pre-send check: the stream options computed from intent decide the Relay effective protocol.
    const streamOptions = buildProviderStreamOptions(relay, buildStreamOptionsFromIntent(relayModel, 'automatic', false), relayModel);
    const before = await resolveAttachmentLine({ provider: relay, model: relayModel, streamOptions });
    expect(fileState({ line: before, nativeFileMimes: [PDF], pdfNativeDefault: false })?.state).toBe('nativeWhenSupported');
    // The file negative cache only recognizes v2: record one against the production write target (the same stream options as the wire resolution).
    const fileTarget = inputNegativeCacheTarget(relay, relayModel, streamOptions, 'file_input')!;
    recordInputNegativeCache(fileTarget.key, { signatureId: 'test.rejected', verdictRevision: fileTarget.verdictRevision });
    const after = await resolveAttachmentLine({ provider: relay, model: relayModel, streamOptions });
    expect(fileState({ line: after, nativeFileMimes: [PDF], pdfNativeDefault: false })?.state).toBe('text');
  });
});

describe('BOARD-OPTIONS-09 three vision states', () => {
  const visionOf = (vision: ModelOptionsVisionFacts) => modelOptionsTiles({
    card: { kind: 'rows', rows: [] }, vision, file: TEXT_FILE, generationRows: [],
  }).tiles.find((tile) => tile.kind === 'vision');

  it('BOARD-OPTIONS-09 entry not visible -> unavailable; visible + no positive evidence -> unknown (same rule for official and Relay); other visible -> available', () => {
    expect(visionOf({ entryVisible: false, isRelayForm: true, noPositiveEvidence: true })).toEqual({ kind: 'vision', state: 'hidden', corner: 'x' });
    expect(visionOf({ entryVisible: true, isRelayForm: true, noPositiveEvidence: true })).toEqual({ kind: 'vision', state: 'unknown', corner: 'question' });
    expect(visionOf({ entryVisible: true, isRelayForm: true, noPositiveEvidence: false })).toEqual({ kind: 'vision', state: 'available', corner: 'check' });
    // Same rule for official providers: unknown is not supported.
    expect(visionOf({ entryVisible: true, isRelayForm: false, noPositiveEvidence: true })?.state).toBe('unknown');
  });

  it('BOARD-OPTIONS-09 official vision projection unknown -> the vision card does not show "available", and the projection is carried through as is', () => {
    const official = provider({ id: 'official-vision', kind: 'openAI' });
    const model = { id: 'official-vision-unknown', capabilities: ['text'] } as unknown as AIModel;
    const vision = visionCardFacts(official, model, { image: true, nativeFile: false, textFileInline: true });
    expect(vision.projection?.visible).toBe(false);
    const tile = visionOf(vision);
    expect(tile?.state).toBe('unknown');
    expect(modelOptionsTileStatusCopy(tile!)).not.toEqual({ key: 'common.modelOptionsVisionAvailable' });
  });

  it('BOARD-OPTIONS-09 vision projection: Relay with no evidence or only a raw declaration -> unknown; a user override of add -> available; image negative cache -> unavailable', () => {
    const relay = provider({
      id: 'relay-vision', kind: 'relay', baseURLText: 'https://relay.example/v1',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' } as never,
    });
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), relay.id);
    const support = { image: true, nativeFile: false, textFileInline: true };
    // The vision card reads the vision projection: editable decides visibility, visible decides "unknown" (the same production function as the panel and the model library row).
    const factsOf = (relayModel: AIModel): ModelOptionsVisionFacts => visionCardFacts(relay, relayModel, support);
    const unknownModel = createRelayManualModel('vision-unknown', true);
    expect(visionOf(factsOf(unknownModel))?.state).toBe('unknown');
    // An image bit in the catalog capabilities is only a raw declaration and the projection stays unknown; only a user override of "can see images" (add) lights it up.
    const declared = { ...createRelayManualModel('vision-declared', true), capabilities: ['text', 'image'] } as AIModel;
    expect(visionOf(factsOf(declared))?.state).toBe('unknown');
    const userAdded = {
      ...createRelayManualModel('vision-user-added', true),
      relayCapabilityOverrides: { image: { value: true, source: 'user' } },
    } as AIModel;
    expect(visionOf(factsOf(userAdded))?.state).toBe('available');
    const imageTarget = inputNegativeCacheTarget(
      relay, unknownModel,
      buildProviderStreamOptions(relay, buildStreamOptionsFromIntent(unknownModel, 'automatic', false), unknownModel),
      'vision_input',
    )!;
    recordInputNegativeCache(imageTarget.key, { signatureId: 'test.rejected', verdictRevision: imageTarget.verdictRevision });
    expect(visionOf(factsOf(unknownModel))?.state).toBe('hidden');
  });
});

describe('BOARD-OPTIONS-10 parameter card temperature row', () => {
  const llama = localEngineGenerationProfile('llamacpp', undefined)!;
  const scope = { providerId: 'p1', modelId: 'm1', conversationId: 'c1' };
  const rows = () => generationParameterRows({
    parameterIds: llama.parameters.map((parameter) => parameter.id),
    profile: llama,
    resolved: resolveGenerationParameterOverridesWithSources(scope),
    editingLayers: ['transient', 'conversation'],
  });

  it('BOARD-OPTIONS-10 production row model has temperature -> the temperature row carries the value, the capsule no longer lists temperature', () => {
    saveGenerationParameterOverrides(scope, {
      temperature: { state: 'value', value: 0.7 }, top_k: { state: 'value', value: 20 },
    } as never);
    const out = modelOptionsPanelModel(facts({ generationRows: rows() }));
    expect(out.temperature).toMatchObject({ id: 'temperature', displayValue: { kind: 'text', text: '0.7' } });
    expect(out.parameters.chips.map((chip) => chip.id)).toEqual(['top_k']);
    expect(out.parameters.moreCount).toBe(0);
  });

  it('BOARD-OPTIONS-10 temperature has no value -> the temperature row still appears (showing the existing default copy of that row); model has no temperature row -> not shown', () => {
    const unset = modelOptionsPanelModel(facts({ generationRows: rows() }));
    expect(unset.temperature?.id).toBe('temperature');
    expect(unset.temperature?.displayValue ?? unset.temperature?.unsetLabel).toBeTruthy();
    const without = modelOptionsPanelModel(facts({ generationRows: rows().filter((row) => row.id !== 'temperature') }));
    expect(without.temperature).toBeUndefined();
  });
});
