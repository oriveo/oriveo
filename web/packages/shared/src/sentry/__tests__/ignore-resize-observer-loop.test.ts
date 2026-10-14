import { describe, expect, it } from 'vitest';
import { isResizeObserverLoopNotice } from '../ignore-resize-observer-loop';
import type { SentryEventLike } from '../types';

describe('isResizeObserverLoopNotice', () => {
  it('matches the older Chrome wording reported with no stack frames', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{ type: 'Error', value: 'ResizeObserver loop limit exceeded' }],
      },
    };
    expect(isResizeObserverLoopNotice(event)).toBe(true);
  });

  it('matches the event.message form', () => {
    expect(isResizeObserverLoopNotice({ message: 'Error: ResizeObserver loop limit exceeded' })).toBe(true);
  });

  it('keeps real errors that merely mention ResizeObserver', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{ type: 'TypeError', value: "Failed to execute 'observe' on 'ResizeObserver': parameter 1 is not of type 'Element'." }],
      },
    };
    expect(isResizeObserverLoopNotice(event)).toBe(false);
  });

  it('does not match an empty event', () => {
    expect(isResizeObserverLoopNotice({})).toBe(false);
  });
});
