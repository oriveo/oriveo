import { describe, expect, it } from 'vitest';
import {
  previewGenerationCompatibility,
  removeGenerationConflicts,
  validateCustomGenerationParameter,
} from './generation-workbench';
import type { GenerationParameterProfile } from './request-builders/types';

const profile: GenerationParameterProfile = {
  template: 'openai_chat_completions',
  wire: { json_schema: 'response_format', top_logprobs: 'top_logprobs', logprobs: 'logprobs' },
  parameters: [
    { id: 'json_schema', support: 'supported', source: 'relay_declared', conflictsWith: ['tools'], valueSchema: 'json-schema' },
    { id: 'logprobs', support: 'supported', source: 'relay_declared', valueSchema: 'boolean' },
    { id: 'top_logprobs', support: 'supported', source: 'relay_declared', valueSchema: 'integer', requires: [{ key: 'logprobs', value: true }] },
  ],
};

describe('generation expert workbench contract', () => {
  it('hard-blocks reserved and sensitive custom fields', () => {
    for (const id of ['model', 'messages', 'tools', 'authorization', 'api_key', 'callback_url']) {
      expect(() => validateCustomGenerationParameter({ id, valueSchema: 'string', wire: id })).toThrow();
    }
    expect(validateCustomGenerationParameter({ id: 'min_tokens', valueSchema: 'integer', min: 0, wire: 'extra_body.min_tokens' }))
      .toMatchObject({ id: 'custom.min_tokens', wire: 'extra_body.min_tokens' });
  });

  it('previews tools/schema and dependency conflicts and removes only blocking values', () => {
    const overrides = {
      json_schema: { state: 'value' as const, value: { type: 'object' } },
      top_logprobs: { state: 'value' as const, value: 5 },
    };
    const issues = previewGenerationCompatibility({ profile, overrides, toolsActive: true, streaming: true });
    expect(issues).toEqual(expect.arrayContaining([
      { key: 'json_schema', kind: 'conflict', conflictsWith: 'tools' },
      { key: 'top_logprobs', kind: 'requires', conflictsWith: 'logprobs' },
      { key: 'json_schema', kind: 'rendering' },
      { key: 'json_schema', kind: 'streaming' },
    ]));
    expect(removeGenerationConflicts(overrides, issues)).toEqual({});
  });
});
