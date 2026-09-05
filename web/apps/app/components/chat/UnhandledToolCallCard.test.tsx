import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { UnhandledToolCallCard, formatToolCallArguments } from './UnhandledToolCallCard';

describe('UnhandledToolCallCard', () => {
  it('keeps multiple tool requests in one collapsed card and expands diagnostics', () => {
    render(<UnhandledToolCallCard calls={[
      { id: 'one', name: 'weather', arguments: '{"city":"Melbourne"}' },
      { id: 'two', name: 'clock', arguments: '{"tz":"Australia/Melbourne"}' },
    ]} />);

    const card = screen.getByTestId('unhandled-tool-call-card');
    expect(card.textContent).toContain('toolCallUnhandledMultiple');
    expect(screen.queryByText('toolCallRequestTitle')).toBeNull();
    const toggle = screen.getByRole('button');
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    fireEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(toggle.getAttribute('aria-controls')).toBeTruthy();
    expect(screen.getByText('toolCallRequestTitle')).not.toBeNull();
    expect(screen.getByText('weather')).not.toBeNull();
    expect(screen.getByText('clock')).not.toBeNull();
    expect(card.querySelectorAll('pre')).toHaveLength(2);
  });

  it('uses the iOS placeholder for an empty provider tool name', () => {
    render(<UnhandledToolCallCard calls={[
      { id: 'empty', name: '', arguments: '{}' },
    ]} />);

    fireEvent.click(screen.getByRole('button'));
    expect(screen.getByText('?')).not.toBeNull();
  });

  it('truncates arguments larger than 2KB', () => {
    render(<UnhandledToolCallCard calls={[
      { id: 'one', name: 'huge', arguments: JSON.stringify({ value: 'x'.repeat(3_000) }) },
    ]} />);
    fireEvent.click(screen.getByRole('button'));
    expect(screen.getByText('toolCallArgumentsTruncated')).not.toBeNull();
  });

  it('pretty-prints valid JSON and preserves invalid provider output verbatim', () => {
    expect(formatToolCallArguments('{"city":"Melbourne","days":2}')).toEqual({
      text: '{\n  "city": "Melbourne",\n  "days": 2\n}',
      truncated: false,
    });
    expect(formatToolCallArguments('{"city":')).toEqual({
      text: '{"city":',
      truncated: false,
    });
  });

  it('truncates pretty JSON to at most 2KB without splitting CJK or emoji scalars', () => {
    const formatted = formatToolCallArguments(JSON.stringify({
      value: ' 🙂'.repeat(500),
    }));

    expect(formatted.truncated).toBe(true);
    expect(new TextEncoder().encode(formatted.text).byteLength).toBeLessThanOrEqual(2_048);
    expect(formatted.text.endsWith('\uFFFD')).toBe(false);
    expect(formatted.text).not.toContain('\uFFFD');
    // The prefix itself remains valid UTF-8 and round-trips byte-for-byte.
    const bytes = new TextEncoder().encode(formatted.text);
    expect(new TextEncoder().encode(new TextDecoder('utf-8', { fatal: true }).decode(bytes))).toEqual(bytes);
  });
});
