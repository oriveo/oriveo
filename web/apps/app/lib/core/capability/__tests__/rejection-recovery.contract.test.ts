// @vitest-environment jsdom
//
// One-tap action after an official upstream rejection (fixture rejection-recovery.v1.json).
// Signature matching is fed the fixture match directly (file / video have no official signature, so no entries are invented in the signature table); the rest goes through production
// recordOfficialInputRejection -> failed message record -> rejectionRecoveryAction, asserting the action and the negative cache writes.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import type { ContentPart } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({ match: vi.fn() }));

vi.mock('../rejection-signatures', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../rejection-signatures')>()),
  matchRejectionSignature: (...args: unknown[]) => mocks.match(...args),
}));

import { recordOfficialInputRejection } from '../input-rejection-flow';
import { INPUT_NEGATIVE_CACHE_STORAGE_KEY, recordInputNegativeCache } from '../input-negative-cache';
import { inputNegativeCacheTarget } from '../truth/input-truth-adapter';
import { attachOfficialInputRejection, officialInputRejectionOf, rejectionMessagePatch, rejectionRecoveryAction } from '../rejection-recovery';
import { attachmentDisabledMessageKey, type AttachmentMedia } from '../../chat/attachment-policy';

type CapabilityKey = 'vision_input' | 'file_input' | 'video_input';
type Match =
  | { kind: 'input_rejected'; capabilityKey: CapabilityKey }
  | { kind: 'param_rejected'; parameter: string };

interface ActionCase {
  id: string;
  connection: string;
  match: Match | null;
  negativeCacheAlreadyHit?: boolean;
  expect: { action: string | null; negativeCache: boolean };
}

interface KillSwitchCase {
  id: string;
  key: CapabilityKey;
  expect: { copyId: string };
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'capability', 'rejection-recovery.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as { actionCases: ActionCase[]; killSwitchCopyCases: KillSwitchCase[] };
    }
    dir = path.dirname(dir);
  }
  throw new Error('rejection-recovery.v1.json not found');
})();

const model: AIModel = {
  id: 'qwen-vl-test', name: 'Qwen VL Test', capabilities: ['text'], transport: 'openai_chat_completions',
  reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '$',
  capabilityControls: {
    vision_input: { state: 'unknown', reasonCode: 'catalog_silent', wireFamily: 'openai_chat.image_url' },
    file_input: { state: 'unknown', reasonCode: 'catalog_silent', wireFamily: 'openai_chat.file' },
    video_input: { state: 'unknown', reasonCode: 'catalog_silent', wireFamily: 'openai_chat.video_url' },
  },
} as unknown as AIModel;

const provider: Provider = {
  id: 'official-qwen', kind: 'qwen', status: { kind: 'connected' }, models: [model], catalogModels: [model],
  apiKey: 'sk-test', apiKeyPreview: '••test', authMode: 'apiKey',
} as Provider;

// This round really carried all three media types: whichever key is hit satisfies "the media was really sent".
const carriedParts = [
  { type: 'text', text: 'look' },
  { type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } },
  { type: 'file', file: { filename: 'a.pdf', file_data: 'data:application/pdf;base64,AAAA' } },
  { type: 'video_url', video_url: { url: 'data:video/mp4;base64,AAAA' } },
] as unknown as ContentPart[];

const KEY_MEDIA: Readonly<Record<CapabilityKey, AttachmentMedia>> = {
  vision_input: 'image', file_input: 'file', video_input: 'video',
};

function storedEntries(): Array<Record<string, unknown>> {
  const raw = localStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY);
  return raw ? (JSON.parse(raw) as { entries: Array<Record<string, unknown>> }).entries : [];
}

function failedMessage(result: ReturnType<typeof recordOfficialInputRejection>) {
  return { role: 'assistant' as const, state: 'failed' as const, ...rejectionMessagePatch(result) };
}

