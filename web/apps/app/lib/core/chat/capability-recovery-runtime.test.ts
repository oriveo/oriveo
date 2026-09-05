import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  capabilityRecoveryDescriptorIsCurrent,
  capabilityRejectionIsDormant,
  capabilityRecipeOmissions,
  clearCapabilityRejectionsForConnection,
  decodeCapabilityRecoveryDescriptor,
  encodeCapabilityRecoveryDescriptor,
  invokeCapabilityRecoveryRetry,
  isDeterministicToolCallUnsupported,
  locateCapabilityRecovery,
  recordCapabilityRejection,
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
  clearToolCallMemoryForConnection,
} from './capability-recovery-runtime';

const memory = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => memory.get(key) ?? null,
  setItem: (key: string, value: string) => memory.set(key, value),
});

const identity = {
  connectionId: 'connection-a',
  canonicalModelId: 'model/a',
  finalTransport: 'openai_responses',
  runtimeRevision: 'runtime-r7',
};

const toolCallIdentity = {
  accountId: 'account-a',
  connectionId: 'connection-a',
  authMode: 'apiKey' as const,
  canonicalModelId: 'model/a',
  finalTransport: 'openai_chat',
};

describe('D5 tool-call recovery runtime', () => {
  beforeEach(() => memory.clear());

  it('admits only deterministic structured tool-unsupported 4xx responses', () => {
    expect(isDeterministicToolCallUnsupported({
      status: 400,
      structuredError: { error: { message: 'Unrecognized request argument supplied: tools' } },
    })).toBe(true);
    expect(isDeterministicToolCallUnsupported({
      status: 400,
      structuredError: { error: { message: 'This model does not support function calling' } },
    })).toBe(true);

    for (const context of [
      { status: 401, structuredError: { error: 'tools unsupported' } },
      { status: 403, structuredError: { error: 'tools not allowed' } },
      { status: 422, structuredError: { detail: [{ loc: ['body', 'tools'], msg: 'Extra inputs are not permitted' }] } },
      { status: 429, structuredError: { error: 'tools unsupported' } },
      { status: 500, structuredError: { error: 'tools unsupported' } },
      { status: 400, structuredError: { error: 'messages[0].content is invalid' } },
      { status: 400, structuredError: { error: 'tools[0].function.name is required' } },
      { status: 400, structuredError: 'tools unsupported' },
    ]) expect(isDeterministicToolCallUnsupported(context)).toBe(false);
  });

  it('partitions false by the complete dispatch identity and clears only one account connection', () => {
    recordToolCallSupportFalse(toolCallIdentity, 1_000);
    expect(toolCallSupportIsRememberedFalse(toolCallIdentity)).toBe(true);
    for (const changed of [
      { ...toolCallIdentity, accountId: 'account-b' },
      { ...toolCallIdentity, connectionId: 'connection-b' },
      { ...toolCallIdentity, authMode: 'subscription' as const },
      { ...toolCallIdentity, canonicalModelId: 'model/b' },
      { ...toolCallIdentity, finalTransport: 'openai_responses' },
      { ...toolCallIdentity, finalTransport: 'unknown' },
      { ...toolCallIdentity, authMode: 'unknown' },
    ]) expect(toolCallSupportIsRememberedFalse(changed)).toBe(false);

    recordToolCallSupportFalse({ ...toolCallIdentity, accountId: 'account-b' }, 2_000);
    clearToolCallMemoryForConnection('account-a', 'connection-a');
    expect(toolCallSupportIsRememberedFalse(toolCallIdentity)).toBe(false);
    expect(toolCallSupportIsRememberedFalse({ ...toolCallIdentity, accountId: 'account-b' })).toBe(true);
  });

  it('ignores malformed persisted state and never records an unknown transport', () => {
    localStorage.setItem('oriveo.tool-call-rejection-cache.v1', '{broken');
    expect(toolCallSupportIsRememberedFalse(toolCallIdentity)).toBe(false);
    recordToolCallSupportFalse({ ...toolCallIdentity, finalTransport: 'unknown' });
    expect(toolCallSupportIsRememberedFalse({ ...toolCallIdentity, finalTransport: 'unknown' })).toBe(false);
  });
});

