/**
 * Chat template thinking switch: applicable transports, the four states, in-place rewriting that preserves formatting, and writes that go out through the production store and withAdditionalBody.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import { additionalBodyScope, loadAdditionalBody, saveAdditionalBody, withAdditionalBody } from '../additional-body-settings';
import {
  applyChatTemplateThinking,
  chatTemplateThinkingApplies,
  chatTemplateThinkingState,
  setChatTemplateThinking,
  writeChatTemplateThinking,
} from '../chat-template-thinking';

const relay = { id: 'conn-local', kind: 'relay', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;
const model = { id: 'qwen3', name: 'Q', capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' } as AIModel;

beforeEach(() => localStorage.clear());

describe('applicable transports', () => {
  it('only OpenAI Chat Completions', () => {
    expect(chatTemplateThinkingApplies('openai_chat_completions')).toBe(true);
    // The form after capabilityRuntimeIdentity normalization (this is what the popover reads once the runtime is ready).
    expect(chatTemplateThinkingApplies('openai_chat')).toBe(true);
    expect(chatTemplateThinkingApplies('anthropic_messages')).toBe(false);
    expect(chatTemplateThinkingApplies('llamacpp_native')).toBe(false);
    expect(chatTemplateThinkingApplies(undefined)).toBe(false);
  });
});

describe('the four states', () => {
  it('empty content -> off', () => {
    expect(chatTemplateThinkingState(null)).toBe('off');
    expect(chatTemplateThinkingState({ raw: '  \n', enabled: true })).toBe('off');
  });
  it('sending on: only enable_thinking === true is on', () => {
    expect(chatTemplateThinkingState({ raw: '{"chat_template_kwargs":{"enable_thinking":true}}', enabled: true })).toBe('on');
    expect(chatTemplateThinkingState({ raw: '{"chat_template_kwargs":{"enable_thinking":"true"}}', enabled: true })).toBe('off');
    expect(chatTemplateThinkingState({ raw: '{"top_k":3}', enabled: true })).toBe('off');
  });
  it('invalid / rejected locally / kwargs is not an object -> blocked', () => {
    expect(chatTemplateThinkingState({ raw: '{"a":', enabled: true })).toBe('blocked');
    expect(chatTemplateThinkingState({ raw: '{"messages":[]}', enabled: true })).toBe('blocked');
    expect(chatTemplateThinkingState({ raw: '{"chat_template_kwargs":true}', enabled: false })).toBe('blocked');
  });
  it('sending off: other fields present -> notSending, otherwise off', () => {
    expect(chatTemplateThinkingState({ raw: '{"top_k":3,"chat_template_kwargs":{"enable_thinking":true}}', enabled: false })).toBe('notSending');
    expect(chatTemplateThinkingState({ raw: '{"chat_template_kwargs":{"enable_thinking":true,"x":1}}', enabled: false })).toBe('notSending');
    expect(chatTemplateThinkingState({ raw: '{"chat_template_kwargs":{"enable_thinking":true}}', enabled: false })).toBe('off');
  });
});

describe('in-place rewriting', () => {
  it('empty content -> a new object with two-space indentation', () => {
    expect(setChatTemplateThinking(true, '')).toBe('{\n  "chat_template_kwargs": {\n    "enable_thinking": true\n  }\n}');
  });
  it('multi-line with an existing key: only this value changes and everything else stays byte-identical', () => {
    const raw = '{\n    "top_k": 20,\n    "chat_template_kwargs": {\n        "enable_thinking": false,\n        "x": [1, 2]\n    },\n    "z": "a"\n}';
    expect(setChatTemplateThinking(true, raw)).toBe(raw.replace('"enable_thinking": false', '"enable_thinking": true'));
  });
  it('single-line with an existing key: off writes false and does not delete the key', () => {
    expect(setChatTemplateThinking(false, '{"chat_template_kwargs":{"enable_thinking":true},"b":1}'))
      .toBe('{"chat_template_kwargs":{"enable_thinking":false},"b":1}');
  });
  it('kwargs without the key: appended at the end of kwargs, with separators and indentation following the original', () => {
    const raw = '{\n  "chat_template_kwargs": {\n    "x": 1\n  }\n}';
    expect(setChatTemplateThinking(true, raw)).toBe('{\n  "chat_template_kwargs": {\n    "x": 1,\n    "enable_thinking": true\n  }\n}');
  });
  it('no kwargs: appended at the end of the root object (multi-line and single-line)', () => {
    expect(setChatTemplateThinking(true, '{\n  "top_k": 20\n}'))
      .toBe('{\n  "top_k": 20,\n  "chat_template_kwargs": {\n    "enable_thinking": true\n  }\n}');
    expect(setChatTemplateThinking(false, '{"top_k":20}')).toBe('{"top_k":20,"chat_template_kwargs":{"enable_thinking":false}}');
  });
});

describe('writing', () => {
  it('does not write for blocked and notSending', () => {
    expect(applyChatTemplateThinking(true, { raw: '{"a":', enabled: true })).toBeNull();
    expect(applyChatTemplateThinking(true, { raw: '{"top_k":3}', enabled: false })).toBeNull();
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"top_k":3}', enabled: false });
    expect(writeChatTemplateThinking(true, additionalBodyScope(relay, model, 'c1'))).toBe(false);
    expect(loadAdditionalBody(additionalBodyScope(relay, model, 'c1'))).toBeNull();
  });
  it('rewrites the content and turns sending on when writable', () => {
    expect(applyChatTemplateThinking(true, null)).toEqual({ raw: setChatTemplateThinking(true, ''), enabled: true });
  });
  it('writes to the conversation layer on top of the effective record and sends enable_thinking through withAdditionalBody', () => {
    saveAdditionalBody(additionalBodyScope(relay, model), { raw: '{"top_k":3}', enabled: true });
    expect(writeChatTemplateThinking(true, additionalBodyScope(relay, model, 'c1'))).toBe(true);
    expect(loadAdditionalBody(additionalBodyScope(relay, model))?.raw).toBe('{"top_k":3}');
    const options = withAdditionalBody({ supportsWebSearch: false }, { provider: relay, model, conversationId: 'c1' });
    const outbound = JSON.parse(options?.additionalBody?.raw ?? '{}');
    expect(outbound).toEqual({ top_k: 3, chat_template_kwargs: { enable_thinking: true } });
    expect(chatTemplateThinkingState(loadAdditionalBody(additionalBodyScope(relay, model, 'c1')))).toBe('on');
  });
  it('writes the model default when there is no conversation', () => {
    expect(writeChatTemplateThinking(false, additionalBodyScope(relay, model))).toBe(true);
    expect(JSON.parse(loadAdditionalBody(additionalBodyScope(relay, model))?.raw ?? '{}'))
      .toEqual({ chat_template_kwargs: { enable_thinking: false } });
  });
});
