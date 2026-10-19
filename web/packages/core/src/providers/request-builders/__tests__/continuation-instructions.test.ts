import { describe, expect, it } from 'vitest';
import { buildProviderRequest } from '../dispatch';
import { mapContinuationForRecipe } from '../continuation-replay';
import { applyToolCallWireAdapter } from '../tool-call-wire-adapter';
import type { RuntimeRecipe } from '../capability-execution';
import type { ProviderRequest, RequestParams } from '../types';
import type { ProxyMessage } from '../runtime';

// The recipe's continuationInstructionsMode and the continuation decision together determine whether previous_response_id / instructions are sent.
const UNCHANGED = { systemChanged: false, modelChanged: false, checkpointChanged: false };
const intent = { kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_prev' } };

function recipe(mode?: unknown): RuntimeRecipe {
  return {
    id: 'fixture.responses.web.v1', providerKind: 'openAI', capability: 'web', executionKind: 'server_tool',
    transport: { protocol: 'openai_responses', endpointClass: 'responses' }, requestOps: [],
    responseParserKind: 'openai_responses_web_v1', continuationKind: 'previous_id',
    ...(mode === undefined ? {} : { continuationInstructionsMode: mode }),
  } as RuntimeRecipe;
}

describe('continuation instructions mode (mapContinuationForRecipe)', () => {
  it('resend: chains previous_response_id and keeps instructions', () => {
    expect(mapContinuationForRecipe(recipe('resend'), intent, UNCHANGED)).toEqual({
      accepted: true, target: 'body', delta: { previous_response_id: 'resp_prev' },
    });
  });

  it('omit: chains previous_response_id and drops instructions', () => {
    expect(mapContinuationForRecipe(recipe('omit'), intent, UNCHANGED)).toEqual({
      accepted: true, target: 'body', delta: { previous_response_id: 'resp_prev' }, omitRoots: ['instructions'],
    });
  });

  it('missing or unknown mode: full plan, no previous_response_id', () => {
    for (const mode of [undefined, 'bogus', 1]) {
      expect(mapContinuationForRecipe(recipe(mode), intent, UNCHANGED)).toEqual({ accepted: true, target: 'body', delta: {} });
    }
  });

  it('missing fingerprint or any change: full plan', () => {
    expect(mapContinuationForRecipe(recipe('resend'), intent)).toEqual({ accepted: true, target: 'body', delta: {} });
    for (const key of ['systemChanged', 'modelChanged', 'checkpointChanged'] as const) {
      expect(mapContinuationForRecipe(recipe('omit'), intent, { ...UNCHANGED, [key]: true }))
        .toEqual({ accepted: true, target: 'body', delta: {} });
    }
  });
});

function metadata(mode: string | undefined): any {
  const webRecipe = {
    ...recipe(mode), id: 'openai.responses.web.v1',
    requestOps: [{ op: 'append', pointer: '/tools/-', value: { type: 'web_search' } }],
  };
  return {
    version: 2, updatedAt: '2026-10-15T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    capabilityRuntime: {
      schemaVersion: 2, revision: 'fixture', generatedAt: '2026-10-15T00:00:00Z',
      recipes: { 'openai.responses.web.v1': webRecipe }, controlDefinitions: {}, sourceIndex: {},
    },
    providers: { openAI: { resolveMap: { 'gpt-5': 'gpt-5' }, models: { 'gpt-5': {
      transport: 'openai_responses',
      capabilityControls: { web: { state: 'auto_available', recipeRef: 'openai.responses.web.v1' } },
    } } } },
  };
}

const chat: RequestParams['messages'] = [
  { role: 'system', content: 'Be brief.' },
  { role: 'user', content: 'earlier' },
  { role: 'assistant', content: 'answer' },
  { role: 'user', content: 'continue' },
];

async function build(mode: string | undefined, fingerprint?: RequestParams['continuationFingerprint']): Promise<ProviderRequest> {
  return buildProviderRequest({
    providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-5', messages: chat,
    options: { supportsWebSearch: true }, continuation: intent,
    ...(fingerprint ? { continuationFingerprint: fingerprint } : {}),
  }, async () => metadata(mode));
}

function inputTexts(body: Record<string, unknown>): string {
  return JSON.stringify(body.input);
}

