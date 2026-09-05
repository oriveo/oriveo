import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { mergeExecutionResponse } from './execution-response';

describe('adapter execution response headers', () => {
  it('preserves body/status/adapter headers and frozen headers for all adapter response shapes', async () => {
    for (const adapter of ['moonshot-loop', 'formula-fiber', 'minimax-chat', 'gemini-interactions']) {
      const response = mergeExecutionResponse(new Response(adapter, { status: 200, headers: { 'X-Adapter': adapter } }), { 'X-Oriveo-Capability-Result': 'frozen-r3' }, { kind: 'tool_loop', protocol: 'openai_chat', responseParserKind: 'moonshot_builtin_web_v1' });
      expect(await response.text()).toBe(adapter);
      expect(response.headers.get('X-Adapter')).toBe(adapter);
      expect(response.headers.get('X-Oriveo-Capability-Result')).toBe('frozen-r3');
      expect(response.headers.get('X-Oriveo-Continuation-Kind')).toBe('tool_loop');
    }
  });

  it('keeps all streaming adapter route branches behind the execution-header merger', () => {
    const route = readFileSync(resolve(process.cwd(), 'app/api/chat/stream/route.ts'), 'utf8');
    for (const branch of [
      'adaptMoonshotToolLoopResponse(upstream, activeReq)',
      'adaptMoonshotFormulaFiberResponse(upstream, activeReq, request.signal)',
      'adaptMiniMaxChatStream(upstream)',
      'adaptGeminiInteractionsResponse(upstream)',
    ]) {
      expect(route).toMatch(new RegExp(`withExecutionHeaders\\(await ${branch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
    }
  });
});
