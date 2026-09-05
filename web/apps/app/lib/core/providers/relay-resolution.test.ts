import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildRelayCapabilityBitmap } from './relay-resolution';

describe('buildRelayCapabilityBitmap', () => {
  it.each([
    ['openai_chat_completions', 'chatCompletions'],
    ['openai_responses', 'responses'],
    ['anthropic_messages', 'messages'],
    ['gemini_generate_content', 'geminiGenerateContent'],
  ] as const)('maps %s through the single transport authority', (transport, enabled) => {
    const bitmap = buildRelayCapabilityBitmap(transport);
    expect(bitmap).toMatchObject({ modelsList: false, [enabled]: true });
    expect(Object.values(bitmap).filter(Boolean)).toHaveLength(1);
  });

  it('accepts catalog evidence only as the models-list override', () => {
    expect(buildRelayCapabilityBitmap('openai_chat_completions', {
      catalogEvidenceSucceeded: true,
    })).toEqual({
      modelsList: true,
      responses: false,
      chatCompletions: true,
      messages: false,
      geminiGenerateContent: false,
    });
  });
});

describe('relay capability bitmap structure guard', () => {
  const source = (relativePath: string): string => readFileSync(
    resolve(process.cwd(), relativePath),
    'utf8',
  );

  it.each([
    'app/providers/relay/new/RelaySetup.tsx',
    'app/providers/relay/new/LocalComputeSetup.tsx',
    'lib/core/provider-ops.ts',
  ])('%s delegates its bitmap to relay-resolution', (relativePath) => {
    const content = source(relativePath);
    expect(content).toContain('buildRelayCapabilityBitmap(');
    expect(content).not.toMatch(/relayCapabilityBitmap:\s*\{/);
  });
});
