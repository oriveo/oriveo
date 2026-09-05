/**
 * Unit tests for citation normalization, deduplication and dot-notation readPath.
 *
 * Covers the three deduplication cases plus numeric indices in readPath.
 */

import { describe, expect, it } from 'vitest';
import type { Citation } from '@oriveo/shared';
import {
  citationFromRaw,
  mergeCitation,
  normalizeUrl,
  readPath,
} from '../citation-utils';

describe('normalizeUrl', () => {
  it('strips the fragment and trailing slash and lowercases the scheme', () => {
    expect(normalizeUrl('HTTPS://Example.com/path/#section')).toBe(
      'https://Example.com/path',
    );
    expect(normalizeUrl('https://example.com/')).toBe('https://example.com');
    expect(normalizeUrl('  https://example.com/path  ')).toBe('https://example.com/path');
  });

  it('leaves an empty string empty', () => {
    expect(normalizeUrl('')).toBe('');
  });

  it('leaves a value without a scheme unchanged', () => {
    expect(normalizeUrl('example.com/path/')).toBe('example.com/path');
  });
});

describe('mergeCitation deduplication rules', () => {
  it('URL as primary key: the same URL is not added twice', () => {
    const list: Citation[] = [];
    expect(mergeCitation(list, { url: 'https://a.com', title: 't1' })).toBe(true);
    // The same key arrives again and adds no entry
    expect(mergeCitation(list, { url: 'https://a.com/', title: 't1' })).toBe(false);
    expect(list).toHaveLength(1);
  });

  it('URL as primary key: merges in a longer snippet', () => {
    const list: Citation[] = [];
    mergeCitation(list, { url: 'https://a.com', title: 'short', snippet: 'A' });
    const changed = mergeCitation(list, {
      url: 'https://a.com',
      title: 'longer title',
      snippet: 'A longer snippet',
    });
    expect(changed).toBe(true);
    expect(list[0].title).toBe('longer title');
    expect(list[0].snippet).toBe('A longer snippet');
  });

  it('without a URL, deduplicates on a title+snippet hash', () => {
    const list: Citation[] = [];
    expect(mergeCitation(list, { url: '', title: 'T', snippet: 'S' })).toBe(true);
    expect(mergeCitation(list, { url: '', title: 'T', snippet: 'S' })).toBe(false);
    expect(list).toHaveLength(1);
  });

  it('a completely empty object returns false', () => {
    const list: Citation[] = [];
    expect(mergeCitation(list, { url: '', title: undefined, snippet: undefined })).toBe(
      false,
    );
    expect(mergeCitation(list, null)).toBe(false);
  });

  it('keeps arrival order stable', () => {
    const list: Citation[] = [];
    mergeCitation(list, { url: 'https://a.com' });
    mergeCitation(list, { url: 'https://b.com' });
    mergeCitation(list, { url: 'https://c.com' });
    expect(list.map((c) => c.url)).toEqual([
      'https://a.com',
      'https://b.com',
      'https://c.com',
    ]);
  });
});

describe('readPath dot notation', () => {
  it('reads a nested object field', () => {
    expect(readPath({ a: { b: { c: 1 } } }, 'a.b.c')).toBe(1);
  });

  it('reads an array element by numeric index', () => {
    expect(readPath({ items: [10, 20, 30] }, 'items.1')).toBe(20);
  });

  it('handles a mixed path', () => {
    expect(readPath({ choices: [{ delta: { content: 'hi' } }] }, 'choices.0.delta.content')).toBe(
      'hi',
    );
  });

  it('returns undefined when the path hits null or undefined', () => {
    expect(readPath({ a: null }, 'a.b')).toBeUndefined();
    expect(readPath(undefined, 'a')).toBeUndefined();
    expect(readPath({}, '')).toBeUndefined();
  });
});

describe('citationFromRaw streamShape field mapping', () => {
  it('uses the default url/title/snippet fields', () => {
    const c = citationFromRaw(
      { url: 'https://a.com', title: 'T', snippet: 'S' },
      null,
      { urlField: 'url', titleField: 'title', snippetField: 'snippet' },
    );
    expect(c).toEqual({
      url: 'https://a.com',
      title: 'T',
      snippet: 'S',
      faviconUrl: undefined,
      index: undefined,
      startIndex: undefined,
      endIndex: undefined,
    });
  });

  it('streamShape overrides the URL field (Zhipu link)', () => {
    const c = citationFromRaw(
      { link: 'https://zhipu.com', media: 'Zhipu' },
      { citationUrlField: 'link', citationTitleField: 'media' },
      { urlField: 'url', titleField: 'title', snippetField: 'snippet' },
    );
    expect(c?.url).toBe('https://zhipu.com');
    expect(c?.title).toBe('Zhipu');
  });

  it('still returns a Citation when the URL is missing but title/snippet are present', () => {
    const c = citationFromRaw(
      { title: 'T', snippet: 'S' },
      null,
      { urlField: 'url', titleField: 'title', snippetField: 'snippet' },
    );
    expect(c?.url).toBe('');
    expect(c?.title).toBe('T');
  });

  it('returns null when every field is missing', () => {
    const c = citationFromRaw({}, null, {
      urlField: 'url',
      titleField: 'title',
      snippetField: 'snippet',
    });
    expect(c).toBeNull();
  });
});
