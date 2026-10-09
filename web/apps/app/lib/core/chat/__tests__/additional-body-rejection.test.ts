/**
 * Local additional body rejection -> error card copy: the input is the rejection actually thrown by production validation (`withAdditionalBody` /
 * `validateAdditionalBody`), not a hand-built safe code.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { additionalBodyRejectionCode as coreCode, validateAdditionalBody } from '@oriveo/core/providers/request-builders/additional-body';
import en from '../../../../messages/en.json';

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import { additionalBodyScope, saveAdditionalBody, withAdditionalBody } from '../additional-body-settings';
import { additionalBodyRejectionCode, additionalBodyRejectionCopy } from '../additional-body-rejection';

const relay = { id: 'conn-1', kind: 'relay', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;
const model = { id: 'model-1', name: 'M', capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' } as AIModel;

function thrownCode(raw: string): string {
  saveAdditionalBody(additionalBodyScope(relay, model), { raw, enabled: true });
  try { withAdditionalBody(undefined, { provider: relay, model }); } catch (error) {
    const code = additionalBodyRejectionCode(error);
    if (code) return code;
    throw error;
  }
  throw new Error('not rejected');
}

function rejected(raw: string): string {
  const result = validateAdditionalBody(raw);
  if (result.accepted) throw new Error('accepted');
  return coreCode(result.rejection);
}

beforeEach(() => localStorage.clear());

describe('additionalBodyRejectionCopy', () => {
  it('syntax errors carry a line number', () => {
    expect(additionalBodyRejectionCopy(thrownCode('{\n"top_k": ,\n}'))).toEqual({ reasonKey: 'reasonInvalidJson', line: 2 });
  });

  it('root is not an object / too deep / too large', () => {
    expect(additionalBodyRejectionCopy(thrownCode('[1]'))).toEqual({ reasonKey: 'reasonNotObject' });
    expect(additionalBodyRejectionCopy(rejected(`${'{"a":'.repeat(40)}1${'}'.repeat(40)}`))).toEqual({ reasonKey: 'reasonTooDeep' });
    expect(additionalBodyRejectionCopy(rejected(`{"a":"${'x'.repeat(70 * 1024)}"}`))).toEqual({ reasonKey: 'reasonTooLarge' });
  });

  it('protected field / blocked segment: the field name comes from the safe code (an Oriveo-owned name), not a user-written value', () => {
    expect(additionalBodyRejectionCopy(thrownCode('{"messages":[]}'))).toEqual({ reasonKey: 'reasonProtectedField', values: { field: 'messages' } });
    expect(additionalBodyRejectionCopy(rejected('{"a":{"__proto__":{"x":1}}}'))).toEqual({ reasonKey: 'reasonBlockedSegment', values: { field: '__proto__' } });
  });

  it('an unknown reason falls back to the "not sent" message outside the syntax kind: no invented reason', () => {
    expect(additionalBodyRejectionCopy('additional_body_rejected:future_reason')).toEqual({ reasonKey: 'message' });
  });

  it('every reason key has copy under errors.additionalBodyRejected in en.json', () => {
    const copy = (en as { errors: { additionalBodyRejected: Record<string, string> } }).errors.additionalBodyRejected;
    for (const key of ['reasonInvalidJson', 'reasonNotObject', 'reasonTooDeep', 'reasonTooLarge', 'reasonProtectedField', 'reasonBlockedSegment', 'message', 'line', 'title', 'upstreamTitle']) {
      expect(copy[key], key).toBeTruthy();
    }
  });

  it('extracts the safe code from an error object or a detail string', () => {
    expect(additionalBodyRejectionCode({ detail: 'x additional_body_rejected:invalid_json@3' })).toBe('additional_body_rejected:invalid_json@3');
    expect(additionalBodyRejectionCode(new Error('boom'))).toBeNull();
  });
});
