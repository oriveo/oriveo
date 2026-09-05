import { describe, expect, it } from 'vitest';
import {
  canonicalProviderKindForId,
  createDeterministicProviderId,
  normalizeNoteIDs,
  normalizePinnedNoteIDs,
  normalizeUUID,
} from './id-utils';

// Golden vectors for deterministic provider ids. Every client must derive these exact
// uppercase values from the same (canonicalKind, regionId).
// Note: these use the web enum strings (togetherAI/fireworksAI) and assert they land on the
// together/fireworks golden values after canonical mapping, which also checks the mapping itself.
const SILICON_FLOW_INTL_ID = '9935660f-5b1a-50ce-b700-42da5090fe1b'.toUpperCase();

const GOLDEN: Array<{ kind: string; region: string; id: string }> = [
  // No region (regionId is the empty string)
  { kind: 'openAI', region: '', id: 'CEE693BC-01B3-5542-A639-D3263AF0D47A' },
  { kind: 'anthropic', region: '', id: 'F4D47A73-2034-5CEB-B2B7-366412C44A5B' },
  { kind: 'gemini', region: '', id: 'EF43015B-FE23-5D59-8D1E-460C5D07D447' },
  { kind: 'openRouter', region: '', id: '644B24B7-E017-5253-BDDA-2E1D24A0608E' },
  { kind: 'deepseek', region: '', id: '72EFDE43-1EBD-5251-8BF8-87596CACCD04' },
  { kind: 'grok', region: '', id: '2238EE91-0BC2-51CC-AA86-595F0B0BF865' },
  { kind: 'groq', region: '', id: '1C71C539-54CF-5613-B913-E994161DF74F' },
  // togetherAI/fireworksAI map canonically to together/fireworks golden values
  { kind: 'togetherAI', region: '', id: '91DD594C-1437-5C33-A923-EA5DEBC43D02' },
  { kind: 'fireworksAI', region: '', id: '3ABBD200-CAF5-5D8B-A473-4FE3E92AE39D' },
  { kind: 'zhipu', region: '', id: '6993D319-CD3A-5D36-8DDC-17C7D32B00EA' },
  { kind: 'siliconFlow', region: '', id: 'DEE48B1E-584B-51F4-8A1F-F921E52796EA' },
  // With a region
  { kind: 'miniMax', region: 'global', id: 'C1F9299A-51D9-51ED-9B4F-853DEC6875A6' },
  { kind: 'miniMax', region: 'cn', id: '53CA3FCB-2E5C-5B51-BDA0-61FC22339096' },
  { kind: 'qwen', region: 'sg', id: 'B5E00F0C-3E68-5E10-B66C-A6DAD2FD7263' },
  { kind: 'qwen', region: 'bj', id: '248F0148-C596-5B0A-A5EE-7D9091F789F0' },
  { kind: 'qwen', region: 'hk', id: 'B64ED15A-F012-574C-808E-1A728151ECF3' },
  { kind: 'qwen', region: 'us', id: '92D43121-6B8A-5E38-A831-6506372A84AB' },
  { kind: 'moonshot', region: 'intl', id: 'E8BDD52A-8670-5FF1-8BC4-6D7653977089' },
  { kind: 'moonshot', region: 'cn', id: '6331C09B-260B-5105-AA15-63380223D72E' },
  { kind: 'siliconFlow', region: 'cn', id: 'DEE48B1E-584B-51F4-8A1F-F921E52796EA' },
  { kind: 'siliconFlow', region: 'intl', id: SILICON_FLOW_INTL_ID },
];

describe('createDeterministicProviderId golden vectors', () => {
  for (const { kind, region, id } of GOLDEN) {
    it(`${kind}|${region} -> ${id}`, async () => {
      const got = await createDeterministicProviderId(kind, region);
      expect(got).toBe(id);
    });
  }

  it('produces a valid uppercase v5 UUID with version=5 and variant in 8/9/A/B that round-trips through normalizeUUID', async () => {
    const got = await createDeterministicProviderId('openAI', '');
    expect(got).toBe(got.toUpperCase());
    expect(got[14]).toBe('5'); // version nibble
    expect('89AB').toContain(got[19]); // variant nibble, uppercase
    expect(normalizeUUID(got)).toBe(got); // already in canonical uppercase form
  });

  it('stays stable across repeated calls for the same (kind, region)', async () => {
    const a = await createDeterministicProviderId('qwen', 'bj');
    const b = await createDeterministicProviderId('qwen', 'bj');
    expect(a).toBe(b);
    expect(a).toBe('248F0148-C596-5B0A-A5EE-7D9091F789F0');
  });

  it('keeps the SiliconFlow China region on the older empty-region identity and gives the international region its own', async () => {
    expect(await createDeterministicProviderId('siliconFlow', 'cn')).toBe(
      await createDeterministicProviderId('siliconFlow', ''),
    );
    expect(await createDeterministicProviderId('siliconFlow', 'intl')).not.toBe(
      await createDeterministicProviderId('siliconFlow', ''),
    );
  });

  it('folds togetherAI/fireworksAI into together/fireworks canonically and leaves the rest as-is', () => {
    expect(canonicalProviderKindForId('togetherAI')).toBe('together');
    expect(canonicalProviderKindForId('fireworksAI')).toBe('fireworks');
    expect(canonicalProviderKindForId('openAI')).toBe('openAI');
    expect(canonicalProviderKindForId('siliconFlow')).toBe('siliconFlow');
  });
});

describe('normalizePinnedNoteIDs', () => {
  it('keeps the last limit entries when there are more, matching slice(-3)', () => {
    expect(normalizePinnedNoteIDs(['a', 'b', 'c', 'd', 'e'], 3)).toEqual(['c', 'd', 'e']);
  });

  it('keeps everything in order when under the limit', () => {
    expect(normalizePinnedNoteIDs(['a', 'b'], 3)).toEqual(['a', 'b']);
  });

  it('deduplicates by first-seen before taking the last limit entries', () => {
    // Dedupe on first-seen -> ['a','b','c','d'], then slice(-3) -> ['b','c','d']
    expect(normalizePinnedNoteIDs(['a', 'b', 'a', 'c', 'd'], 3)).toEqual(['b', 'c', 'd']);
  });

  it('skips blank entries and trims', () => {
    expect(normalizePinnedNoteIDs([' a ', '', '   ', 'b'], 3)).toEqual(['a', 'b']);
  });

  it('returns an empty array for undefined', () => {
    expect(normalizePinnedNoteIDs(undefined)).toEqual([]);
  });
});

describe('normalizeNoteIDs', () => {
  it('canonicalizes source anchors as well as the note id', () => {
    const note = normalizeNoteIDs({
      id: 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa',
      title: 'n',
      titleSource: 'manual',
      body: 'b',
      tags: [],
      captureKind: 'fullAnswer',
      sourceConversationId: 'bbbbbbbb-bbbb-4bbb-abbb-bbbbbbbbbbbb',
      sourceMessageId: 'cccccccc-cccc-4ccc-accc-cccccccccccc',
      createdAt: '2026-06-01T00:00:00.000Z',
      updatedAt: '2026-06-01T00:00:00.000Z',
    });

    expect(note.id).toBe('AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA');
    expect(note.sourceConversationId).toBe('BBBBBBBB-BBBB-4BBB-ABBB-BBBBBBBBBBBB');
    expect(note.sourceMessageId).toBe('CCCCCCCC-CCCC-4CCC-ACCC-CCCCCCCCCCCC');
  });
});
