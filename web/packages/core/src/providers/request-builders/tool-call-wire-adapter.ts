import { validateContinuation, type ContinuationIntent } from '../request-preference/continuation';
import { PROPOSE_MEMORY_TOOL_NAME } from '../../context/memory-propose';
import { SEARCH_MEMORY_TOOL_NAME } from '../../context/memory-search';
import { ContextContinuation } from '../../context/continuation';
import type { ProviderRequest, RequestParams } from './types';
import { markAnthropicCacheBreakpoint } from '../relay-adapter';
import { usesAnthropicExplicitPromptCache } from '../protocol-implementations';
import type { ProxyMessage, ProxyToolCall, ProxyToolDefinition } from './runtime';
import { buildOpenAIChatMessages, withImagePlaceholders } from './runtime';
import {
  attachmentTransportProfile,
  dispatchedAttachmentTransport,
  nativeFileBlockOf,
  outboundWireOf,
} from '../attachment-transport';

/** Wires whose image outbound is decided per model: the placeholder is written by the outbound sanitizer from the projection, and the builder sends images per the protocol. */
const VERDICT_GATED_IMAGE_TRANSPORTS: ReadonlySet<string> = new Set([
  'deepseek_chat',
  'minimax_chat',
  'minimax_anthropic_messages',
]);

export type WireProtocol = 'openai_chat' | 'openai_responses' | 'anthropic_messages' | 'gemini_generate';

type ToolCallWireParams = Pick<RequestParams, 'messages' | 'tools' | 'toolChoice'>
  & Partial<Pick<RequestParams, 'providerKind'>>
  & { options?: Pick<NonNullable<RequestParams['options']>, 'dynamicText'> };

/** Maps the canonical local-tool contract to the selected provider protocol. Server tools already
 * installed by an official recipe remain in the body and are never reclassified as client tools. */
export function applyToolCallWireAdapter(
  request: ProviderRequest,
  params: ToolCallWireParams,
): ProviderRequest {
  // The tool leg uses the same wire placeholder as a normal send: wires that can only send text replace each image with a placeholder line and send no image blocks.
  // Wires with per-model verdict outbound (DeepSeek / MiniMax) do not write placeholders here: image parts only exist when the projection says they can go out.
  const transport = params.providerKind
    ? dispatchedAttachmentTransport(params.providerKind, outboundWireOf(request))
    : null;
  const placeholder = transport && !VERDICT_GATED_IMAGE_TRANSPORTS.has(transport)
    ? attachmentTransportProfile(transport).imagePlaceholderText
    : undefined;
  const adapted = {
    ...request,
    body: adaptBody(protocolForRequest(request), request.body, {
      ...params,
      instructionsMode: request.continuationCapture?.instructionsMode,
      explicitPromptCache: usesAnthropicExplicitPromptCache(request.promptCachePolicyRef),
      messages: withImagePlaceholders(params.messages, placeholder),
    }),
  };
  return request.fallback
    ? { ...adapted, fallback: applyToolCallWireAdapter(request.fallback, params) }
    : adapted;
}

/**
 * The `tools` wire shape of a function tool on a given protocol: the tool leg and the Relay capability test share this one mapping,
 * so the tool shapes of the two paths cannot diverge.
 */
export function functionToolsForProtocol(protocol: WireProtocol, tools: ProxyToolDefinition[]): unknown[] {
  if (protocol === 'openai_chat') return tools;
  if (protocol === 'openai_responses') return tools.map(toResponsesTool);
  if (protocol === 'anthropic_messages') return tools.map(toAnthropicTool);
  return geminiTools(tools) ?? [];
}

