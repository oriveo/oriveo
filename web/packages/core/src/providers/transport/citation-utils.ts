/**
 * Citation normalization and deduplication, shared by every strategy.
 *
 * Deduplication rules:
 *   1. Primary key: normalizeUrl(url) (drops the fragment, normalizes the scheme, strips a
 *      trailing `/`)
 *   2. Secondary key: with no url, deduplicate on a hash of title plus snippet
 *   3. Order: first arrival wins
 *   4. Incremental merge: a repeat of the same primary key overwrites with the longer non-empty
 *      snippet or title
 */

import type { Citation } from '@oriveo/shared/pure-types';
import type { StreamShape } from '@oriveo/core/metadata/types';

const URL_TRAILING_SLASH = /\/+$/;

export function normalizeUrl(url: string): string {
  if (!url) return '';
  let trimmed = url.trim();
  // Drop the fragment
  const hashIdx = trimmed.indexOf('#');
  if (hashIdx >= 0) trimmed = trimmed.slice(0, hashIdx);
  // Strip a trailing slash (whether a bare root `/` survives does not matter)
  trimmed = trimmed.replace(URL_TRAILING_SLASH, '');
  // Lowercase http and https schemes, leave others alone
  const schemeMatch = trimmed.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):/);
  if (schemeMatch) {
    const scheme = schemeMatch[1].toLowerCase();
    return `${scheme}:${trimmed.slice(schemeMatch[1].length + 1)}`;
  }
  return trimmed;
}

/** Simple djb2 string hash, used as the secondary key when there is no URL. */
function hashString(input: string): string {
  let hash = 5381;
  for (let i = 0; i < input.length; i += 1) {
    hash = ((hash << 5) + hash + input.charCodeAt(i)) | 0;
  }
  // Convert to unsigned 32-bit
  return (hash >>> 0).toString(36);
}

function citationKey(c: Pick<Citation, 'url' | 'title' | 'snippet'>): string {
  if (c.url && c.url.trim()) return `u:${normalizeUrl(c.url)}`;
  const seed = `${c.title ?? ''}|${c.snippet ?? ''}`.trim();
  return seed ? `t:${hashString(seed)}` : '';
}

/**
 * Merge one new citation into the accumulated list.
 * Returns true when something was added or updated, which an adapter can use to decide whether to
 * emit an event so the UI updates.
 */
export function mergeCitation(
  existing: Citation[],
  next: Citation | null | undefined,
): boolean {
  if (!next || (!next.url && !next.title && !next.snippet)) return false;
  const key = citationKey(next);
  if (!key) return false;

  const idx = existing.findIndex((c) => citationKey(c) === key);
  if (idx < 0) {
    existing.push({
      url: (next.url ?? '').trim(),
      title: trimOrUndefined(next.title),
      snippet: trimOrUndefined(next.snippet),
      faviconUrl: trimOrUndefined(next.faviconUrl),
      index: typeof next.index === 'number' ? next.index : undefined,
      startIndex: typeof next.startIndex === 'number' ? next.startIndex : undefined,
      endIndex: typeof next.endIndex === 'number' ? next.endIndex : undefined,
    });
    return true;
  }
  // Already present: keep the longer non-empty title and snippet, since a repeat of the same primary key may fill in a missing snippet
  const cur = existing[idx];
  const merged: Citation = {
    url: cur.url || (next.url ?? '').trim(),
    title: longerNonEmpty(cur.title, next.title),
    snippet: longerNonEmpty(cur.snippet, next.snippet),
    faviconUrl: cur.faviconUrl ?? trimOrUndefined(next.faviconUrl),
    index: cur.index ?? next.index,
    startIndex: cur.startIndex ?? next.startIndex,
    endIndex: cur.endIndex ?? next.endIndex,
  };
  existing[idx] = merged;
  return (
    merged.title !== cur.title ||
    merged.snippet !== cur.snippet ||
    merged.faviconUrl !== cur.faviconUrl
  );
}

function trimOrUndefined(v: string | undefined | null): string | undefined {
  if (typeof v !== 'string') return undefined;
  const t = v.trim();
  return t ? t : undefined;
}

function longerNonEmpty(a?: string, b?: string | null): string | undefined {
  const va = trimOrUndefined(a);
  const vb = trimOrUndefined(b ?? undefined);
  if (!va) return vb;
  if (!vb) return va;
  return vb.length > va.length ? vb : va;
}

/** Read a value by dot notation, supporting numeric indices such as `.0` and `.1`. */
export function readPath(obj: unknown, path: string | undefined): unknown {
  if (!obj || !path) return undefined;
  let cur: unknown = obj;
  for (const seg of path.split('.')) {
    if (cur == null) return undefined;
    const asIndex = /^\d+$/.test(seg) ? Number(seg) : null;
    if (asIndex !== null && Array.isArray(cur)) {
      cur = cur[asIndex];
    } else if (typeof cur === 'object') {
      cur = (cur as Record<string, unknown>)[seg];
    } else {
      return undefined;
    }
  }
  return cur;
}

function pickString(item: Record<string, unknown>, field: string | undefined): string | undefined {
  if (!field) return undefined;
  const v = readPath(item, field);
  return typeof v === 'string' && v.trim() ? v : undefined;
}

/** Convert an upstream citation entry into a Citation using the streamShape field mapping. */
export function citationFromRaw(
  raw: unknown,
  shape: StreamShape | null,
  defaults: { urlField: string; titleField: string; snippetField: string },
): Citation | null {
  if (!raw || typeof raw !== 'object') return null;
  const item = raw as Record<string, unknown>;
  const urlField = shape?.citationUrlField ?? defaults.urlField;
  const titleField = shape?.citationTitleField ?? defaults.titleField;
  const snippetField = shape?.citationSnippetField ?? defaults.snippetField;

  const url = pickString(item, urlField);
  if (!url) {
    const title = pickString(item, titleField);
    const snippet = pickString(item, snippetField);
    if (!title && !snippet) return null;
    return { url: '', title, snippet };
  }

  return {
    url,
    title: pickString(item, titleField),
    snippet: pickString(item, snippetField),
    faviconUrl: pickString(item, 'icon') ?? pickString(item, 'faviconUrl'),
    index: typeof item.index === 'number' ? item.index : undefined,
    startIndex: typeof item.start_index === 'number' ? item.start_index : undefined,
    endIndex: typeof item.end_index === 'number' ? item.end_index : undefined,
  };
}
