/** Gemini Interactions API builder.
 *
 * This is deliberately separate from generateContent: the route is selected only by a
 * server recipe with `route.protocol=gemini_interactions`, never by a local model-name
 * list. `input` is always Step[] (user_input / model_output); every turn is sent in full,
 * there is no previous_interaction_id replay. Thinking values come only from the server
 * reasoning recipe compiled by the shared capability compiler.
 */
import { resolveProviderBaseURL } from '../url-utils';
import { attachmentTransportProfile, mediaTextFallback } from '../attachment-transport';
import type { ContentPart } from '../types';
import { parseDataURL, withImagePlaceholders, type ProxyMessage } from './runtime';
import { credentialHeader } from './generation-parameters';
import { STREAM_HEADERS, JSON_HEADERS, type ProviderRequest, type RequestParams } from './types';
import { applyCapabilityRecipes, isGeminiInteractionsPath, type EndpointRouteRecipe, type RuntimeRecipe } from './capability-execution';

export interface GeminiInteractionsBuildOptions {
  webRecipe?: RuntimeRecipe;
  reasoningRecipe?: RuntimeRecipe;
  /** null / undefined = automatic tier: the reasoning recipe writes only the base ops that have no intent. */
  reasoningIntent?: string | null;
  /** Production is fixed at pre_activation (images become a placeholder, files were already turned into text upstream); activated is passed only in tests, and the tier is raised after real samples are verified. */
  attachmentProfile?: 'pre_activation' | 'activated';
}

type InteractionContent =
  | { type: 'text'; text: string }
  | { type: 'image' | 'document'; data: string; mime_type: string };

export function buildGeminiInteractionsRequest(
  params: RequestParams,
  route: EndpointRouteRecipe,
  options: GeminiInteractionsBuildOptions = {},
): ProviderRequest {
  if (!isGeminiInteractionsPath(route.path)) {
    throw new Error(`Gemini Interactions route path is not allowed: ${route.path}`);
  }
  const activated = options.attachmentProfile === 'activated';
  const messages = activated
    ? params.messages
    : withImagePlaceholders(params.messages, attachmentTransportProfile('gemini_interactions').imagePlaceholderText);
  const stream = params.stream !== false;
  const systemInstruction = systemText(messages);
  const base: Record<string, unknown> = {
    model: params.modelID,
    ...(systemInstruction ? { system_instruction: systemInstruction } : {}),
    input: interactionSteps(messages, activated),
    stream,
    store: false,
  };
  const recipes = [options.webRecipe, options.reasoningRecipe].filter((recipe): recipe is RuntimeRecipe => recipe != null);
  const body = recipes.length > 0
    ? applyCapabilityRecipes(base, recipes, { reasoning: options.reasoningIntent ?? undefined }, [], { automaticReasoningBaseOps: true }).body
    : base;

  return {
    // Existing Gemini default base already carries /v1beta for generateContent; the
    // route recipe carries its own canonical versioned path, so remove it once.
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL).replace(/\/v1(?:beta)?$/i, '')}${route.path}`,
    headers: {
      ...(stream ? STREAM_HEADERS : JSON_HEADERS),
      ...credentialHeader('x-goog-api-key', params.apiKey),
    },
    body,
    responseAdapter: 'gemini_interactions',
  };
}

function systemText(messages: ProxyMessage[]): string {
  return messages
    .filter((message) => message.role === 'system')
    .map((message) => textOf(message.content).trim())
    .filter(Boolean)
    .join('\n\n');
}

function textOf(content: string | ContentPart[]): string {
  return typeof content === 'string'
    ? content
    : content.flatMap((part) => part.type === 'text' ? [part.text] : []).join('\n');
}

function interactionSteps(messages: ProxyMessage[], activated: boolean): Array<{ type: string; content: InteractionContent[] }> {
  const steps: Array<{ type: string; content: InteractionContent[] }> = [];
  for (const message of messages) {
    if (message.role === 'user') {
      const content = userContent(message.content, activated);
      if (content.length > 0) steps.push({ type: 'user_input', content });
    } else if (message.role === 'assistant') {
      // The first version replays only the body text; thinking and signatures are not replayed. A turn whose body is only whitespace (a failure / interruption that wrote no body) is not replayed.
      const text = textOf(message.content);
      if (text.trim()) steps.push({ type: 'model_output', content: [{ type: 'text', text }] });
    }
    // system already went into system_instruction; this route sends no client tools, so there is no tool leg.
  }
  return steps;
}

function userContent(content: string | ContentPart[], activated: boolean): InteractionContent[] {
  if (typeof content === 'string') return content ? [{ type: 'text', text: content }] : [];
  const texts: InteractionContent[] = [];
  const media: InteractionContent[] = [];
  for (const part of content) {
    if (part.type === 'text') {
      if (part.text) texts.push({ type: 'text', text: part.text });
      continue;
    }
    // pre_activation: images were already replaced by placeholder text and files were already turned into text by the attachment injector, so no media bytes go out.
    if (!activated) continue;
    const data = part.type === 'image_url' ? parseDataURL(part.image_url.url)
      : part.type === 'file' ? parseDataURL(part.file.file_data)
        : null;
    if (!data) {
      // A data URL image that cannot be parsed is written as a placeholder, same as Anthropic, and not silently dropped; files are still skipped.
      if (part.type === 'image_url') media.push({ type: 'text', text: mediaTextFallback('image', part.image_url.url, 'gemini_interactions') });
      continue;
    }
    media.push({ type: part.type === 'image_url' ? 'image' : 'document', data: data.base64, mime_type: data.mimeType });
  }
  // Text first and media after within one turn (the official image understanding guide).
  return [...texts, ...media];
}
