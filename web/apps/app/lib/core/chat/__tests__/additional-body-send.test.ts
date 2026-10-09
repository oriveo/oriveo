/**
 * Browser-side wiring of the additional request body: effective criteria (switch off means not sent), local rejection before sending, library agent legs.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { AdditionalBodyRejectedError } from '@oriveo/core/providers/request-builders/additional-body';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import { additionalBodyScope, saveAdditionalBody, withAdditionalBody } from '../additional-body-settings';
import { sendLibraryAgentLeg } from '../../providers/proxy-client';
import { migrateDraftScopedModelControls } from '../draft-scope-migration';
import { loadAdditionalBody } from '../additional-body-settings';

const anthropic = { id: 'conn-a', kind: 'anthropic', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;
const model = { id: 'claude-sonnet-4-6', name: 'M', capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' } as AIModel;

beforeEach(() => localStorage.clear());
afterEach(() => vi.restoreAllMocks());

describe('withAdditionalBody (last step of outbound options)', () => {
  it('on and valid -> attaches the raw text; off -> not attached', () => {
    saveAdditionalBody(additionalBodyScope(anthropic, model), { raw: '{"top_k":3}', enabled: true });
    expect(withAdditionalBody({ supportsWebSearch: false }, { provider: anthropic, model, conversationId: 'c1' }))
      .toEqual({ supportsWebSearch: false, additionalBody: { raw: '{"top_k":3}' } });
    saveAdditionalBody(additionalBodyScope(anthropic, model), { raw: '{"top_k":3}', enabled: false });
    expect(withAdditionalBody({ supportsWebSearch: false }, { provider: anthropic, model, conversationId: 'c1' }))
      .toEqual({ supportsWebSearch: false });
  });

  it('local rejection before sending: throws a dedicated error carrying the safe code, errorKind and the oriveo origin', () => {
    saveAdditionalBody(additionalBodyScope(anthropic, model), { raw: '{\n"top_k": ,\n}', enabled: true });
    let caught: unknown;
    try { withAdditionalBody(undefined, { provider: anthropic, model }); } catch (error) { caught = error; }
    expect(caught).toBeInstanceOf(AdditionalBodyRejectedError);
    expect(caught).toMatchObject({
      code: 'additional_body_rejected:invalid_json@2', errorKind: 'additionalBodyRejected', kind: 'additionalBodyRejected', source: 'oriveo',
    });
  });
});

describe('library agent leg', () => {
  it('the additional body travels to the route with /api/chat/stream and the production builder on the route merges it as the last step (with tools)', async () => {
    saveAdditionalBody(additionalBodyScope(anthropic, model), { raw: '{"temperature":0.2,"metadata":{"user_id":"u"}}', enabled: true });
    const options = withAdditionalBody({ supportsWebSearch: false }, { provider: anthropic, model, conversationId: 'c1' });
    let posted: Record<string, any> | undefined;
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (_input, init) => {
      posted = JSON.parse(String(init?.body));
      return new Response('data: [DONE]\n\n', { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
    });
    const tools = [{ type: 'function' as const, function: { name: 'search_library', description: 'd', parameters: { type: 'object', properties: {} } } }];
    const handle = sendLibraryAgentLeg('anthropic', 'k', model.id, [{ role: 'user', content: 'hello' }], tools, undefined, options);
    const reader = handle.stream.getReader();
    while (!(await reader.read()).done) { /* drain */ }
    expect(posted?.options?.additionalBody).toEqual({ raw: '{"temperature":0.2,"metadata":{"user_id":"u"}}' });

    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: model.id, baseURL: 'https://contract.invalid/v1',
      messages: posted!.messages, tools: posted!.tools, toolChoice: posted!.toolChoice, options: posted!.options,
    }, async () => loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata);
    expect(request.body.temperature).toBe(0.2);
    expect(request.body.metadata).toEqual({ user_id: 'u' });
    expect(Array.isArray(request.body.tools)).toBe(true);
  });
});

describe('draft conversation -> real conversation', () => {
  const metadata = async () => loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata;

  it('after the first send swaps in the real id, the additional body written under the draft goes out with the first message (the send chain reads finalConvId)', async () => {
    saveAdditionalBody(additionalBodyScope(anthropic, model, 'draft-1'), { raw: '{"top_k":7}', enabled: true });
    migrateDraftScopedModelControls({ provider: anthropic, model, conversation: undefined, draftSessionId: 'draft-1', conversationId: 'conv-real' });
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model, 'draft-1'))).toBeNull();
    const options = withAdditionalBody({ supportsWebSearch: false }, { provider: anthropic, model, conversationId: 'conv-real' });
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: model.id, baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hi' }], options,
    }, metadata);
    expect(request.body.top_k).toBe(7);
  });

  it('when the target scope already has a record the target wins; an existing conversation is not moved', () => {
    saveAdditionalBody(additionalBodyScope(anthropic, model, 'draft-1'), { raw: '{"top_k":7}', enabled: true });
    saveAdditionalBody(additionalBodyScope(anthropic, model, 'conv-real'), { raw: '{"top_k":1}', enabled: false });
    migrateDraftScopedModelControls({ provider: anthropic, model, conversation: undefined, draftSessionId: 'draft-1', conversationId: 'conv-real' });
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model, 'conv-real'))).toMatchObject({ raw: '{"top_k":1}', enabled: false });
  });
});

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}
