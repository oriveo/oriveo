import { describe, expect, it } from 'vitest';

import { StreamFinishTracker } from '../stream-finish';

describe('StreamFinishTracker', () => {
  it('responses_completed_event_without_status_is_clean', () => {
    const tracker = new StreamFinishTracker();
    expect(tracker.observe('response.output_text.delta', { type: 'response.output_text.delta', delta: 'hi' })).toBeNull();
    const finish = tracker.observe('response.completed', {
      type: 'response.completed',
      response: { usage: { input_tokens: 3, output_tokens: 4 } },
    });
    expect(finish).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'completed' });
    expect(tracker.atEnd(true)).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'completed' });
  });

  it('responses_completed_type_without_event_line_or_status_is_clean', () => {
    const tracker = new StreamFinishTracker();
    tracker.observe(null, { type: 'response.created', response: {} });
    tracker.observe(null, { type: 'response.completed', response: {} });
    expect(tracker.atEnd(false)).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'completed' });
  });

  it('responses_stream_without_terminal_event_is_eof_without_marker', () => {
    const tracker = new StreamFinishTracker();
    tracker.observe('response.output_item.done', { type: 'response.output_item.done', item: {} });
    expect(tracker.atEnd(true)).toEqual({ family: 'openai_responses', ended: 'eof_without_marker' });
  });
});
