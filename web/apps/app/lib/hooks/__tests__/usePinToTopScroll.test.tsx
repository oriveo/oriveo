// @vitest-environment jsdom
//
// Pure functions behind usePinToTopScroll, plus locks on the threshold constants.
// computePinReserve is inset = max(minPad, anchorTopY + viewportH - contentH), the geometry that
// decides whether pinning can scroll the question to the top, so the formula boundaries are locked
// by unit tests and the constants act as a tripwire.

import { describe, expect, it } from 'vitest';
import {
  computePinReserve,
  AT_BOTTOM_THRESHOLD_PX,
  PIN_TOP_GAP_PX,
} from '../usePinToTopScroll';

describe('computePinReserve', () => {
  it('short answer: content does not fill the viewport, so the reserve is anchorTop + viewportH - contentH', () => {
    // Question at 600px, viewport 800, content only 650, so 600+800-650 of scroll space is needed
    expect(
      computePinReserve({ anchorTop: 600, viewportHeight: 800, naturalContentHeight: 650 }),
    ).toBe(750);
  });

  it('long answer: content already exceeds anchorTop + viewportH, so the reserve drops to 0', () => {
    // Content 2000 > 600+800, so the question can already be scrolled to the top and no filler is needed
    expect(
      computePinReserve({ anchorTop: 600, viewportHeight: 800, naturalContentHeight: 2000 }),
    ).toBe(0);
  });

  it('exact boundary: contentH == anchorTop + viewportH gives a reserve of 0', () => {
    expect(
      computePinReserve({ anchorTop: 600, viewportHeight: 800, naturalContentHeight: 1400 }),
    ).toBe(0);
  });

  it('never negative, clamped to 0', () => {
    expect(
      computePinReserve({ anchorTop: 0, viewportHeight: 500, naturalContentHeight: 9999 }),
    ).toBe(0);
  });

  it('monotonic: as content grows the reserve shrinks, which is why the streaming spacer only ever shrinks', () => {
    const a = computePinReserve({ anchorTop: 600, viewportHeight: 800, naturalContentHeight: 700 });
    const b = computePinReserve({ anchorTop: 600, viewportHeight: 800, naturalContentHeight: 1100 });
    expect(b).toBeLessThan(a);
  });
});

describe('threshold constant tripwire', () => {
  it('the distance-from-bottom threshold is locked at 80px', () => {
    expect(AT_BOTTOM_THRESHOLD_PX).toBe(80);
  });

  it('the pinned top gap is locked at 12px', () => {
    expect(PIN_TOP_GAP_PX).toBe(12);
  });
});