describe('rejection-recovery.v1 actionCases', () => {
  beforeEach(() => {
    localStorage.clear();
    mocks.match.mockReset();
  });

  it.each(fixture.actionCases.map((item) => [item.id, item] as const))('REJECTION-RECOVERY-%s', (_id, item) => {
    expect(item.connection).toBe('official');
    if (item.negativeCacheAlreadyHit) {
      const target = inputNegativeCacheTarget(provider, model, undefined, 'vision_input')!;
      recordInputNegativeCache(target.key, { signatureId: 'earlier.signature', verdictRevision: target.verdictRevision });
    }
    const before = JSON.stringify(storedEntries());
    mocks.match.mockReturnValue(item.match ? { signatureId: `test.${item.id}`, ...item.match } : null);

    const result = recordOfficialInputRejection({
      provider, model, streamOptions: undefined,
      messages: [{ content: carriedParts }],
      error: { status: 400, source: 'provider', detail: '{"error":{"message":"rejected"}}' },
    });

    // Fields on the failed message come only from the production patch (media -> inputRejection, parameter -> generationParameterRejection).
    expect(rejectionRecoveryAction(failedMessage(result))).toBe(item.expect.action);

    const entries = storedEntries();
    if (item.expect.negativeCache) {
      const expectedKey = item.match?.kind === 'input_rejected' ? item.match.capabilityKey
        : item.match?.kind === 'param_rejected' ? `param:${item.match.parameter}` : null;
      expect(entries).toEqual([expect.objectContaining({
        connectionId: provider.id, modelId: model.id, capabilityKey: expectedKey, signatureId: `test.${item.id}`,
      })]);
    } else {
      expect(JSON.stringify(entries)).toBe(before);
    }
  });

  it('WEB-REJECTION-RECOVERY-param_signature_from_upstream_body', async () => {
    // Real signature table: the upstream error body hits dashscope.enable_search_not_supported (param_rejected).
    const actual = await vi.importActual<typeof import('../rejection-signatures')>('../rejection-signatures');
    mocks.match.mockImplementation(actual.matchRejectionSignature);
    const error = {
      status: 400, source: 'provider',
      detail: JSON.stringify({ error: { code: 'invalid_parameter_error', message: 'This model does not support enable_search.' } }),
    };
    const result = recordOfficialInputRejection({
      provider, model, streamOptions: undefined, messages: [{ content: 'hi' }], error,
    });
    expect(result).toEqual({ kind: 'param_rejected', parameter: 'enable_search', signatureId: 'dashscope.enable_search_not_supported' });
    // Normal send: attached to the error, and failure persistence reads generationParameterRejection.
    attachOfficialInputRejection(error, result);
    expect((error as { generationParameterRejection?: unknown }).generationParameterRejection).toEqual({
      parameterId: 'enable_search', signatureId: 'dashscope.enable_search_not_supported',
    });
    expect(officialInputRejectionOf(error)).toBeUndefined();
    expect(rejectionRecoveryAction(failedMessage(result))).toBe('resend_without_parameter');
    expect(storedEntries()).toEqual([expect.objectContaining({
      capabilityKey: 'param:enable_search', signatureId: 'dashscope.enable_search_not_supported',
    })]);
  });

  it('WEB-REJECTION-RECOVERY-stream_parameter_wins_over_signature', () => {
    const error = { generationParameterRejection: { parameterId: 'temperature' } };
    attachOfficialInputRejection(error, { kind: 'param_rejected', parameter: 'top_p', signatureId: 'x' });
    expect(error.generationParameterRejection).toEqual({ parameterId: 'temperature' });
  });

  it('WEB-REJECTION-RECOVERY-signature_same_parameter_adds_source', () => {
    // The generic panel ruling already recorded enable_search and the signature names the same parameter: keep the original record and add the signature origin.
    const error = { generationParameterRejection: { parameterId: 'enable_search' } };
    attachOfficialInputRejection(error, { kind: 'param_rejected', parameter: 'enable_search', signatureId: 'dashscope.enable_search_not_supported' });
    expect(error.generationParameterRejection).toEqual({
      parameterId: 'enable_search', signatureId: 'dashscope.enable_search_not_supported',
    });
  });

  it('WEB-REJECTION-RECOVERY-record_only_on_failed_assistant', () => {
    const record = { capabilityKey: 'vision_input' as const, signatureId: 'test.sig' };
    expect(rejectionRecoveryAction({ role: 'assistant', state: 'delivered', inputRejection: record })).toBeNull();
    expect(rejectionRecoveryAction({ role: 'user', state: 'failed', inputRejection: record })).toBeNull();
  });
});

describe('rejection-recovery.v1 killSwitchCopyCases', () => {
  it.each(fixture.killSwitchCopyCases.map((item) => [item.id, item] as const))('REJECTION-RECOVERY-%s', (_id, item) => {
    // The fixture copyId segment uses snake_case while Web localization key segments use camelCase: disabled.kill_switch.<m> <-> disabled.killSwitch.<m>.
    const webKey = item.expect.copyId.replace(/_([a-z])/g, (_m, letter: string) => letter.toUpperCase());
    expect(attachmentDisabledMessageKey('disabled.kill_switch', KEY_MEDIA[item.key])).toBe(webKey);
  });
});
