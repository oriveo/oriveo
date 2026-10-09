'use client';

import { useCallback } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import type { CopyArg, CopyRef } from '../../lib/core/chat/model-options-copy';

/**
 * Turns the `CopyRef` produced by the data layer into text. `common.*` goes through the common namespace translator and the rest is looked up by root path;
 * copy nested in arguments is resolved first, and lists are joined according to the current language.
 */
export function useCopy(): (ref: CopyRef | CopyRef[]) => string {
  const tc = useTranslations('common');
  const root = useTranslations();
  const locale = useLocale();
  const resolve = useCallback((ref: CopyRef | CopyRef[]): string => {
    if (Array.isArray(ref)) return joinList(ref.map(resolve), locale);
    if ('literal' in ref) return ref.literal;
    const args = ref.args
      ? Object.fromEntries(Object.entries(ref.args).map(([name, value]) => [name, resolveArg(value, resolve)]))
      : undefined;
    return ref.key.startsWith('common.') ? tc(ref.key.slice('common.'.length), args) : root(ref.key, args);
  }, [locale, root, tc]);
  return resolve;
}

function resolveArg(value: CopyArg, resolve: (ref: CopyRef | CopyRef[]) => string): string | number {
  if (typeof value === 'string' || typeof value === 'number') return value;
  return resolve(value);
}

function joinList(items: string[], locale: string): string {
  try {
    return new Intl.ListFormat(locale, { style: 'short', type: 'conjunction' }).format(items);
  } catch {
    return items.join(', ');
  }
}
