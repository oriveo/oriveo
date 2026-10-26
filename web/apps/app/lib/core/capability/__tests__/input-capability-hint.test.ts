import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { projectInputCapability } from '@oriveo/core/providers/capability-evidence-facade';
import {
  consumeFirstAttachHint,
  firstAttachHintMessageKey,
  hasSeenInputCapabilityHint,
} from '../input-capability-hint';

const STORAGE_KEY = 'oriveo.input-capability-hint-seen.v1';

// The projection comes from the production facade: only unknown carries first_attach_once, auto / disabled do not.
function projectionFor(state: 'auto_available' | 'unknown' | 'unavailable') {
  return projectInputCapability({
    key: 'vision_input',
    verdict: state === 'unavailable'
      ? { state, reasonCode: 'model_capability_absent' }
      : { state },
    endImplements: true,
    override: null,
    negativeCacheHit: false,
    connection: 'official',
  });
}

describe('first attach hint for unknown input capability', () => {
  beforeEach(() => window.localStorage.clear());
  afterEach(() => window.localStorage.clear());

  it('shows once per provider and model, and records on show', () => {
    const unknown = projectionFor('unknown');
    expect(unknown.hint).toBe('first_attach_once');

    expect(consumeFirstAttachHint('p1', 'm1', unknown)).toBe(true);
    expect(hasSeenInputCapabilityHint('p1', 'm1')).toBe(true);
    expect(JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '[]')).toEqual(['p1|m1']);
    expect(consumeFirstAttachHint('p1', 'm1', unknown)).toBe(false);

    // Switching model or connection each prompts once more.
    expect(consumeFirstAttachHint('p1', 'm2', unknown)).toBe(true);
    expect(consumeFirstAttachHint('p2', 'm1', unknown)).toBe(true);
    expect(JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '[]')).toEqual(['p1|m1', 'p1|m2', 'p2|m1']);
  });

  it('never shows or records without the first_attach_once hint', () => {
    expect(consumeFirstAttachHint('p1', 'm1', projectionFor('auto_available'))).toBe(false);
    expect(consumeFirstAttachHint('p1', 'm1', projectionFor('unavailable'))).toBe(false);
    expect(consumeFirstAttachHint('p1', 'm1', null)).toBe(false);
    expect(consumeFirstAttachHint(undefined, 'm1', projectionFor('unknown'))).toBe(false);
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull();
  });

  it('tolerates corrupt storage and keeps only string entries', () => {
    window.localStorage.setItem(STORAGE_KEY, '{not json');
    expect(hasSeenInputCapabilityHint('p1', 'm1')).toBe(false);
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(['p1|m1', 42]));
    expect(hasSeenInputCapabilityHint('p1', 'm1')).toBe(true);
    expect(consumeFirstAttachHint('p1', 'm1', projectionFor('unknown'))).toBe(false);
  });

  it('maps media to the localized hint key', () => {
    expect(firstAttachHintMessageKey('image')).toBe('hintFirstAttach.image');
    expect(firstAttachHintMessageKey('file')).toBe('hintFirstAttach.file');
    expect(firstAttachHintMessageKey('video')).toBe('hintFirstAttach.video');
  });
});
