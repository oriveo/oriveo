import { describe, expect, it } from 'vitest';
import {
  resolveStreamActivityPresentation,
  type StreamActivityPresentationInput,
} from '../stream-activity-presentation';

// The decision table, one row per test.
const base: StreamActivityPresentationInput = {
  isGenerating: true,
  hasBodyText: true,
  typingIndicatorVisible: false,
  activity: null,
  quiet: false,
};

describe('resolveStreamActivityPresentation', () => {
  it('not generating: shows nothing, even with a leftover activity or pause', () => {
    expect(
      resolveStreamActivityPresentation({ ...base, isGenerating: false, activity: 'web_search', quiet: true }),
    ).toEqual({ kind: 'hidden' });
  });

  it('activity observed while the typing indicator is visible: the indicator swaps its label and no line is stacked', () => {
    expect(
      resolveStreamActivityPresentation({
        ...base,
        hasBodyText: false,
        typingIndicatorVisible: true,
        activity: 'web_search',
      }),
    ).toEqual({ kind: 'typingLabel', activity: 'web_search' });
  });

  it('activity observed without the typing indicator: the line shows at once, without waiting for a pause', () => {
    expect(resolveStreamActivityPresentation({ ...base, activity: 'web_search' })).toEqual({
      kind: 'line',
      label: 'web_search',
    });
    // When the reasoning block has replaced the typing indicator the body is empty, and the line still carries the activity.
    expect(
      resolveStreamActivityPresentation({ ...base, hasBodyText: false, activity: 'web_search' }),
    ).toEqual({ kind: 'line', label: 'web_search' });
  });

  it('a pause after body text: the neutral line', () => {
    expect(resolveStreamActivityPresentation({ ...base, quiet: true })).toEqual({
      kind: 'line',
      label: 'neutral',
    });
  });

  it('a pause with no body text, or body text still arriving: shows nothing', () => {
    expect(
      resolveStreamActivityPresentation({ ...base, hasBodyText: false, typingIndicatorVisible: true, quiet: true }),
    ).toEqual({ kind: 'hidden' });
    expect(resolveStreamActivityPresentation({ ...base, hasBodyText: false, quiet: true })).toEqual({
      kind: 'hidden',
    });
    expect(resolveStreamActivityPresentation(base)).toEqual({ kind: 'hidden' });
  });
});
