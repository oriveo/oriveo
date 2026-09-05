import { describe, expect, it } from 'vitest';

import { isDedicatedImageModel } from './image-models';

describe('isDedicatedImageModel', () => {
  it('matches gpt-image- prefix (lowercase)', () => {
    expect(isDedicatedImageModel('gpt-image-1')).toBe(true);
  });

  it('matches chatgpt-image- prefix', () => {
    expect(isDedicatedImageModel('chatgpt-image-2025-04-15')).toBe(true);
  });

  it('is case-insensitive', () => {
    expect(isDedicatedImageModel('GPT-IMAGE-1')).toBe(true);
    expect(isDedicatedImageModel('ChatGPT-Image-1')).toBe(true);
  });

  it('does not match dall-e or other OpenAI image models', () => {
    expect(isDedicatedImageModel('dall-e-3')).toBe(false);
    expect(isDedicatedImageModel('dall-e-2')).toBe(false);
  });

  it('does not match unrelated chat / multimodal models', () => {
    expect(isDedicatedImageModel('gpt-4o')).toBe(false);
    expect(isDedicatedImageModel('gpt-4-vision')).toBe(false);
    expect(isDedicatedImageModel('claude-3-5-sonnet')).toBe(false);
  });

  it('returns false for null / undefined / empty input', () => {
    expect(isDedicatedImageModel(null)).toBe(false);
    expect(isDedicatedImageModel(undefined)).toBe(false);
    expect(isDedicatedImageModel('')).toBe(false);
  });
});
