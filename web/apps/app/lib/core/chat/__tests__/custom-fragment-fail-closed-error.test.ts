/**
 * Error presentation for fail-closed custom request fields.
 *
 * The problem: the compiler rejects that JSON before the request is sent. Folding that into the
 * generic 502 fallback makes the client show "network error or provider fault, try again later"
 * with an internal enum name such as `unknown_owned_path` as the body, while the only actions
 * that actually resolve it (edit the field, or resend without it) are never mentioned. A hundred
 * retries produce the same result: an error card the user cannot escape.
 *
 * Four things are pinned here: the route returns 400 with a dedicated kind rather than
 * 502/network; the reason comes from a closed vocabulary and never echoes anything the user
 * wrote; the client maps it to localizable errors.* copy; and the three categories match the
 * editor page.
 */
import { describe, expect, it } from 'vitest';
import {
  CUSTOM_FRAGMENT_ERROR_KIND,
  customFragmentRejectionCopyKey,
  customFragmentRejectionMessage,
} from '../custom-fragment-rejection';
import { mapErrorKindKey, resolveErrorCopyKey } from '../../../utils/chat-stream-utils';

describe('fail-closed error classification and localization', () => {
  it('uses the same three categories as the editor page and never leaks the raw reason token', () => {
    expect(customFragmentRejectionCopyKey('invalid_json')).toBe('reasonSyntax');
    expect(customFragmentRejectionCopyKey('duplicate_json_key')).toBe('reasonSyntax');
    expect(customFragmentRejectionCopyKey('too_large')).toBe('reasonLimit');
    expect(customFragmentRejectionCopyKey('depth_exceeded')).toBe('reasonLimit');
    for (const reason of ['unknown_owned_path', 'cross_owner', 'forbidden_root', 'conflict'] as const) {
      expect(customFragmentRejectionCopyKey(reason)).toBe('reasonNotAllowed');
      // An empty allowed set on the editor side gives the same "not allowed" tier.
      expect(customFragmentRejectionMessage(reason, []).key).toBe('customRequestFieldsNotAllowedConflict');
    }
    //   reason  
    expect(customFragmentRejectionCopyKey('some_future_reason')).toBe('reasonNotAllowed');
  });

  /**
   * `invalid_fragment` must mean exactly one thing. Naming both "the root is not an object" and
   * "the compiler rejected it" reports path and quota rejections as syntax errors, and users then
   * keep re-checking JSON that is syntactically fine. These five path reasons and one quota reason
   * are what the compiler really returns (safe-overlay validate), not hypothetical enum values.
   */
  it('path rejections from the compiler are reported as not allowed, not as syntax errors', () => {
    for (const reason of [
      'invalid_pointer', 'blocked_segment', 'builder_owned_root',
      'typed_contribution_required', 'blocked_value_key',
    ] as const) {
      expect(customFragmentRejectionCopyKey(reason), reason).toBe('reasonNotAllowed');
      // When an allowed set exists it must be listed: for a path rejection, "what may I write instead" is the only useful information.
      expect(customFragmentRejectionMessage(reason, ['/enable_search'])).toEqual({
        key: 'customRequestFieldsNotAllowed',
        values: { fields: '/enable_search' },
      });
    }
  });

  it('quota rejections from the compiler are reported as too large or too complex, not as syntax errors', () => {
    for (const reason of ['operation_limit_exceeded', 'size_exceeded', 'node_limit_exceeded'] as const) {
      expect(customFragmentRejectionCopyKey(reason), reason).toBe('reasonLimit');
    }
  });

  it('the syntax category keeps only the cases that editing the JSON really fixes', () => {
    // `invalid_fragment` now means only that the whole fragment is not an object.
    expect(customFragmentRejectionCopyKey('invalid_fragment')).toBe('reasonSyntax');
    // The other direction: none of the compiler reasons may fall back into the syntax tier.
    const syntax = ['invalid_json', 'duplicate_json_key', 'invalid_fragment'];
    for (const reason of [
      'invalid_pointer', 'blocked_segment', 'builder_owned_root', 'typed_contribution_required',
      'blocked_value_key', 'operation_limit_exceeded', 'unknown_owned_path', 'cross_owner', 'compile_rejected',
    ]) {
      expect(syntax, reason).not.toContain(reason);
      expect(customFragmentRejectionCopyKey(reason), reason).not.toBe('reasonSyntax');
    }
  });

  it('the kind has its own copy channel and never falls back to upstream, which reads as a provider fault to retry later', () => {
    expect(mapErrorKindKey(CUSTOM_FRAGMENT_ERROR_KIND)).toBe(CUSTOM_FRAGMENT_ERROR_KIND);
    expect(mapErrorKindKey(CUSTOM_FRAGMENT_ERROR_KIND)).not.toBe('upstream');
    // It has to be localizable again at render time: what is stored is a semantic identifier, not
    // the sentence produced at the moment of failure.
    expect(resolveErrorCopyKey(CUSTOM_FRAGMENT_ERROR_KIND)).toBe(CUSTOM_FRAGMENT_ERROR_KIND);
  });

  it('all 16 locales have a title, body and three reason strings, and the non-English ones are not copies of the English text', async () => {
    const locales = ['ar', 'de', 'en', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const english = (await loadMessages('en')).errors[CUSTOM_FRAGMENT_ERROR_KIND];
    for (const locale of locales) {
      const entry = (await loadMessages(locale)).errors[CUSTOM_FRAGMENT_ERROR_KIND];
      for (const key of ['title', 'message', 'reasonSyntax', 'reasonLimit', 'reasonNotAllowed']) {
        expect(typeof entry?.[key], `${locale}.${key}`).toBe('string');
      }
      if (locale !== 'en') {
        expect(entry!.title, locale).not.toBe(english!.title);
        expect(entry!.message, locale).not.toBe(english!.message);
      }
      // The three reasons must really be three different sentences, otherwise the tiering did nothing.
      expect(new Set([entry!.reasonSyntax, entry!.reasonLimit, entry!.reasonNotAllowed]).size).toBe(3);
    }
  });

  it('the "retry without the custom fields" way out is present in all 16 locales', async () => {
    for (const locale of ['en', 'zh-Hans', 'ja', 'de']) {
      expect(typeof (await loadMessages(locale)).common.retryWithoutCustomRequestFields).toBe('string');
    }
    // The way out has to be translated, not left in English in a non-English locale.
    expect((await loadMessages('zh-Hans')).common.retryWithoutCustomRequestFields)
      .not.toBe((await loadMessages('en')).common.retryWithoutCustomRequestFields);
  });
});

async function loadMessages(locale: string): Promise<{
  errors: Record<string, Record<string, string> | undefined>;
  common: Record<string, string | undefined>;
}> {
  const { readFileSync } = await import('node:fs');
  const path = await import('node:path');
  let current = process.cwd();
  while (true) {
    const file = path.join(current, 'apps/app/messages', `${locale}.json`);
    try { return JSON.parse(readFileSync(file, 'utf8')); } catch { /* keep walking up */ }
    const next = path.dirname(current);
    if (next === current) throw new Error(`messages/${locale}.json`);
    current = next;
  }
}
