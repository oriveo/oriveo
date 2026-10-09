/**
 * Outbound side of the shared contract "model-level parameter facts registered per upstream":
 * modelLevelFacts + modelLevelOutboundCases.
 *
 * strict is written only when true is served; Anthropic's JSON Schema goes to output_config.format;
 * only one of max_tokens and max_completion_tokens is kept. Each case is read from the shared file
 * instead of copying the expectations here.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildAnthropicRequest } from '../anthropic';
import { guardAnthropicThinking } from '../anthropic-thinking';
import { writeGenerationParameters, mergeDroppedGenerationParameters, type DroppedGenerationParameter } from '../generation-parameters';
import { buildOpenAIRequest } from '../openai';
import type { GenerationParameterOverrides, GenerationParameterProfile } from '../types';

interface ModelLevelOutboundCase {
  caseId: string;
  profile: {
    template: string;
    parameters: Array<Record<string, unknown> & { id: string }>;
    wire: Record<string, string>;
  };
  body: Record<string, unknown>;
  overrides: Record<string, { state: 'value' | 'omit' | 'inherit'; value?: unknown }>;
  expect: { body: Record<string, unknown>; bodyExcludes?: string[]; dropped: DroppedGenerationParameter[] };
}

const cases = loadJSON<{ modelLevelOutboundCases: ModelLevelOutboundCase[] }>(
  'generation_parameter_contract.v1.cases.json',
).modelLevelOutboundCases;

describe('modelLevelOutboundCases (shared contract, case by case)', () => {
  it('the case set size is pinned at 15', () => {
    expect(cases).toHaveLength(15);
  });

  for (const item of cases) {
    it(item.caseId, () => {
      const profile = toProfile(item.profile);
      const body = structuredClone(item.body);
      const builderDefaultMaxTokens = body.max_tokens;
      const result = writeGenerationParameters(body, item.overrides as GenerationParameterOverrides, profile);
      const thinkingDropped = profile.template === 'anthropic_messages'
        ? guardAnthropicThinking(body, { profile, written: result.written, builderDefaultMaxTokens })
        : [];
      expect(body).toEqual(item.expect.body);
      for (const key of item.expect.bodyExcludes ?? []) expect(body).not.toHaveProperty(key);
      expect(mergeDroppedGenerationParameters(result.dropped, thinkingDropped)).toEqual(item.expect.dropped);
    });
  }
});

const schema = { type: 'object', properties: { answer: { type: 'string' } }, required: ['answer'] };

describe('real request bodies from the production builder', () => {
  it('official Anthropic: JSON Schema is written to output_config.format, merged with the thinking effort, with no top-level output_format', () => {
    const profile: GenerationParameterProfile = {
      template: 'anthropic_messages',
      wire: { max_output_tokens: 'max_tokens', json_schema: 'output_config.format' },
      parameters: [
        { id: 'max_output_tokens', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 1 } },
        { id: 'json_schema', support: 'supported', source: 'test', valueSchema: 'json-schema', conflictsWith: ['tools', 'response_format'] },
      ],
    };
    const request = buildAnthropicRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: 'claude-fixture', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: { generationProfile: profile, generationParameters: { json_schema: { state: 'value', value: schema } } },
    }, { output_config: { effort: 'high' } }, null, 8192);
    expect(request.body.output_config).toEqual({ effort: 'high', format: { type: 'json_schema', schema } });
    expect(request.body).not.toHaveProperty('output_format');
  });

  it('official OpenAI Chat Completions: the model-level wire writes max tokens as max_completion_tokens', () => {
    const profile: GenerationParameterProfile = {
      template: 'openai_chat_completions',
      wire: { max_output_tokens: 'max_completion_tokens', json_schema: 'response_format' },
      parameters: [
        { id: 'max_output_tokens', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 1 } },
        { id: 'json_schema', support: 'supported', source: 'test', valueSchema: 'json-schema', strict: true },
      ],
    };
    const request = buildOpenAIRequest({
      providerKind: 'openAI', apiKey: 'k', modelID: 'o-fixture', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        generationProfile: profile,
        generationParameters: {
          max_output_tokens: { state: 'value', value: 2048 },
          json_schema: { state: 'value', value: schema },
        },
      },
    }, null, null, null, null, null, 'chat_completions');
    expect(request.url).toMatch(/\/chat\/completions$/);
    expect(request.body.max_completion_tokens).toBe(2048);
    expect(request.body).not.toHaveProperty('max_tokens');
    expect(request.body.response_format).toEqual({
      type: 'json_schema', json_schema: { name: 'oriveo_response', strict: true, schema },
    });
  });
});

function toProfile(raw: ModelLevelOutboundCase['profile']): GenerationParameterProfile {
  return {
    template: raw.template,
    wire: raw.wire,
    parameters: raw.parameters.map((parameter) => ({ support: 'supported', source: 'contract', ...parameter })),
  } as GenerationParameterProfile;
}

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
