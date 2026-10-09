/**
 * Local storage and legacy migration of the additional request body (local only, keyed per scope, the switch and the content are stored separately, legacy records are migrated).
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

const partitionMocks = vi.hoisted(() => ({ activeUID: 'user-a' }));
vi.mock('../../../infra/storage/partition', () => ({
  getActiveUIDSync: () => partitionMocks.activeUID,
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import {
  additionalBodyScope,
  loadAdditionalBody,
  removeAdditionalBodyScopes,
  resolveAdditionalBodyForSend,
  resolveEffectiveAdditionalBody,
  saveAdditionalBody,
} from '../additional-body-settings';
import { customFragmentScope, loadCustomFragmentSettings, saveCustomFragmentSettings } from '../custom-fragment-settings';
import { exportGenerationParameterSyncPayload } from '../generation-parameter-settings';
import { exportCapabilityPreferenceSyncPayload } from '../capability-preference-settings';
import { exportGenerationParameterDiagnosticsJSON } from '../generation-parameter-diagnostics';
import { clearPartitionedStoreForUID } from '../../../infra/storage/partitioned-local-store';

const relay = { id: 'conn-1', kind: 'relay', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;
const model = { id: 'model-1', name: 'M', capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' } as AIModel;
const otherModel = { ...model, id: 'model-2' } as AIModel;

function legacyGeneration(transport: string, mode: 'custom' | 'auto', raw: string, providerModel: AIModel = model) {
  saveCustomFragmentSettings(customFragmentScope(relay, providerModel, transport, 'generation'), { configurationMode: mode, raw });
}

beforeEach(() => {
  localStorage.clear();
  partitionMocks.activeUID = 'user-a';
});

describe('additional body storage', () => {
  it('keys by connection x model x conversation (or model default)', () => {
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"a":1}', enabled: true });
    saveAdditionalBody(additionalBodyScope(relay, model, 'conv-1'), { raw: '{"b":1}', enabled: true });
    expect(loadAdditionalBody(additionalBodyScope(relay, model))?.raw).toBe('{"a":1}');
    expect(loadAdditionalBody(additionalBodyScope(relay, model, 'conv-1'))?.raw).toBe('{"b":1}');
    expect(loadAdditionalBody(additionalBodyScope(relay, model, 'conv-2'))).toBeNull();
    expect(loadAdditionalBody(additionalBodyScope(relay, otherModel))).toBeNull();
    expect(loadAdditionalBody({ connectionId: 'conn-2', modelId: model.id })).toBeNull();
  });

  it('effective value: uses the conversation layer when it has a record, otherwise the model default', () => {
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"a":1}', enabled: true });
    expect(resolveEffectiveAdditionalBody(additionalBodyScope(relay, model, 'conv-1'))?.raw).toBe('{"a":1}');
    saveAdditionalBody(additionalBodyScope(relay, model, 'conv-1'), { raw: '{"b":2}', enabled: false });
    expect(resolveEffectiveAdditionalBody(additionalBodyScope(relay, model, 'conv-1'))).toMatchObject({ raw: '{"b":2}', enabled: false });
    // Conversation layer switched off: nothing is sent this time and it does not fall back to the model default
    expect(resolveAdditionalBodyForSend({ provider: relay, model, conversationId: 'conv-1' })).toBeUndefined();
    expect(resolveAdditionalBodyForSend({ provider: relay, model, conversationId: 'conv-2' })).toEqual({ raw: '{"a":1}' });
  });

  it('an empty conversation-layer record is kept: empty content + off means this conversation sends nothing and masks the model default; only an explicit clear falls back', () => {
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"a":1}', enabled: true });
    saveAdditionalBody(additionalBodyScope(relay, model, 'conv-1'), { raw: '', enabled: false });
    expect(loadAdditionalBody(additionalBodyScope(relay, model, 'conv-1'))).toMatchObject({ raw: '', enabled: false });
    expect(resolveAdditionalBodyForSend({ provider: relay, model, conversationId: 'conv-1' })).toBeUndefined();
    // Only an explicit clear (passing null) deletes the record, after which it falls back to the model default
    saveAdditionalBody(additionalBodyScope(relay, model, 'conv-1'), null);
    expect(loadAdditionalBody(additionalBodyScope(relay, model, 'conv-1'))).toBeNull();
    expect(resolveAdditionalBodyForSend({ provider: relay, model, conversationId: 'conv-1' })).toEqual({ raw: '{"a":1}' });
  });

  it('switch and content are separate: after switching off the content stays and is simply not sent', () => {
    const scope = additionalBodyScope(relay, model);
    saveAdditionalBody(scope, { raw: '{"top_k":3}', enabled: false });
    expect(loadAdditionalBody(scope)).toMatchObject({ raw: '{"top_k":3}', enabled: false });
    expect(resolveAdditionalBodyForSend({ provider: relay, model })).toBeUndefined();
    saveAdditionalBody(scope, { raw: '{"top_k":3}', enabled: true });
    expect(resolveAdditionalBodyForSend({ provider: relay, model })).toEqual({ raw: '{"top_k":3}' });
    saveAdditionalBody(scope, { raw: '  ', enabled: true });
    expect(resolveAdditionalBodyForSend({ provider: relay, model })).toBeUndefined();
  });

  it('subscription sign-in connections can carry an additional body', () => {
    const subscription = { ...relay, kind: 'grok', authMode: 'subscription' } as Provider;
    saveAdditionalBody(additionalBodyScope(subscription, model), { raw: '{"top_k":3}', enabled: true });
    expect(resolveAdditionalBodyForSend({ provider: subscription, model })).toEqual({ raw: '{"top_k":3}' });
  });

  it('clearing scopes: delete a conversation / a model / a connection', () => {
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"a":1}', enabled: true });
    saveAdditionalBody(additionalBodyScope(relay, model, 'conv-1'), { raw: '{"b":1}', enabled: true });
    saveAdditionalBody(additionalBodyScope(relay, otherModel), { raw: '{"c":1}', enabled: true });
    removeAdditionalBodyScopes({ conversationId: 'conv-1' });
    expect(loadAdditionalBody(additionalBodyScope(relay, model, 'conv-1'))).toBeNull();
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).not.toBeNull();
    removeAdditionalBodyScopes({ providerId: relay.id, modelId: model.id });
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toBeNull();
    expect(loadAdditionalBody(additionalBodyScope(relay, otherModel))).not.toBeNull();
    removeAdditionalBodyScopes({ providerId: relay.id });
    expect(loadAdditionalBody(additionalBodyScope(relay, otherModel))).toBeNull();
  });

  it('partition boundary: another partition cannot read the previous one\'s record, and clearing the partition resets it', () => {
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"secret":1}', enabled: true });
    partitionMocks.activeUID = 'user-b';
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toBeNull();
    partitionMocks.activeUID = 'user-a';
    expect(loadAdditionalBody(additionalBodyScope(relay, model))?.raw).toBe('{"secret":1}');
    clearPartitionedStoreForUID('user-a');
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toBeNull();
  });

  it('stays out of sync payloads / exports / diagnostics: no output contains the additional body content, and the storage key is held by this module only', () => {
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"sentinel_additional_body_value":1}', enabled: true });
    const outputs = [
      JSON.stringify(exportGenerationParameterSyncPayload()),
      JSON.stringify(exportCapabilityPreferenceSyncPayload()),
      exportGenerationParameterDiagnosticsJSON(),
    ];
    for (const output of outputs) expect(output).not.toContain('sentinel_additional_body_value');
    const holders = collectSources(path.resolve(__dirname, '../../../..'))
      .filter((file) => readFileSync(file, 'utf8').includes('local-additional-body'));
    expect(holders.map((file) => path.basename(file))).toEqual(['additional-body-settings.ts']);
  });
});

describe('legacy generation custom fields -> additional body (lazy migration)', () => {
  it('active and valid -> keeps being sent; the legacy record is deleted, web / reasoning are untouched', () => {
    legacyGeneration('t-a', 'custom', '{"top_k":40}');
    saveCustomFragmentSettings(customFragmentScope(relay, model, 't-a', 'web'), { configurationMode: 'custom', raw: '{"enable_search":true}' });
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toMatchObject({ raw: '{"top_k":40}', enabled: true });
    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, 't-a', 'generation'))).toEqual({ configurationMode: 'auto', raw: '' });
    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, 't-a', 'web')).raw).toBe('{"enable_search":true}');
  });

  it('disabled -> draft, not sent by default', () => {
    legacyGeneration('t-a', 'auto', '{"top_k":40}');
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toMatchObject({ raw: '{"top_k":40}', enabled: false });
  });

  it('invalid (truncated JSON / protected field) -> draft, not sent by default', () => {
    legacyGeneration('t-a', 'custom', '{"top_k": ');
    legacyGeneration('t-a', 'custom', '{"model":"x"}', otherModel);
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toMatchObject({ raw: '{"top_k": ', enabled: false });
    expect(loadAdditionalBody(additionalBodyScope(relay, otherModel))).toMatchObject({ raw: '{"model":"x"}', enabled: false });
  });

  it('one scope with several protocol identities: only the most recently modified one is kept', () => {
    legacyGeneration('t-new', 'custom', '{"v":"old"}');
    legacyGeneration('t-old', 'auto', '{"v":"older"}');
    legacyGeneration('t-new', 'custom', '{"v":"latest"}');
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toMatchObject({ raw: '{"v":"latest"}', enabled: true });
    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, 't-old', 'generation')).raw).toBe('');
  });

  it('running again has no side effects: a record the user edited is not overwritten', () => {
    legacyGeneration('t-a', 'custom', '{"top_k":40}');
    expect(loadAdditionalBody(additionalBodyScope(relay, model))?.raw).toBe('{"top_k":40}');
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"top_k":1}', enabled: false });
    const snapshot = JSON.stringify(localStorage);
    expect(loadAdditionalBody(additionalBodyScope(relay, model))).toMatchObject({ raw: '{"top_k":1}', enabled: false });
    expect(JSON.stringify(localStorage)).toBe(snapshot);
  });
});

function collectSources(root: string): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(root)) {
    if (entry === 'node_modules' || entry.startsWith('.')) continue;
    const full = path.join(root, entry);
    if (statSync(full).isDirectory()) files.push(...collectSources(full));
    else if (/\.(ts|tsx)$/.test(entry) && !/\.test\.tsx?$/.test(entry)) files.push(full);
  }
  return files;
}
