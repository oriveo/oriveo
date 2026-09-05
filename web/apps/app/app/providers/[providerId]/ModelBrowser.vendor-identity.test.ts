import { describe, expect, it } from 'vitest';
import { normalizeVendorKey } from './ModelBrowser';

describe('normalizeVendorKey', () => {
  it('maps backend kwai vendor aliases onto the existing visual asset key', () => {
    expect(normalizeVendorKey('kwai-kolors')).toBe('kwaipilot');
    expect(normalizeVendorKey('kwai')).toBe('kwaipilot');
  });

  it('keeps explicit backend nex vendor keys stable for future visual mapping', () => {
    expect(normalizeVendorKey('nex-agi')).toBe('nex-agi');
  });
});
