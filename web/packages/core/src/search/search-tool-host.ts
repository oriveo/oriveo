// External web search: tool host table for regular chat.
// Reference implementation: scripts/lib/search-tool-host.mjs (same names and semantics on every client). Continuation steps are read from this client's CONTINUATION_KINDS table, not copied.

import { CONTINUATION_KINDS } from '../providers/request-preference/continuation';

// Same semantics as ToolCallLoop.Limits: effective value = min(server-provided, 8), default 6
export const LOOP_LIMITS = Object.freeze({ hardCap: 8, defaultMaxSteps: 6 });

export interface ThinkingToolRule {
  thinkingWithTools: 'tool_loop' | 'presearch';
  replay: string;
}

/**
 * Protocol rules for tools in thinking mode.
 * thinkingWithTools: tool_loop = tools may run while thinking is on (continuation state is passed back per replay); presearch = switch to pre-search when thinking is on.
 */
export const THINKING_TOOL_RULES: Readonly<Record<string, ThinkingToolRule>> = Object.freeze({
  openai_chat: { thinkingWithTools: 'presearch', replay: 'since GPT-5.4, Chat does not support tool calls when reasoning_effort is not none' },
  openai_responses: { thinkingWithTools: 'tool_loop', replay: 'send back the reasoning item together with function_call / output; with store=false also send back encrypted_content' },
  anthropic_messages: { thinkingWithTools: 'tool_loop', replay: 'send thinking / redacted_thinking blocks back unchanged, with their signature' },
  gemini_generate_content: { thinkingWithTools: 'tool_loop', replay: 'put thoughtSignature back on the original part; needed at every step of this turn' },
  deepseek_chat: { thinkingWithTools: 'tool_loop', replay: 'with tools, reasoning_content of all past turns must be sent back' },
  moonshot_chat: { thinkingWithTools: 'tool_loop', replay: 'reasoning_content must be sent back; across turns it depends on the model' },
  zhipu_chat: { thinkingWithTools: 'tool_loop', replay: 'send back reasoning_content within the loop; across turns it depends on clear_thinking' },
  qwen_chat: { thinkingWithTools: 'tool_loop', replay: 'with preserve_thinking, history carries reasoning_content; tool_choice must not be required' },
});

export const HOST_PROMPTS = Object.freeze({
  // Search-only (optionally with memory tools) uses the loop's neutral default copy; when enabled together with library / MCP, that loop's existing copy is kept
  neutral: { stoppedErrorCode: 'tool_loop_stopped' },
  library: { stoppedErrorCode: 'research_stopped' },
  mcp: { stoppedErrorCode: 'tool_loop_stopped' },
});

export interface SearchToolHostInput {
  path: string;
  library?: boolean;
  mcp?: boolean;
  memoryTools?: boolean;
  nativeMoonshotLoop?: boolean;
  serverMaxSteps?: number | null;
  continuationKind?: string;
}

export type SearchToolHost =
  | { host: 'none' | 'moonshot_loop'; tools: string[]; webSearchRegistered: false; unchanged: true }
  | {
      host: 'shared_tool_loop' | 'generic_tool_loop';
      tools: string[];
      webSearchRegistered: true;
      maxSteps: number;
      prompts: keyof typeof HOST_PROMPTS;
      consecutiveFailureBreaker: 'off' | 3;
      webSearchDisposition: 'neutral';
      writeToolConfirm: 'once_when_web_results_present' | 'n/a';
      memoryTailLeg: 'in_loop' | 'n/a';
    };

export function resolveSearchToolHost(input: SearchToolHostInput): SearchToolHost {
  const { path } = input;
  if (path !== 'external_tool') {
    if (input.nativeMoonshotLoop === true && path === 'native') {
      return { host: 'moonshot_loop', tools: [], webSearchRegistered: false, unchanged: true };
    }
    return { host: 'none', tools: [], webSearchRegistered: false, unchanged: true };
  }
  const serverMaxSteps = input.serverMaxSteps;
  const server =
    typeof serverMaxSteps === 'number' && Number.isInteger(serverMaxSteps) && serverMaxSteps > 0
      ? Math.min(serverMaxSteps, LOOP_LIMITS.hardCap)
      : LOOP_LIMITS.defaultMaxSteps;
  const kind = input.continuationKind ?? '';
  const spec = Object.prototype.hasOwnProperty.call(CONTINUATION_KINDS, kind)
    ? (CONTINUATION_KINDS as Record<string, { maxSteps: number }>)[kind]
    : undefined;
  if (spec === undefined) throw new Error(`unknown continuationKind: ${input.continuationKind}`);
  const maxSteps = Math.min(server, spec.maxSteps);
  const tools: string[] = [];
  if (input.library) tools.push('library');
  if (input.mcp) tools.push('mcp');
  if (input.memoryTools) tools.push('memory');
  tools.push('web_search');
  const shared = input.library || input.mcp;
  return {
    host: shared ? 'shared_tool_loop' : 'generic_tool_loop',
    tools,
    webSearchRegistered: true,
    maxSteps,
    prompts: input.library ? 'library' : input.mcp ? 'mcp' : 'neutral',
    // With MCP, the circuit breaker is off; web_search failures are always fed back at the neutral level and do not count toward consecutive failures
    consecutiveFailureBreaker: input.mcp ? 'off' : 3,
    webSearchDisposition: 'neutral',
    // When web results enter the context this turn, MCP write tools are forced to "this time only" confirmation
    writeToolConfirm: input.mcp ? 'once_when_web_results_present' : 'n/a',
    // Memory tools join the same loop and take one tool step; no separate tail leg is added
    memoryTailLeg: input.memoryTools ? 'in_loop' : 'n/a',
  };
}
