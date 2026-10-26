import { describe, expect, it } from 'vitest';
import {
  TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER,
  TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER,
} from '../attachment-transport';
import {
  convertToAnthropicParts as relayAnthropicParts,
  convertToGeminiParts as relayGeminiParts,
} from '../relay-adapter';
import { convertToAnthropicParts as strategyAnthropicParts } from '../transport/strategies/anthropic-messages';
import { partsToString as dashscopePartsToString } from '../transport/strategies/dashscope-native';
import { convertToGeminiParts as strategyGeminiParts } from '../transport/strategies/gemini-generate';
import { buildResponsesContent as strategyResponsesContent } from '../transport/strategies/openai-responses';
import {
  buildAnthropicRequestPayload,
  buildDashScopeMessages,
  buildGeminiContents,
  type ProxyMessage,
} from '../request-builders/runtime';
import { buildGeminiInteractionsRequest } from '../request-builders/gemini-interactions';
import type { ContentPart } from '../types';

// When a protocol does not accept some media and degrades it to body text, a data: URL is replaced by the route placeholder; inline base64 is never written into the text.
const VIDEO_B64 = 'data:video/mp4;base64,AAAAIGZ0eXBpc29t';
const IMAGE_B64 = 'data:image/png;base64,iVBORw0KGgo=';
// A data URL without ;base64, does not match the native-block regex and falls into the text-degradation branch.
const IMAGE_PLAIN_DATA = 'data:image/svg+xml,%3Csvg%20xmlns%3D%22x%22%2F%3E';
const VIDEO_PLAIN_DATA = 'data:video/mp4,raw-bytes';
const IMAGE_HTTPS = 'https://example.com/cat.png';
const VIDEO_HTTPS = 'https://example.com/clip.mp4';

const image = (url: string): ContentPart => ({ type: 'image_url', image_url: { url } });
const video = (url: string): ContentPart => ({ type: 'video_url', video_url: { url } });
const user = (content: ContentPart[]): ProxyMessage => ({ role: 'user', content } as ProxyMessage);

/** Collect every text in the output: the string itself, or the value of a `text` key in an object. */
function texts(value: unknown): string[] {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(texts);
  if (value && typeof value === 'object') {
    return Object.entries(value as Record<string, unknown>).flatMap(([key, child]) => (
      key === 'text' && typeof child === 'string' ? [child] : typeof child === 'string' ? [] : texts(child)
    ));
  }
  return [];
}

function expectNoInlineData(body: string[]) {
  for (const text of body) {
    expect(text).not.toContain('base64,');
    expect(text).not.toContain('data:');
  }
}

describe('media text fallback never writes data URLs into the body', () => {
  it('relay-adapter convertToAnthropicParts: base64 video → video placeholder', () => {
    const body = texts(relayAnthropicParts([video(VIDEO_B64)]));
    expectNoInlineData(body);
    expect(body).toContain(TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER);
  });

  it('relay-adapter convertToGeminiParts: non-base64 data video → video placeholder', () => {
    const out = relayGeminiParts([video(VIDEO_PLAIN_DATA), video(VIDEO_B64)]);
    expectNoInlineData(texts(out));
    expect(out[0]).toEqual({ text: TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER });
    expect(out[1]).toEqual({ inlineData: { mimeType: 'video/mp4', data: 'AAAAIGZ0eXBpc29t' } });
  });

  it('strategy anthropic-messages: data image / base64 video → placeholders', () => {
    const body = texts(strategyAnthropicParts([image(IMAGE_PLAIN_DATA), video(VIDEO_B64)]));
    expectNoInlineData(body);
    expect(body).toEqual([TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER, TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER]);
  });

  it('strategy dashscope-native: base64 image and video → placeholders', () => {
    const body = dashscopePartsToString([image(IMAGE_B64), video(VIDEO_B64)]);
    expectNoInlineData([body]);
    expect(body).toContain(TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER);
    expect(body).toContain(TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER);
  });

  it('strategy gemini-generate: non-base64 data image / video → placeholders', () => {
    const body = texts(strategyGeminiParts([image(IMAGE_PLAIN_DATA), video(VIDEO_PLAIN_DATA)]));
    expectNoInlineData(body);
    expect(body).toEqual([TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER, TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER]);
  });

  it('strategy openai-responses: base64 video → video placeholder', () => {
    const out = strategyResponsesContent('user', [video(VIDEO_B64)]);
    expectNoInlineData(texts(out));
    expect(out).toEqual([{ type: 'input_text', text: TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER }]);
  });

  it('runtime buildDashScopeMessages: base64 image and video → placeholders', () => {
    const [message] = buildDashScopeMessages([user([image(IMAGE_B64), video(VIDEO_B64)])]);
    expectNoInlineData([message.content]);
    expect(message.content).toBe(`${TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER}\n${TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER}`);
  });

  it('runtime buildAnthropicRequestPayload: non-base64 data image → image placeholder', () => {
    const { messages } = buildAnthropicRequestPayload([user([image(IMAGE_PLAIN_DATA), video(VIDEO_B64)])]);
    const body = texts(messages);
    expectNoInlineData(body);
    expect(body).toEqual([TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER, TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER]);
  });

  it('runtime buildGeminiContents: non-base64 data image / video → placeholders', () => {
    const body = texts(buildGeminiContents([user([image(IMAGE_PLAIN_DATA), video(VIDEO_PLAIN_DATA)])]));
    expectNoInlineData(body);
    expect(body).toEqual([TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER, TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER]);
  });

  it('gemini interactions: unparsable data image → image placeholder', () => {
    const request = buildGeminiInteractionsRequest(
      { modelID: 'gemini-x', providerKind: 'gemini', apiKey: 'k', messages: [user([{ type: 'text', text: 'hi' }, image(IMAGE_PLAIN_DATA)])] } as never,
      { path: '/v1beta/interactions' } as never,
      { attachmentProfile: 'activated' },
    );
    const body = texts((request.body as { input: unknown }).input);
    expectNoInlineData(body);
    expect(body).toEqual(['hi', TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER]);
  });

  it('https remote URLs keep the [image|video: url] line', () => {
    const remote = [image(IMAGE_HTTPS), video(VIDEO_HTTPS)];
    const expected = [`[image: ${IMAGE_HTTPS}]`, `[video: ${VIDEO_HTTPS}]`];
    expect(texts(strategyAnthropicParts(remote))).toEqual(expected);
    expect(texts(strategyGeminiParts(remote))).toEqual(expected);
    expect(texts(buildGeminiContents([user(remote)]))).toEqual(expected);
    expect(dashscopePartsToString(remote)).toBe(expected.join('\n'));
    expect(buildDashScopeMessages([user(remote)])[0].content).toBe(expected.join('\n'));
    expect(texts(relayAnthropicParts([video(VIDEO_HTTPS)]))).toEqual([expected[1]]);
    expect(relayGeminiParts([video(VIDEO_HTTPS)])).toEqual([{ text: expected[1] }]);
    expect(strategyResponsesContent('user', [video(VIDEO_HTTPS)]))
      .toEqual([{ type: 'input_text', text: expected[1] }]);
    expect(texts(buildAnthropicRequestPayload([user([image(IMAGE_HTTPS)])]).messages)).toEqual([expected[0]]);
  });
});