function adaptBody(
  protocol: WireProtocol,
  original: Record<string, unknown>,
  params: ToolCallWireParams & { instructionsMode?: 'resend' | 'omit'; explicitPromptCache?: boolean },
): Record<string, unknown> {
  const body = { ...original };
  if (protocol === 'openai_chat') {
    // Native `file` blocks on a tool leg depend only on the wire table (currently only OpenRouter's tool leg keeps them).
    const chatTransport = params.providerKind
      ? dispatchedAttachmentTransport(params.providerKind, 'openai_chat')
      : null;
    body.messages = openAIChatMessages(
      params.messages,
      chatTransport !== null && nativeFileBlockOf({ transport: chatTransport, toolLoop: true }) === 'file',
    );
    appendTools(body, params.tools && functionToolsForProtocol(protocol, params.tools));
    if (params.tools?.length) body.tool_choice = params.toolChoice ?? 'auto';
    return body;
  }
  if (protocol === 'openai_responses') {
    // Within one tool loop system / model / checkpoint do not change, so the fingerprint counts as unchanged; the mode is still taken from the recipe only.
    const decision = ContextContinuation.decideContinuation({
      previousResponseId: latestPreviousResponseId(params.messages),
      instructionsMode: params.instructionsMode,
      systemChangedSinceLastLeg: false,
      modelChanged: false,
      checkpointChanged: false,
    });
    const mapped = responsesInput(params.messages, decision.kind === 'stateful');
    body.input = mapped.input;
    if (mapped.instructions && (decision.kind === 'fullPlan' || decision.sendInstructions)) body.instructions = mapped.instructions;
    else delete body.instructions;
    if (decision.kind === 'stateful') body.previous_response_id = decision.previousResponseId;
    else delete body.previous_response_id;
    appendTools(body, params.tools && functionToolsForProtocol(protocol, params.tools));
    if (params.tools?.length) body.tool_choice = params.toolChoice ?? 'auto';
    return body;
  }
  if (protocol === 'anthropic_messages') {
    const mapped = anthropicMessages(params.messages);
    // The tool loop assembles Anthropic turns itself: official Anthropic re-places the single breakpoint the same way as the builder (last non-[D] block of the tool_result turn),
    // and likewise only when the catalog verdict promptCache.policyRef is anthropic.explicit; other lines using the Messages endpoint, such as MiniMax, are left as they are.
    if (params.providerKind === 'anthropic' && params.explicitPromptCache) { // capability-lint-allow R2: Anthropic explicit cache breakpoint, unrelated to attachments
      markAnthropicCacheBreakpoint(mapped.messages as Array<Record<string, unknown>>, params.options?.dynamicText);
    }
    body.messages = mapped.messages;
    if (mapped.system) body.system = mapped.system;
    appendTools(body, params.tools && functionToolsForProtocol(protocol, params.tools));
    if (params.tools?.length) body.tool_choice = anthropicToolChoice(params.toolChoice);
    return body;
  }
  const mapped = geminiContents(params.messages);
  body.contents = mapped.contents;
  if (mapped.systemInstruction) body.systemInstruction = mapped.systemInstruction;
  appendTools(body, params.tools && functionToolsForProtocol(protocol, params.tools));
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
function openAIChatMessages(messages: ProxyMessage[], nativeFileBlock = false): Array<Record<string, unknown>> {
  const ordinary = buildOpenAIChatMessages(messages, { nativeFileBlock }) as Array<Record<string, unknown>>;
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

export function protocolForRequest(request: ProviderRequest): WireProtocol {
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

const HOST_MEMORY_TOOL_NAMES: readonly string[] = [PROPOSE_MEMORY_TOOL_NAME, SEARCH_MEMORY_TOOL_NAME];

function isHostMemoryTool(tool: ProxyToolDefinition): boolean {
  return isCanonicalTool(tool) && HOST_MEMORY_TOOL_NAMES.includes(tool.function.name);
}

/**
 * Host memory tools (propose_memory, then search_memory) go after the server tools the builder or a
 * recipe merged in; library / MCP tools keep their place. Gemini function declarations are one grouped entry:
 * a group made only of memory tools moves to the end as a whole, a group mixed with library / MCP tools stays.
 */
export function moveHostMemoryToolsLast(
  protocol: WireProtocol,
  body: Record<string, unknown>,
  tools: ProxyToolDefinition[] | undefined,
): void {
  const memoryTools = tools?.filter(isHostMemoryTool) ?? [];
  if (!memoryTools.length || !Array.isArray(body.tools)) return;
  if (protocol === 'gemini_generate') {
    const isMemoryGroup = (entry: unknown): boolean => isRecord(entry)
      && Array.isArray(entry.functionDeclarations)
      && entry.functionDeclarations.length > 0
      && entry.functionDeclarations.every((declaration) => isRecord(declaration)
        && typeof declaration.name === 'string' && HOST_MEMORY_TOOL_NAMES.includes(declaration.name));
    const groups = body.tools.filter(isMemoryGroup);
    if (groups.length) body.tools = [...body.tools.filter((entry) => !isMemoryGroup(entry)), ...groups];
    return;
  }
  const wire = functionToolsForProtocol(protocol, memoryTools);
  const identities = new Set(wire.map((entry) => JSON.stringify(entry)));
  body.tools = body.tools.filter((entry) => !identities.has(JSON.stringify(entry)));
  appendTools(body, wire);
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

function latestPreviousResponseIndex(messages: ProxyMessage[]): number {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (previousResponseID(messages[index]?.providerContinuation) != null) return index;
  }
  return -1;
}

function latestPreviousResponseId(messages: ProxyMessage[]): string | undefined {
  const index = latestPreviousResponseIndex(messages);
  return index >= 0 ? previousResponseID(messages[index]?.providerContinuation) : undefined;
}

/** stateful = chained on previous_response_id: only the tail after that response is sent. */
function responsesInput(messages: ProxyMessage[], stateful: boolean): {
  input: unknown[];
  instructions?: string;
} {
  const system = messages.filter((message) => message.role === 'system').map(textContent).filter(Boolean);
  const previousIndex = stateful ? latestPreviousResponseIndex(messages) : -1;
  const source = previousIndex >= 0 ? messages.slice(previousIndex + 1) : messages;
  const input: unknown[] = [];
  for (const message of source) {
    if (message.role === 'system') continue;
    if (message.role === 'tool') {
      input.push({ type: 'function_call_output', call_id: message.tool_call_id, output: textContent(message) });
      continue;
    }
    const content = message.role === 'assistant'
      ? (textContent(message) ? [{ type: 'output_text', text: textContent(message) }] : [])
      : userBlocks(message, (text) => ({ type: 'input_text', text }), (url) => ({ type: 'input_image', image_url: url }));
    if (content.length) input.push({ role: message.role, content });
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
  };
}

function anthropicMessages(messages: ProxyMessage[]): { system?: string; messages: unknown[] } {
  const system = messages.filter((message) => message.role === 'system').map(textContent).filter(Boolean);
  const output: Array<{ role: string; content: unknown[] }> = [];
  // Whether the trailing user turn holds tool_result blocks: every result of the same leg and the host
  // loop notice that follows them go into this one user turn, so no adjacent user turns are produced.
  let openToolTurn: { role: string; content: unknown[] } | undefined;
  for (const message of messages) {
    if (message.role === 'system') continue;
    if (message.role === 'tool') {
      const block = { type: 'tool_result', tool_use_id: message.tool_call_id, content: textContent(message) };
      if (openToolTurn) openToolTurn.content.push(block);
      else {
        openToolTurn = { role: 'user', content: [block] };
        output.push(openToolTurn);
      }
      continue;
    }
    if (message.role === 'user' && openToolTurn && typeof message.content === 'string') {
      if (message.content) openToolTurn.content.push({ type: 'text', text: message.content });
      continue;
    }
    openToolTurn = undefined;
    const replay = replayBlocks(message.providerContinuation, 'anthropic_messages');
    const content = replay ?? [
      ...userBlocks(message, (text) => ({ type: 'text', text }), (url) => {
        const data = base64DataURL(url);
        return data ? { type: 'image', source: { type: 'base64', media_type: data.mimeType, data: data.data } } : undefined;
      }),
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
  // Same as Anthropic: the leg's functionResponse parts and the host loop notice after them share one user content.
  let openToolTurn: { role: string; parts: unknown[] } | undefined;
  for (const message of messages) {
    if (message.role === 'system') continue;
    if (message.role === 'tool') {
      const part = { functionResponse: {
        name: callNames.get(message.tool_call_id ?? '') ?? 'unknown_tool',
        response: jsonObject(textContent(message)),
      } };
      if (openToolTurn) openToolTurn.parts.push(part);
      else {
        openToolTurn = { role: 'user', parts: [part] };
        contents.push(openToolTurn);
      }
      continue;
    }
    if (message.role === 'user' && openToolTurn && typeof message.content === 'string') {
      if (message.content) openToolTurn.parts.push({ text: message.content });
      continue;
    }
    openToolTurn = undefined;
    const replay = replayBlocks(message.providerContinuation, 'gemini_generate_content');
    if (replay) {
      contents.push(...replay);
      continue;
    }
    contents.push({
      role: message.role === 'assistant' ? 'model' : 'user',
      parts: [
        ...userBlocks(message, (text) => ({ text }), (url) => {
          const data = base64DataURL(url);
          return data ? { inlineData: { mimeType: data.mimeType, data: data.data } } : undefined;
        }),
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
  // A later part that already starts with a line break (transport's "\n\n" + [D]) is not joined with another one.
  return message.content.filter((part) => part.type === 'text').map((part) => part.text)
    .reduce((joined, text, index) => (index === 0 || text.startsWith('\n') ? joined + text : `${joined}\n${text}`), '');
}

/** Transport appends [D] as its own text part prefixed with "\n\n"; as a separate block that separator is redundant. */
function withoutPartSeparator(text: string, isFirstText: boolean): string {
  return isFirstText ? text : text.replace(/^\n\n/, '');
}

/** Convert a user message block by block (body + images), consistent with the main-chat builders; other roles and plain text yield a single text block.
 * Image blocks were already handled per line by withImagePlaceholders, so only the shape is converted here. */
function userBlocks(
  message: ProxyMessage,
  text: (value: string) => Record<string, unknown>,
  image: (url: string) => Record<string, unknown> | undefined,
): Array<Record<string, unknown>> {
  if (message.role !== 'user' || typeof message.content === 'string') {
    const value = textContent(message);
    return value ? [text(value)] : [];
  }
  const blocks: Array<Record<string, unknown>> = [];
  let seenText = false;
  for (const part of message.content) {
    if (part.type === 'text') {
      const value = withoutPartSeparator(part.text, !seenText);
      if (part.text) seenText = true;
      if (value) blocks.push(text(value));
    } else if (part.type === 'image_url') {
      const block = image(part.image_url.url);
      if (block) blocks.push(block);
    }
  }
  return blocks;
}

function base64DataURL(url: string): { mimeType: string; data: string } | undefined {
  const matched = url.match(/^data:([^;]+);base64,(.+)$/);
  return matched ? { mimeType: matched[1], data: matched[2] } : undefined;
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
