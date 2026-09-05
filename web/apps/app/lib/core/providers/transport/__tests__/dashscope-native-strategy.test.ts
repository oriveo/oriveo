/**
 * Unit tests for the dashscope_native strategy parsing chunk fixtures
 *
 * Covers the native Qwen DashScope shape: output.choices[].message.content + output.search_info.search_results
 */

import { describe, expect, it } from 'vitest';
import { dashscopeNativeStrategy } from '../strategies/dashscope-native';
import { createStreamContext } from '../transport-strategy';

function toArr(result: ReturnType<typeof dashscopeNativeStrategy.parseStreamChunk>) {
  if (result == null) return [];
  return Array.isArray(result) ? result : [result];
}

describe('dashscopeNativeStrategy.buildRequestBody', () => {
  it('wraps parameters.result_format=message and incremental_output=true', () => {
    const body = dashscopeNativeStrategy.buildRequestBody({
      modelID: 'qwen-plus',
      messages: [{ role: 'user', content: 'hi' }],
    });
    const params = body.parameters as { result_format: string; incremental_output: boolean };
    expect(params.result_format).toBe('message');
    expect(params.incremental_output).toBe(true);
  });

  it('injects parameters.enable_search from mergeParams', () => {
    const body = dashscopeNativeStrategy.buildRequestBody({
      modelID: 'qwen-plus',
      messages: [{ role: 'user', content: 'hi' }],
      mergeParams: { parameters: { enable_search: true } },
    });
    const params = body.parameters as { enable_search?: boolean };
    expect(params.enable_search).toBe(true);
  });

  it('injects thinking_budget for relay with reasoning=deep', () => {
    const body = dashscopeNativeStrategy.buildRequestBody({
      modelID: 'qwen-max',
      messages: [{ role: 'user', content: 'hi' }],
      providerKind: 'relay',
      options: { reasoning: 'deep' },
    });
    const params = body.parameters as { enable_thinking?: boolean; thinking_budget?: number };
    expect(params.enable_thinking).toBe(true);
    expect(params.thinking_budget).toBeGreaterThan(0);
  });

  it('does not inject the local thinking_budget mapping for an official provider kind with reasoning=deep', () => {
    const body = dashscopeNativeStrategy.buildRequestBody({
      modelID: 'qwen-max',
      messages: [{ role: 'user', content: 'hi' }],
      providerKind: 'qwen',
      options: { reasoning: 'deep' },
    });
    const params = body.parameters as { enable_thinking?: boolean; thinking_budget?: number };
    expect(params.enable_thinking).toBeUndefined();
    expect(params.thinking_budget).toBeUndefined();
  });
});

describe('dashscopeNativeStrategy.parseStreamChunk', () => {
  it('chunk 1: output.choices[0].message.content emit delta', () => {
    const ctx = createStreamContext();
    const events = toArr(
      dashscopeNativeStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          output: {
            choices: [{ message: { content: 'Hello' } }],
          },
        }),
        ctx,
        null,
      ),
    );
    expect(events).toContainEqual({ type: 'delta', content: 'Hello' });
  });

  it('chunk 2: output.search_info.search_results emit citations event', () => {
    const ctx = createStreamContext();
    const events = toArr(
      dashscopeNativeStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          output: {
            search_info: {
              search_results: [
                { url: 'https://aliyun.com', title: 'Ali', site_name: 'Aliyun' },
              ],
            },
          },
        }),
        ctx,
        null,
      ),
    );
    const cit = events.find((e) => e.type === 'citations');
    expect(cit).toBeDefined();
    if (cit?.type === 'citations') {
      expect(cit.citations[0].url).toBe('https://aliyun.com');
    }
  });

  it('chunk 3: usage chunk emit input/output tokens', () => {
    const ctx = createStreamContext();
    const events = toArr(
      dashscopeNativeStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          usage: { input_tokens: 12, output_tokens: 34, total_tokens: 46 },
        }),
        ctx,
        null,
      ),
    );
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    if (usage?.type === 'usage') {
      expect(usage.usage.prompt_tokens).toBe(12);
      expect(usage.usage.completion_tokens).toBe(34);
    }
  });
});
