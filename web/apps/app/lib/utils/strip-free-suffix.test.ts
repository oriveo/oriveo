import { describe, expect, it } from 'vitest';
import { stripFreeSuffix } from './strip-free-suffix';

describe('stripFreeSuffix', () => {
  it('strips_trailing_free_suffix_case_insensitive', () => {
    expect(stripFreeSuffix('Llama 3.3 70B (free)')).toBe('Llama 3.3 70B');
    expect(stripFreeSuffix('DeepSeek V3 (FREE)  ')).toBe('DeepSeek V3');
    expect(stripFreeSuffix('Qwen3(Free)')).toBe('Qwen3');
  });

  it('keeps_names_without_trailing_suffix', () => {
    expect(stripFreeSuffix('GPT-4o')).toBe('GPT-4o');
    expect(stripFreeSuffix('Free (free) tier model')).toBe('Free (free) tier model');
  });

  it('keeps_original_when_only_suffix', () => {
    expect(stripFreeSuffix('(free)')).toBe('(free)');
  });
});
