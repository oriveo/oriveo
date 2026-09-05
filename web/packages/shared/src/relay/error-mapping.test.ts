import { describe, expect, it } from 'vitest';

import { mapRelayStreamError } from './error-mapping';

describe('mapRelayStreamError', () => {
  it('keeps the provider message while mapping moderation recovery semantics', () => {
    const result = mapRelayStreamError('moderation_blocked', 'blocked content');
    expect(result.errorKind).toBe('moderation');
    expect(result.i18nKey).toBe('moderation');
    expect(result.message).toBe('blocked content');
  });

  it('maps moderation by message heuristic when code is missing', () => {
    const result = mapRelayStreamError(null, 'Triggered the safety system due to copyrighted content.');
    expect(result.errorKind).toBe('moderation');
    expect(result.i18nKey).toBe('moderation');
  });

  it('is case-insensitive on code matching', () => {
    expect(mapRelayStreamError('MODERATION_BLOCKED', 'x').errorKind).toBe('moderation');
  });

  it('maps any image_generation related code to imageGenUser', () => {
    expect(mapRelayStreamError('image_generation_user_error', 'tool failed')).toEqual({
      errorKind: 'imageGenUser',
      i18nKey: 'imageGenUser',
      message: 'tool failed',
    });
    expect(mapRelayStreamError('IMAGE_GENERATION_FAILED', 'tool failed').errorKind).toBe('imageGenUser');
    expect(mapRelayStreamError('image_generation', 'tool failed').i18nKey).toBe('imageGenUser');
  });

  it('passes through upstream message for unrecognized codes', () => {
    const upstream = 'Custom upstream description';
    const result = mapRelayStreamError('some_other_code', upstream);
    expect(result.errorKind).toBe('upstream');
    expect(result.i18nKey).toBeUndefined();
    expect(result.message).toBe(upstream);
  });

  it('falls back to a generic message when both code and message are empty', () => {
    const result = mapRelayStreamError(undefined, undefined);
    expect(result.errorKind).toBe('upstream');
    expect(result.i18nKey).toBeUndefined();
    expect(result.message).toBeTruthy();
  });
});
