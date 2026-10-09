/**
 * Reconciles the shared contract's `resolverCases` and `relayWireRoundTrips` with the web client:
 * every case that the production resolver / writer can prove is run; cases without a matching
 * production path on web are skipped with a registered reason (not an omission, see SKIPPED).
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import { guardAnthropicThinking } from '@oriveo/core/providers/request-builders/anthropic-thinking';
import { writeGenerationParameters } from '@oriveo/core/providers/request-builders/generation-parameters';
import type {
  GenerationParameterOverride,
  GenerationParameterProfile,
} from '@oriveo/core/providers/request-builders/types';
import {
  resolveGenerationParameterOverridesWithSources,
  saveGenerationParameterOverrides,
  type GenerationParameterScope,
} from '../generation-parameter-settings';
import { decideGenerationParameterRejection } from '../generation-parameter-rejection';

type Layer = { scope: string; override: GenerationParameterOverride };
type ResolverCase = {
  caseId: string;
  status?: number;
  streamStarted?: boolean;
  sideEffects?: boolean;
  locator?: { pointers: string[]; errorFields: Record<string, string> };
  support?: string;
  layers?: Layer[];
  activeKeys?: string[];
  expect: Record<string, unknown>;
};

const cases = JSON.parse(readFileSync(resolve(
  process.cwd(),
  '../../..',
  'shared/model-contracts/generation_parameter_contract.v1.cases.json',
), 'utf8')) as { resolverCases: ResolverCase[]; relayWireRoundTrips: Array<Record<string, unknown>> };

const SCOPE: GenerationParameterScope = { providerId: 'relay-contract', modelId: 'model-a' };
const PARAMETER = 'temperature';

const profileOf = (parameters: GenerationParameterProfile['parameters']): GenerationParameterProfile => ({
  template: 'openai_chat_completions',
  wire: Object.fromEntries(parameters.map((parameter) => [parameter.id, parameter.id])),
  parameters,
});
const param = (id: string, extra: Partial<GenerationParameterProfile['parameters'][number]> = {}) => ({
  id, support: 'supported', source: 'relay_declared', valueSchema: 'number', ...extra,
});

/** Contract layer name → web storage layer; single_send goes through the resolver's transient argument and is never stored. */
function resolveLayers(layers: readonly Layer[]) {
  let transient: Record<string, GenerationParameterOverride> | undefined;
  for (const layer of layers) {
    if (layer.scope === 'single_send') transient = { [PARAMETER]: layer.override };
    else if (layer.scope === 'conversation_connection_model') saveGenerationParameterOverrides({ ...SCOPE, conversationId: 'c1' }, { [PARAMETER]: layer.override });
    else if (layer.scope === 'connection_model') saveGenerationParameterOverrides(SCOPE, { [PARAMETER]: layer.override });
    // provider_default inherit means nobody wrote anything, so nothing is stored.
  }
  return resolveGenerationParameterOverridesWithSources({ ...SCOPE, conversationId: 'c1', ...(transient ? { transient } : {}) });
}

const LAYER_NAMES: Readonly<Record<string, string>> = {
  transient: 'single_send',
  conversation: 'conversation_connection_model',
  connectionModel: 'connection_model',
};

/**
 * The four upstream parameter-rejection cases: the write fact comes from the production writer
 * (the panel set temperature and it really went into the request body), the handling goes through
 * the production decision function, and every field listed in the contract's expect is matched.
 */
function rejectionCase(testCase: ResolverCase): void {
  const profile = profileOf([param(PARAMETER)]);
  const body: Record<string, unknown> = {};
  const { written } = writeGenerationParameters(body as never, { [PARAMETER]: { state: 'value', value: 0.7 } }, profile);
  expect(written).toEqual([PARAMETER]);
  const decision = decideGenerationParameterRejection({
    status: testCase.status,
    streamStarted: testCase.streamStarted === true,
    sideEffects: testCase.sideEffects === true,
    ...(testCase.locator ? { errorFields: testCase.locator.errorFields } : {}),
    written,
    wire: profile.wire,
  });
  expect(decision).toMatchObject(testCase.expect);
  if (testCase.locator) {
    // The located parameter is the wire field the contract's pointers refer to.
    expect(testCase.locator.pointers).toEqual([`/${profile.wire[decision.parameterId!]}`]);
  } else {
    expect(decision.parameterId).toBeUndefined();
  }
}

