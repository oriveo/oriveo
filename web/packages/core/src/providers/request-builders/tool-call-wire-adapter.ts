import { validateContinuation, type ContinuationIntent } from '../request-preference/continuation';
import type { ProviderRequest, RequestParams } from './types';
import type { ProxyMessage, ProxyToolCall, ProxyToolDefinition } from './runtime';
import { buildOpenAIChatMessages } from './runtime';

type WireProtocol = 'openai_chat' | 'openai_responses' | 'anthropic_messages' | 'gemini_generate';

/** Maps the canonical local-tool contract to the selected provider protocol. Server tools already
 * installed by an official recipe remain in the body and are never reclassified as client tools. */
export function applyToolCallWireAdapter(
  request: ProviderRequest,
  params: Pick<RequestParams, 'messages' | 'tools' | 'toolChoice'>,
): ProviderRequest {
  const adapted = {
    ...request,
    body: adaptBody(protocolForRequest(request), request.body, params),
  };
  return request.fallback
    ? { ...adapted, fallback: applyToolCallWireAdapter(request.fallback, params) }
    : adapted;
}

function adaptBody(
  protocol: WireProtocol,
  original: Record<string, unknown>,
  params: Pick<RequestParams, 'messages' | 'tools' | 'toolChoice'>,
): Record<string, unknown> {
  const body = { ...original };
  if (protocol === 'openai_chat') {
    body.messages = openAIChatMessages(params.messages);
    appendTools(body, params.tools);
    if (params.tools?.length) body.tool_choice = params.toolChoice ?? 'auto';
    return body;
  }
  if (protocol === 'openai_responses') {
    const mapped = responsesInput(params.messages);
    body.input = mapped.input;
    if (mapped.instructions) body.instructions = mapped.instructions;
    else delete body.instructions;
    if (mapped.previousResponseId) body.previous_response_id = mapped.previousResponseId;
    appendTools(body, params.tools?.map(toResponsesTool));
    if (params.tools?.length) body.tool_choice = params.toolChoice ?? 'auto';
    return body;
  }
  if (protocol === 'anthropic_messages') {
    const mapped = anthropicMessages(params.messages);
    body.messages = mapped.messages;
    if (mapped.system) body.system = mapped.system;
    appendTools(body, params.tools?.map(toAnthropicTool));
    if (params.tools?.length) body.tool_choice = anthropicToolChoice(params.toolChoice);
    return body;
  }
  const mapped = geminiContents(params.messages);
  body.contents = mapped.contents;
  if (mapped.systemInstruction) body.systemInstruction = mapped.systemInstruction;
  appendTools(body, geminiTools(params.tools));
  if (params.tools?.length) {
    body.toolConfig = {
      functionCallingConfig: { mode: geminiToolChoice(params.toolChoice) },
    };
  }
  return body;
}

/**
 * OpenAI-compatible reasoning providers require the exact assistant message from the previous
 * tool-call leg. The neutral history deliberately stores opaque provider fields in a local-only
 * continuation sidecar, so the ordinary message builder cannot see them. Replay only a validated
 * single assistant message whose tool-call identity still matches the neutral history; corrupt or
 * stale sidecars fail closed to the ordinary message shape instead of crossing the provider wire.
 */
function openAIChatMessages(messages: ProxyMessage[]): Array<Record<string, unknown>> {
  const ordinary = buildOpenAIChatMessages(messages) as Array<Record<string, unknown>>;
  return ordinary.map((encoded, index) => {
    const source = messages[index];
    const continuation = source?.providerContinuation;
    if (source?.role !== 'assistant'
      || continuation?.kind !== 'replay_reasoning'
      || !validateContinuation(continuation).accepted) return encoded;
    const assistantMessages = continuation.state.assistantMessages;
    if (!Array.isArray(assistantMessages) || assistantMessages.length !== 1) return encoded;
    const replay = assistantMessages[0];
    if (!isRecord(replay) || replay.role !== 'assistant'
      || !sameToolCalls(encoded.tool_calls, replay.tool_calls)) return encoded;
    return replay;
  });
}

