import { describe, expect, it } from 'vitest';
import { resolvePromptUseMemory } from '../prompt-injection';

describe('resolvePromptUseMemory', () => {
  it("a conversation-level false overrides the skill's true", () => {
    expect(resolvePromptUseMemory(false, true)).toBe(false);
  });

  it("a conversation-level true overrides the skill's false", () => {
    expect(resolvePromptUseMemory(true, false)).toBe(true);
  });

  it('the skill applies when there is no conversation-level setting', () => {
    expect(resolvePromptUseMemory(undefined, false)).toBe(false);
    expect(resolvePromptUseMemory(undefined, true)).toBe(true);
  });

  it('defaults to true when neither is set', () => {
    expect(resolvePromptUseMemory(undefined, undefined)).toBe(true);
  });
});
