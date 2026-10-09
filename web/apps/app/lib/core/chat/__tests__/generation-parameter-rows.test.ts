/**
 * Generation parameter row model: the three source tiers, display values, drop reasons (the same decision as outbound), takeover, and summary.
 */
import { beforeEach, describe, expect, it } from 'vitest';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import type { StreamOptions } from '@oriveo/core/providers/types';
import type { GenerationParameterOverrides, GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import {
  resolveGenerationParameterOverrides,
  resolveGenerationParameterOverridesWithSources,
  saveConnectionGenerationParameterDefaults,
  saveGenerationParameterOverrides,
} from '../generation-parameter-settings';
import { generationParameterRows, generationParameterSummary, type GenerationParameterRowsInput } from '../generation-parameter-rows';
import { localEngineGenerationProfile } from '../local-engine-profiles';

const v = (value: unknown) => ({ state: 'value', value }) as never;
const omit = { state: 'omit' } as const;
const conv = { providerId: 'p1', modelId: 'm1', conversationId: 'c1' };
const llama = localEngineGenerationProfile('llamacpp', undefined)!;

function rows(input: Partial<GenerationParameterRowsInput> & Pick<GenerationParameterRowsInput, 'parameterIds' | 'profile'>) {
  return generationParameterRows({ resolved: undefined, editingLayers: ['transient', 'conversation'], ...input });
}

function flatten(resolved: ReturnType<typeof resolveGenerationParameterOverridesWithSources>): GenerationParameterOverrides {
  return Object.fromEntries(Object.entries(resolved ?? {}).map(([id, entry]) => [id, entry.override]));
}

async function relayBody(
  transport: NonNullable<StreamOptions['relayTransport']>,
  profile: GenerationParameterProfile,
  generationParameters: GenerationParameterOverrides,
): Promise<Record<string, unknown>> {
  let captured: Record<string, unknown> | undefined;
  const deps: RelayOrchestratorDeps = {
    transport: {
      fetch: async (_url, init) => {
        captured = JSON.parse(String(init.body)) as Record<string, unknown>;
        return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
  const handle = sendRelayStream('key', 'm1', [{ role: 'user', content: 'hello' }], 'https://relay.example', {
    relayTransport: transport, relayAuthMode: 'bearer', relayStream: false, generationProfile: profile, generationParameters,
  }, deps);
  await handle.stream.getReader().read();
  return captured!;
}

/** Parameters that have a value but are absent from the real request body. */
function absentFromBody(body: Record<string, unknown>, profile: GenerationParameterProfile, values: GenerationParameterOverrides): string[] {
  return Object.entries(values)
    .filter(([id, item]) => item?.state === 'value' && !(profile.wire[id] in body))
    .map(([id]) => id).sort();
}

beforeEach(() => localStorage.clear());

describe('resolution with sources', () => {
  it('each of the four layers is tagged with its source, and the legacy function result is unchanged', () => {
    saveGenerationParameterOverrides(conv, { temperature: v(0.3) });
    saveGenerationParameterOverrides({ providerId: 'p1', modelId: 'm1' }, { top_p: v(0.9), temperature: v(0.1) });
    saveConnectionGenerationParameterDefaults('p1', { top_k: v(20) });
    const input = { ...conv, transient: { seed: v(7) } };
    const sourced = resolveGenerationParameterOverridesWithSources(input);
    expect(Object.fromEntries(Object.entries(sourced ?? {}).map(([id, entry]) => [id, entry.layer]))).toEqual({
      seed: 'transient', temperature: 'conversation', top_p: 'connectionModel', top_k: 'connection',
    });
    expect(flatten(sourced)).toEqual(resolveGenerationParameterOverrides(input));
  });
});

describe('row model', () => {
  it('three source tiers plus standing', () => {
    saveGenerationParameterOverrides(conv, { temperature: v(0.3) });
    saveGenerationParameterOverrides({ providerId: 'p1', modelId: 'm1' }, { top_p: v(0.9) });
    const resolved = resolveGenerationParameterOverridesWithSources(conv);
    const out = rows({ parameterIds: ['temperature', 'top_p', 'top_k'], profile: llama, resolved });
    expect(out.map((row) => [row.id, row.source, row.standing])).toEqual([
      ['temperature', 'changedInConversation', 'editedHere'],
      ['top_p', 'modelDefault', 'inherited'],
      ['top_k', 'decidedByModel', 'unset'],
    ]);
    expect(out[0].displayValue).toEqual({ kind: 'text', text: '0.3' });
    expect(out[2].displayValue).toEqual({ kind: 'text', text: '40' });
  });

  it('do-not-send: isOmitted, trailing is omitted, and there is no display value', () => {
    const out = rows({ parameterIds: ['temperature'], profile: llama, resolved: { temperature: { override: omit, layer: 'conversation' } } });
    expect([out[0].isOmitted, out[0].displayValue, out[0].unsetLabel, out[0].dropReason]).toEqual([true, undefined, 'omitted', undefined]);
  });

  it('placeholder words are not shown as values, and a max output of -1 shows as no limit', () => {
    const profile: GenerationParameterProfile = {
      template: 'openai_chat_completions', wire: { temperature: 'temperature', top_p: 'top_p' },
      parameters: [
        { id: 'temperature', support: 'supported', source: 't', defaultDescription: 'provider_default' },
        { id: 'top_p', support: 'supported', source: 't', defaultDescription: 'unknown' },
      ],
    };
    const out = rows({ parameterIds: ['temperature', 'top_p'], profile, resolved: undefined });
    expect(out.map((row) => [row.displayValue, row.engineDefault, row.unsetLabel])).toEqual([
      [undefined, undefined, 'modelDefault'], [undefined, undefined, 'modelDefault'],
    ]);
    const max = rows({ parameterIds: ['max_output_tokens'], profile: llama, resolved: undefined })[0];
    expect([max.displayValue, max.engineDefault]).toEqual([{ kind: 'noLimit' }, { kind: 'noLimit' }]);
  });

  it('four kinds of unsetLabel', () => {
    const out = rows({ parameterIds: ['seed', 'stop', 'json_schema', 'top_logprobs'], profile: llama, resolved: undefined });
    expect(out.map((row) => row.unsetLabel)).toEqual(['randomEachTime', 'notSet', 'plainText', 'modelDefault']);
  });

  it('out of range -> invalid_value + aboveMaximum; the range gives both bounds', () => {
    const out = rows({ parameterIds: ['top_p'], profile: llama, resolved: { top_p: { override: v(1.5), layer: 'transient' } } });
    expect([out[0].dropReason, out[0].validationIssue, out[0].allowedRange]).toEqual([
      'invalid_value', { kind: 'aboveMaximum', limit: 1 },
      { lower: { value: 0, open: false }, upper: { value: 1, open: false } },
    ]);
  });

  it('precondition partners and required fields are not sent', () => {
    const profile: GenerationParameterProfile = {
      template: 'anthropic_messages', wire: { max_output_tokens: 'max_tokens', top_logprobs: 'top_logprobs', logprobs: 'logprobs' },
      parameters: [
        { id: 'max_output_tokens', support: 'supported', source: 't', valueSchema: 'integer' },
        { id: 'logprobs', support: 'supported', source: 't', valueSchema: 'boolean' },
        { id: 'top_logprobs', support: 'supported', source: 't', valueSchema: 'integer', requires: [{ key: 'logprobs', value: true }] },
      ],
    };
    const out = rows({
      parameterIds: ['max_output_tokens', 'top_logprobs'], profile,
      resolved: { max_output_tokens: { override: omit, layer: 'conversation' }, top_logprobs: { override: v(3), layer: 'conversation' } },
    });
    expect(out.map((row) => [row.dropReason, row.requirementPartnerId])).toEqual([
      ['required_field', undefined], ['requirement_unmet', 'logprobs'],
    ]);
  });

  it('Mirostat takes over top_k / top_p; no takeover when the family head is dropped; a taken-over row gets no drop reason', () => {
    const take = rows({ parameterIds: ['mirostat', 'top_k', 'top_p', 'temperature'], profile: llama, resolved: {
      mirostat: { override: v(2), layer: 'conversation' }, top_k: { override: v(50), layer: 'conversation' },
      top_p: { override: v(1.5), layer: 'conversation' },
    } });
    expect(take.map((row) => [row.id, row.supersededById, row.dropReason])).toEqual([
      ['mirostat', undefined, undefined], ['top_k', 'mirostat', undefined], ['top_p', 'mirostat', undefined], ['temperature', undefined, undefined],
    ]);
    const dropped = rows({ parameterIds: ['mirostat', 'top_k'], profile: llama, resolved: {
      mirostat: { override: v(3), layer: 'conversation' }, top_k: { override: v(50), layer: 'conversation' },
    } });
    expect(dropped.map((row) => [row.supersededById, row.dropReason])).toEqual([[undefined, 'invalid_value'], [undefined, undefined]]);
    const off = rows({ parameterIds: ['top_k'], profile: llama, resolved: {
      mirostat: { override: v(0), layer: 'conversation' }, top_k: { override: v(50), layer: 'conversation' },
    } });
    expect(off[0].supersededById).toBeUndefined();
  });

  it('fallback value and model default: a lower layer wins when it provides one, otherwise the engine default is used', () => {
    const out = rows({
      parameterIds: ['temperature', 'top_k'], profile: llama,
      resolved: { temperature: { override: v(0.3), layer: 'conversation' }, top_k: { override: v(5), layer: 'conversation' } },
      lowerValues: { temperature: v(0.6) },
    });
    expect(out.map((row) => [row.fallbackValue, row.modelDefaultValue, row.engineDefault])).toEqual([
      [{ kind: 'text', text: '0.6' }, { kind: 'text', text: '0.6' }, { kind: 'text', text: '0.8' }],
      [{ kind: 'text', text: '40' }, undefined, { kind: 'text', text: '40' }],
    ]);
  });

  it('summary: counts only rows changed in this conversation and effective, at most 2 chips plus N more', () => {
    const out = rows({ parameterIds: ['temperature', 'top_p', 'top_k', 'seed', 'min_p', 'typical_p'], profile: llama, resolved: {
      temperature: { override: v(0.3), layer: 'conversation' }, top_p: { override: v(1.5), layer: 'transient' },
      top_k: { override: v(9), layer: 'connectionModel' }, seed: { override: v(7), layer: 'conversation' },
      min_p: { override: v(0.1), layer: 'conversation' }, typical_p: { override: omit, layer: 'conversation' },
    } });
    expect(generationParameterSummary(out)).toEqual({
      chips: [{ id: 'temperature', displayValue: { kind: 'text', text: '0.3' } }, { id: 'seed', displayValue: { kind: 'text', text: '7' } }],
      moreCount: 1,
    });
  });
});

describe('production path: the drop set on the rows equals the set absent from the production send path request body', () => {
  it('llama.cpp real parameter table: saved to the production store, read back, and sent out through the Relay send path', async () => {
    saveGenerationParameterOverrides(conv, { top_p: v(1.5), min_p: v(0.1), top_k: v(50), repeat_last_n: v(-3) });
    const resolved = resolveGenerationParameterOverridesWithSources(conv);
    const out = rows({ parameterIds: llama.parameters.map((item) => item.id), profile: llama, resolved });
    const values = flatten(resolved);
    const body = await relayBody('openai_chat_completions', llama, values);
    expect(out.filter((row) => row.dropReason).map((row) => row.id).sort()).toEqual(absentFromBody(body, llama, values));
    expect(absentFromBody(body, llama, values)).toEqual(['repeat_last_n', 'top_p']);
  });

  it('declared conflict: the second item is dropped and its partner is the first; matches the Relay Anthropic send path', async () => {
    const profile: GenerationParameterProfile = {
      template: 'anthropic_messages', wire: { temperature: 'temperature', top_p: 'top_p' },
      parameters: [
        { id: 'temperature', support: 'supported', source: 't', valueSchema: 'number', conflictsWith: ['top_p'] },
        { id: 'top_p', support: 'supported', source: 't', valueSchema: 'number' },
      ],
    };
    saveGenerationParameterOverrides(conv, { temperature: v(0.4), top_p: v(0.9) });
    const resolved = resolveGenerationParameterOverridesWithSources(conv);
    const out = rows({ parameterIds: ['temperature', 'top_p'], profile, resolved });
    expect(out.map((row) => [row.dropReason, row.conflictPartnerId])).toEqual([[undefined, undefined], ['conflict', 'temperature']]);
    const values = flatten(resolved);
    const body = await relayBody('anthropic_messages', profile, values);
    expect(out.filter((row) => row.dropReason).map((row) => row.id)).toEqual(absentFromBody(body, profile, values));
  });
});