describe('continuation instructions mode (dispatch)', () => {
  it('resend: previous_response_id is chained', async () => {
    const request = await build('resend', UNCHANGED);
    expect(request.body.previous_response_id).toBe('resp_prev');
    expect(request.continuationCapture?.instructionsMode).toBe('resend');
  });

  it('omit: previous_response_id without instructions', async () => {
    const request = await build('omit', UNCHANGED);
    expect(request.body.previous_response_id).toBe('resp_prev');
    expect(request.continuationCapture?.instructionsMode).toBe('omit');
    expect(request.body).not.toHaveProperty('instructions');
  });

  it('missing mode or fingerprint: full input, no previous_response_id', async () => {
    for (const request of [await build(undefined, UNCHANGED), await build('resend')]) {
      expect(request.body).not.toHaveProperty('previous_response_id');
      expect(inputTexts(request.body)).toContain('earlier');
      expect(inputTexts(request.body)).toContain('answer');
      expect(inputTexts(request.body)).toContain('continue');
    }
  });
});

describe('app-layer continuation decision (app-layer decision)', () => {
  const omit = { kind: 'stateful' as const, previousResponseId: 'resp_prev', sendInstructions: false };

  it('follows the app decision instead of re-deciding from the recipe', () => {
    // The recipe says resend / unconfirmed while the app layer concludes omit: follow the app layer.
    for (const mode of ['resend', undefined]) {
      expect(mapContinuationForRecipe(recipe(mode), intent, undefined, omit)).toEqual({
        accepted: true, target: 'body', delta: { previous_response_id: 'resp_prev' }, omitRoots: ['instructions'],
      });
    }
    expect(mapContinuationForRecipe(recipe('omit'), intent, UNCHANGED, { kind: 'fullPlan' }))
      .toEqual({ accepted: true, target: 'body', delta: {} });
  });

  it('throws when the stateful decision is incompatible with the recipe or state', () => {
    const chatRecipe = { ...recipe('omit'), transport: { protocol: 'openai_chat', endpointClass: 'chat' } } as RuntimeRecipe;
    expect(() => mapContinuationForRecipe(chatRecipe, intent, UNCHANGED, omit)).toThrow(/incompatible with recipe/);
    expect(() => mapContinuationForRecipe(recipe('omit'), intent, UNCHANGED, { ...omit, previousResponseId: 'resp_other' })).toThrow(/does not match the continuation state/);
  });

  it('dispatch throws when a stateful decision has no continuation recipe', async () => {
    await expect(buildProviderRequest({
      providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-5', messages: chat,
      options: {}, continuation: intent, continuationFingerprint: UNCHANGED, continuationDecision: omit,
    }, async () => metadata('omit'))).rejects.toThrow(/no matching continuation recipe/);
  });
});

describe('continuation instructions mode (tool leg)', () => {
  const call = { id: 'call_1', type: 'function' as const, function: { name: 'lookup', arguments: '{}' } };
  const messages: ProxyMessage[] = [
    { role: 'system', content: 'Be brief.' },
    { role: 'user', content: 'question' },
    { role: 'assistant', content: '', tool_calls: [call], providerContinuation: intent },
    { role: 'tool', content: '{"ok":true}', tool_call_id: call.id },
  ];
  const tools = [{ type: 'function' as const, function: { name: 'lookup', description: 'Lookup', parameters: { type: 'object' } } }];

  function leg(mode?: 'resend' | 'omit'): Record<string, unknown> {
    const request: ProviderRequest = {
      url: 'https://api.openai.com/v1/responses', headers: {}, body: { instructions: 'stale' },
      ...(mode ? { continuationCapture: { kind: 'previous_id', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1', instructionsMode: mode } } : {}),
    };
    return applyToolCallWireAdapter(request, { messages, tools, toolChoice: 'auto' }).body;
  }

  it('resend: previous_response_id with instructions, only the new tail', () => {
    const body = leg('resend');
    expect(body.previous_response_id).toBe('resp_prev');
    expect(body.instructions).toBe('Be brief.');
    expect(body.input).toEqual([{ type: 'function_call_output', call_id: 'call_1', output: '{"ok":true}' }]);
  });

  it('omit: previous_response_id without instructions', () => {
    const body = leg('omit');
    expect(body.previous_response_id).toBe('resp_prev');
    expect(body).not.toHaveProperty('instructions');
  });

  it('missing mode: full input replay without previous_response_id', () => {
    const body = leg();
    expect(body).not.toHaveProperty('previous_response_id');
    expect(body.instructions).toBe('Be brief.');
    expect(body.input).toEqual([
      { role: 'user', content: [{ type: 'input_text', text: 'question' }] },
      { type: 'function_call', call_id: 'call_1', name: 'lookup', arguments: '{}' },
      { type: 'function_call_output', call_id: 'call_1', output: '{"ok":true}' },
    ]);
  });
});