function sameToolCalls(left: unknown, right: unknown): boolean {
  if (!Array.isArray(left) || left.length === 0 || !Array.isArray(right)) return false;
  return JSON.stringify(left) === JSON.stringify(right);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value != null && !Array.isArray(value);
}

function protocolForRequest(request: ProviderRequest): WireProtocol {
  if (/\/responses(?:\?|$)/.test(request.url)) return 'openai_responses';
  if (/\/messages(?:\?|$)/.test(request.url)) return 'anthropic_messages';
  if (/:streamGenerateContent(?:\?|$)|:generateContent(?:\?|$)/.test(request.url)) return 'gemini_generate';
  return 'openai_chat';
}

function appendTools(body: Record<string, unknown>, tools: unknown[] | undefined): void {
  if (!tools?.length) return;
  const existing = Array.isArray(body.tools) ? body.tools : [];
  const seen = new Set(existing.map((tool) => JSON.stringify(tool)));
  body.tools = [...existing, ...tools.filter((tool) => {
    const identity = JSON.stringify(tool);
    if (seen.has(identity)) return false;
    seen.add(identity);
    return true;
  })];
}

function toResponsesTool(tool: ProxyToolDefinition): Record<string, unknown> {
  if (!isCanonicalTool(tool)) return tool as unknown as Record<string, unknown>;
  return {
    type: 'function',
    name: tool.function.name,
    description: tool.function.description,
    parameters: tool.function.parameters,
  };
}

export function toAnthropicTool(tool: ProxyToolDefinition): Record<string, unknown> {
  if (!isCanonicalTool(tool)) return tool as unknown as Record<string, unknown>;
  return {
    name: tool.function.name,
    description: tool.function.description,
    input_schema: tool.function.parameters,
  };
}

function toGeminiDeclaration(tool: ProxyToolDefinition): Record<string, unknown> {
  return {
    name: tool.function.name,
    description: tool.function.description,
    parameters: normalizeGeminiSchema(tool.function.parameters),
  };
}

function geminiTools(tools: ProxyToolDefinition[] | undefined): unknown[] | undefined {
  if (!tools?.length) return undefined;
  const canonical = tools.filter(isCanonicalTool);
  const protocolNative = tools.filter((tool) => !isCanonicalTool(tool));
  return [
    ...protocolNative,
    ...(canonical.length
      ? [{ functionDeclarations: canonical.map(toGeminiDeclaration) }]
      : []),
  ];
}

function isCanonicalTool(tool: ProxyToolDefinition): boolean {
  const value = tool as unknown as Record<string, unknown>;
  const fn = value.function;
  return value.type === 'function' && fn != null && typeof fn === 'object' && !Array.isArray(fn);
}

function responsesInput(messages: ProxyMessage[]): {
  input: unknown[];
  instructions?: string;
  previousResponseId?: string;
} {
  const system = messages.filter((message) => message.role === 'system').map(textContent).filter(Boolean);
  let previousIndex = -1;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (previousResponseID(messages[index]?.providerContinuation) != null) {
      previousIndex = index;
      break;
    }
  }
  const previousResponseId = previousIndex >= 0
    ? previousResponseID(messages[previousIndex]?.providerContinuation)
    : undefined;
  const source = previousIndex >= 0 ? messages.slice(previousIndex + 1) : messages;
  const input: unknown[] = [];
  for (const message of source) {
    if (message.role === 'system') continue;
    if (message.role === 'tool') {
      input.push({ type: 'function_call_output', call_id: message.tool_call_id, output: textContent(message) });
      continue;
    }
    const content = textContent(message);
    if (content) {
      input.push({
        role: message.role,
        content: [{ type: message.role === 'assistant' ? 'output_text' : 'input_text', text: content }],
      });
    }
    for (const call of message.tool_calls ?? []) {
      input.push({
        type: 'function_call',
        call_id: call.id,
        name: call.function.name,
        arguments: call.function.arguments,
      });
    }
  }
  return {
    input,
    ...(system.length ? { instructions: system.join('\n\n') } : {}),
    ...(previousResponseId ? { previousResponseId } : {}),
  };
}