const HANDLERS: Readonly<Record<string, (testCase: ResolverCase) => void>> = {
  exact_structured_400_before_stream_requires_explicit_resend: rejectionCase,
  unlocated_400_surfaces_without_learning: rejectionCase,
  // 422 and an already-started stream: no recovery path even if the error body names the parameter we wrote.
  status_422_does_not_self_heal: (testCase) => {
    rejectionCase(testCase);
    expect(decideGenerationParameterRejection({
      status: testCase.status, streamStarted: false, sideEffects: false,
      errorFields: { '/error/param': PARAMETER }, written: [PARAMETER],
    }).action).toBe('surface_error');
  },
  started_stream_never_retries: (testCase) => {
    rejectionCase(testCase);
    expect(decideGenerationParameterRejection({
      status: testCase.status, streamStarted: true, sideEffects: false,
      errorFields: { '/error/param': PARAMETER }, written: [PARAMETER],
    }).action).toBe('surface_error');
  },
  inherit_then_omit_blocks_lower: (testCase) => {
    const entry = resolveLayers(testCase.layers!)?.[PARAMETER];
    expect(entry?.override.state).toBe(testCase.expect.state);
    expect(LAYER_NAMES[entry!.layer]).toBe(testCase.expect.source);
    // Outbound: an explicit "do not send" blocks the 0.5 from the layer below
    const body: Record<string, unknown> = {};
    writeGenerationParameters(body as never, { [PARAMETER]: entry!.override }, profileOf([param(PARAMETER)]));
    expect(body).not.toHaveProperty(PARAMETER);
  },
  zero_is_not_missing: (testCase) => {
    const entry = resolveLayers(testCase.layers!)?.[PARAMETER];
    expect(entry?.override).toEqual({ state: testCase.expect.state, value: testCase.expect.value });
    expect(LAYER_NAMES[entry!.layer]).toBe(testCase.expect.source);
    const body: Record<string, unknown> = {};
    writeGenerationParameters(body as never, { [PARAMETER]: entry!.override }, profileOf([param(PARAMETER)]));
    expect(body[PARAMETER]).toBe(0);
  },
  unknown_requires_explicit_value: (testCase) => {
    const resolved = resolveLayers(testCase.layers!);
    expect(resolved?.[PARAMETER]).toBeUndefined();
    const body: Record<string, unknown> = {};
    const result = writeGenerationParameters(body as never, undefined, profileOf([param(PARAMETER, { support: testCase.support })]));
    // On web, "omit" means the parameter is not written; the contract's reason code has no counterpart here (without a value there is no drop to report).
    expect(body).not.toHaveProperty(PARAMETER);
    expect(result.written).toEqual([]);
  },
  tools_conflict_json_schema: (testCase) => {
    expect(testCase.activeKeys).toEqual(['tools', 'json_schema']);
    const body: Record<string, unknown> = {};
    const result = writeGenerationParameters(
      body as never,
      { json_schema: { state: 'value', value: { name: 'out', schema: { type: 'object' } } } },
      { ...profileOf([param('json_schema', { valueSchema: 'json-schema', conflictsWith: ['tools'] })]), wire: { json_schema: 'response_format' } },
      { toolsActive: true },
    );
    expect(result.dropped).toEqual([{ parameterId: 'json_schema', reason: testCase.expect.reason }]);
    expect(body).not.toHaveProperty('response_format');
  },
  reasoning_disables_sampling: (testCase) => {
    // On web, the production criterion for "reasoning is on" is the Anthropic thinking guard; the contract's constraint maps to web's thinking_incompatible.
    const profile = { ...profileOf([param('temperature')]), template: 'anthropic_messages' };
    const body: Record<string, unknown> = { thinking: { type: 'enabled', budget_tokens: 1024 }, max_tokens: 4096 };
    const { written } = writeGenerationParameters(body as never, { temperature: { state: 'value', value: 0.7 } }, profile);
    const dropped = guardAnthropicThinking(body, { profile, written, builderDefaultMaxTokens: 4096 });
    expect(dropped.map((item) => item.parameterId)).toEqual(testCase.expect.omitted);
    expect(dropped.every((item) => item.reason === 'thinking_incompatible')).toBe(true);
    expect(body).not.toHaveProperty('temperature');
  },
};

/** Cases with no production path on web: each reason is spelled out, and a new case with neither a handler nor an entry here fails. */
const SKIPPED: Readonly<Record<string, string>> = {
  // Override values are not keyed by fingerprint (the fingerprint is only a record attribute), so after a revision
  // change every value is still read back and "portable preservation" already holds
  // (see "records are still readable after the fingerprint changes" in generation-parameter-settings.test.ts).
  // The other half is what is missing.
  engine_revision_change_invalidates: 'No client implements "invalidate as soon as the revision changes". The behavior follows lifecycleRules: if the new profile still declares the parameter it is sent as before; if it no longer does, the setting is shown as preserved but inactive, the value is kept, and it recovers automatically when a profile declares it again. Stopping a still-declared parameter only because the revision number changed would silently disable a setting without the user doing anything',
  unknown_profile_enum_preserved: 'When web decodes a profile, enums such as support pass through as plain strings; there is no explicit decode result object for "unknown + preserved raw value"',
  'relayWireRoundTrips:openai_chat/none': 'Web stores the relay transport / authMode as plain strings; there is no round-trip function that encodes and decodes the wire format',
  'relayWireRoundTrips:future_transport/future_auth': 'Same as above',
};

describe('shared contract resolverCases (web)', () => {
  beforeEach(() => localStorage.clear());

  it('every case has either a handler or a registered skip reason', () => {
    const ids = [
      ...cases.resolverCases.map((testCase) => testCase.caseId),
      ...cases.relayWireRoundTrips.map((trip) => `relayWireRoundTrips:${String(trip.transportKind)}/${String(trip.authMode)}`),
    ];
    expect(ids.filter((id) => !HANDLERS[id] && !SKIPPED[id])).toEqual([]);
    expect(cases.resolverCases).toHaveLength(11);
    expect(cases.relayWireRoundTrips).toHaveLength(2);
  });

  for (const testCase of cases.resolverCases) {
    const handler = HANDLERS[testCase.caseId];
    if (handler) it(testCase.caseId, () => handler(testCase));
    else it.skip(`${testCase.caseId} (${SKIPPED[testCase.caseId] ?? 'not registered'})`, () => {});
  }
  for (const trip of cases.relayWireRoundTrips) {
    const id = `relayWireRoundTrips:${String(trip.transportKind)}/${String(trip.authMode)}`;
    it.skip(`${id} (${SKIPPED[id] ?? 'not registered'})`, () => {});
  }
});