describe('capability recovery runtime', () => {
  beforeEach(() => memory.clear());

  it('admits only one production-owned custom pointer from structured /error/param', () => {
    const descriptor = locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom',
      structuredError: { error: { param: 'temperature' } },
      customAppliedPointers: { web: ['/temperature'] },
    }, undefined);
    expect(descriptor).toEqual({
      version: 1, action: 'user_confirmed_resend_without_located_setting',
      source: 'custom', owners: ['web'], locatedPointers: ['/temperature'],
    });
    expect(decodeCapabilityRecoveryDescriptor(encodeCapabilityRecoveryDescriptor(descriptor!))).toEqual(descriptor);
    expect(locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom', customAppliedPointers: { web: ['/temperature'] },
    }, undefined)).toBeNull();
    expect(locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom', structuredError: { error: { param: 'model' } },
      customAppliedPointers: { web: ['/temperature'] },
    }, undefined)).toBeNull();
    expect(locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom', structuredError: { error: { param: 'temperature' } },
      customAppliedPointers: { web: ['/temperature'], generation: ['/temperature'] },
    }, undefined)).toBeNull();
    for (const rejected of [
      { status: 401, preToken: true, streamStarted: false, sideEffects: false },
      { status: 403, preToken: true, streamStarted: false, sideEffects: false },
      { status: 429, preToken: true, streamStarted: false, sideEffects: false },
      { status: 500, preToken: true, streamStarted: false, sideEffects: false },
      { status: 400, preToken: false, streamStarted: true, sideEffects: false },
      { status: 400, preToken: true, streamStarted: false, sideEffects: true },
    ]) expect(locateCapabilityRecovery({
      ...rejected, automaticRetryCount: 0, source: 'custom',
      structuredError: { error: { param: 'temperature' } }, customAppliedPointers: { web: ['/temperature'] },
    }, undefined)).toBeNull();
  });

  it('uses only exact structured same-recipe locators and never scans error prose', () => {
    const recipes = { 'openai.responses.web.v1': {
      capability: 'web', errorRecoveryRef: 'openai.responses.web', responseParserKind: 'openai_responses_web_v1',
      transport: { protocol: 'openai_responses' }, requestOps: [{ op: 'set', pointer: '/tools' }],
    } };
    const definitions = { 'openai.responses.web': {
      capability: 'web', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1',
      locatorRules: [{ owner: 'web', status: 400, pointers: ['/tools'], errorFields: { '/error/code': 'unsupported_parameter' } }],
    } };
    const base = {
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'provider_recipe' as const,
      recipeRefs: ['openai.responses.web.v1'],
      recipes,
    };
    const descriptor = locateCapabilityRecovery({ ...base, structuredError: { error: { code: 'unsupported_parameter' } } }, definitions);
    expect(descriptor).toMatchObject({ source: 'provider_recipe', owners: ['web'], locatedPointers: ['/tools'] });
    recordCapabilityRejection(identity, descriptor!, 1_000);
    expect(capabilityRecoveryDescriptorIsCurrent(identity, descriptor!, 1_001)).toBe(true);
    const persistedMessage = { text: 'partial answer', attachments: ['image-1'] };
    const staleSender = vi.fn(() => { persistedMessage.text = ''; persistedMessage.attachments = []; });
    for (const switched of [
      { ...identity, connectionId: 'connection-b' },
      { ...identity, canonicalModelId: 'model/b' },
      { ...identity, finalTransport: 'openai_chat' },
      { ...identity, runtimeRevision: 'runtime-r8' },
    ]) {
      expect(capabilityRecoveryDescriptorIsCurrent(switched, descriptor!, 1_001)).toBe(false);
      expect(invokeCapabilityRecoveryRetry(switched, descriptor!, staleSender, 1_001)).toBe(false);
    }
    expect(staleSender).not.toHaveBeenCalled();
    expect(persistedMessage).toEqual({ text: 'partial answer', attachments: ['image-1'] });
    const currentSender = vi.fn();
    expect(invokeCapabilityRecoveryRetry(identity, descriptor!, currentSender, 1_001)).toBe(true);
    expect(currentSender).toHaveBeenCalledWith({
      capabilityRecipeOmissions: [{ recipeRef: 'openai.responses.web.v1', locatedPointers: ['/tools'] }],
      capabilityRecipeResendOwners: ['web'],
    });
    expect(capabilityRecoveryDescriptorIsCurrent(identity, {
      ...descriptor!, locatedPointers: ['/include'],
    }, 1_001)).toBe(false);
    expect(capabilityRecoveryDescriptorIsCurrent(identity, {
      ...descriptor!, recipeRef: 'other.recipe',
    }, 1_001)).toBe(false);
    expect(capabilityRecoveryDescriptorIsCurrent(identity, {
      ...descriptor!, owners: ['generation'],
    }, 1_001)).toBe(false);
    expect(capabilityRecoveryDescriptorIsCurrent(identity, {
      ...descriptor!, source: 'custom', recipeRef: undefined,
    }, 1_001)).toBe(false);
    expect(capabilityRejectionIsDormant(identity, 'web', 'provider_recipe', 1_001)).toBe(true);
    expect(capabilityRecipeOmissions(identity, 1_001)).toEqual([
      { recipeRef: 'openai.responses.web.v1', locatedPointers: ['/tools'] },
    ]);
    expect(locateCapabilityRecovery({ ...base, structuredError: { error: 'unsupported_parameter /tools' } }, definitions)).toBeNull();
    expect(locateCapabilityRecovery({ ...base, recipeRefs: ['other.recipe'], structuredError: { error: { code: 'unsupported_parameter' } } }, definitions)).toBeNull();
    expect(locateCapabilityRecovery({ ...base, structuredError: { error: { code: 'unsupported_parameter' } } }, {
      'openai.responses.web': { ...definitions['openai.responses.web'], locatorRules: [{ owner: 'web', status: 400, pointers: ['/messages'], errorFields: { '/error/code': 'unsupported_parameter' } }] },
    })).toBeNull();
  });

  it('persists a TTL-partitioned dormant cache across cold module state and isolates every runtime identity field', () => {
    const descriptor = locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom', structuredError: { error: { param: 'temperature' } },
      customAppliedPointers: { generation: ['/temperature'] },
    }, undefined)!;
    recordCapabilityRejection(identity, descriptor, 1_000);
    expect(capabilityRejectionIsDormant(identity, 'generation', 'custom', 1_001)).toBe(true);
    expect(capabilityRejectionIsDormant(identity, 'generation', 'provider_recipe', 1_001)).toBe(false);
    expect(capabilityRejectionIsDormant({ ...identity, connectionId: 'connection-b' }, 'generation', 'custom', 1_001)).toBe(false);
    expect(capabilityRejectionIsDormant({ ...identity, canonicalModelId: 'model/b' }, 'generation', 'custom', 1_001)).toBe(false);
    expect(capabilityRejectionIsDormant({ ...identity, finalTransport: 'openai_chat' }, 'generation', 'custom', 1_001)).toBe(false);
    expect(capabilityRejectionIsDormant({ ...identity, runtimeRevision: 'runtime-r8' }, 'generation', 'custom', 1_001)).toBe(false);
    expect(capabilityRejectionIsDormant(identity, 'generation', 'custom', 1_000 + 24 * 60 * 60 * 1_000 + 1)).toBe(false);
  });

  it('clears every model/transport/revision rejection variant for a deleted connection only', () => {
    const now = Date.now();
    const descriptor = locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom', structuredError: { error: { param: 'temperature' } },
      customAppliedPointers: { generation: ['/temperature'] },
    }, undefined)!;
    const variants = [
      identity,
      { ...identity, canonicalModelId: 'model/b' },
      { ...identity, finalTransport: 'openai_chat' },
      { ...identity, runtimeRevision: 'runtime-r8' },
    ];
    for (const variant of variants) recordCapabilityRejection(variant, descriptor, now);
    recordCapabilityRejection({ ...identity, connectionId: 'connection-b' }, descriptor, now);

    clearCapabilityRejectionsForConnection(identity.connectionId);

    for (const variant of variants) {
      expect(capabilityRejectionIsDormant(variant, 'generation', 'custom', now + 1)).toBe(false);
    }
    expect(capabilityRejectionIsDormant({ ...identity, connectionId: 'connection-b' }, 'generation', 'custom', now + 1)).toBe(true);
  });
});