function anthropicMessages(messages: ProxyMessage[]): { system?: string; messages: unknown[] } {
  const system = messages.filter((message) => message.role === 'system').map(textContent).filter(Boolean);
  const output: unknown[] = [];
  for (const message of messages) {
    if (message.role === 'system') continue;
    if (message.role === 'tool') {
      output.push({
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: message.tool_call_id, content: textContent(message) }],
      });
      continue;
    }
    const replay = replayBlocks(message.providerContinuation, 'anthropic_messages');
    const content = replay ?? [
      ...(textContent(message) ? [{ type: 'text', text: textContent(message) }] : []),
      ...(message.tool_calls ?? []).map(toAnthropicToolUse),
    ];
    output.push({ role: message.role, content });
  }
  return { ...(system.length ? { system: system.join('\n\n') } : {}), messages: output };
}

function geminiContents(messages: ProxyMessage[]): {
  contents: unknown[];
  systemInstruction?: { parts: Array<{ text: string }> };
} {
  const system = messages.filter((message) => message.role === 'system').map(textContent).filter(Boolean);
  const callNames = new Map<string, string>();
  for (const message of messages) {
    for (const call of message.tool_calls ?? []) callNames.set(call.id, call.function.name);
  }
  const contents: unknown[] = [];
  for (const message of messages) {
    if (message.role === 'system') continue;
    if (message.role === 'tool') {
      contents.push({
        role: 'user',
        parts: [{ functionResponse: {
          name: callNames.get(message.tool_call_id ?? '') ?? 'unknown_tool',
          response: jsonObject(textContent(message)),
        } }],
      });
      continue;
    }
    const replay = replayBlocks(message.providerContinuation, 'gemini_generate_content');
    if (replay) {
      contents.push(...replay);
      continue;
    }
    contents.push({
      role: message.role === 'assistant' ? 'model' : 'user',
      parts: [
        ...(textContent(message) ? [{ text: textContent(message) }] : []),
        ...(message.tool_calls ?? []).map((call) => ({ functionCall: {
          name: call.function.name,
          args: jsonObject(call.function.arguments),
        } })),
      ],
    });
  }
  return {
    contents,
    ...(system.length ? { systemInstruction: { parts: [{ text: system.join('\n\n') }] } } : {}),
  };
}

function toAnthropicToolUse(call: ProxyToolCall): Record<string, unknown> {
  return { type: 'tool_use', id: call.id, name: call.function.name, input: jsonObject(call.function.arguments) };
}

function anthropicToolChoice(choice: RequestParams['toolChoice']): Record<string, unknown> {
  return { type: choice === 'required' ? 'any' : choice ?? 'auto' };
}

function geminiToolChoice(choice: RequestParams['toolChoice']): 'AUTO' | 'NONE' | 'ANY' {
  return choice === 'none' ? 'NONE' : choice === 'required' ? 'ANY' : 'AUTO';
}

function replayBlocks(
  continuation: ContinuationIntent | undefined,
  protocol: string,
): unknown[] | undefined {
  if (continuation?.kind !== 'replay_blocks') return undefined;
  const blocks = continuation.state.blocks;
  if (!Array.isArray(blocks)) return undefined;
  if (protocol === 'gemini_generate_content') return blocks;
  return blocks;
}

function previousResponseID(continuation: ContinuationIntent | undefined): string | undefined {
  const value = continuation?.kind === 'previous_id' ? continuation.state.previousResponseId : undefined;
  return typeof value === 'string' && value ? value : undefined;
}

function textContent(message: ProxyMessage): string {
  if (typeof message.content === 'string') return message.content;
  return message.content.filter((part) => part.type === 'text').map((part) => part.text).join('\n');
}

function jsonObject(raw: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(raw);
    return parsed != null && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : { output: parsed };
  } catch {
    return { output: raw };
  }
}

function normalizeGeminiSchema(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalizeGeminiSchema);
  if (!value || typeof value !== 'object') return value;
  const input = value as Record<string, unknown>;
  const output: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(input)) {
    if (key === 'additionalProperties') continue;
    if (key === 'type' && Array.isArray(item) && item.includes('null')) {
      output.type = item.find((entry) => entry !== 'null') ?? 'string';
      output.nullable = true;
      continue;
    }
    output[key] = normalizeGeminiSchema(item);
  }
  return output;
}
