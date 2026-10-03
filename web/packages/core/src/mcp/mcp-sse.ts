/**
 * Incremental SSE (text/event-stream) parsing. Mirrors the iOS `McpSSE.swift`.
 *
 * A Streamable HTTP response may be a single JSON document or an SSE stream; both must be supported. The
 * stream may carry JSON-RPC notifications related to the request (without an id), and the final response
 * ends the stream. Resuming with `Last-Event-ID` is not supported, so event ids are not kept.
 *
 * Parsing must be incremental: after the final response a server SHOULD close the stream but may not. If
 * parsing waited for the stream to close, a writing tool that has already run would make the client wait
 * out the whole timeout and then report a failure.
 *
 * Line endings are LF / CRLF / a lone CR; a BOM at the start of the stream is dropped; multiple `data:`
 * lines of one event are joined with `\n`; `event:` / `id:` / `retry:` and comment lines are ignored; a
 * payload that is not valid JSON is skipped (one bad frame must not kill the whole stream).
 */

import { parseJsonLimited } from './mcp-json';
import type { JsonValue } from './mcp-types';

export class McpSseParser {
  private line = '';
  private dataLines: string[] = [];
  private previousWasCR = false;
  private atStreamStart = true;
  /** This event's payload was already emitted early when its `data:` line ended; the blank line must not emit it again. */
  private emittedEarly = false;

  /** Feeds a chunk of decoded text and returns the completed event payloads (in order of appearance). */
  push(chunk: string): JsonValue[] {
    const out: JsonValue[] = [];
    for (let i = 0; i < chunk.length; i++) {
      const char = chunk[i]!;
      if (char === '\n') {
        if (this.previousWasCR) {
          this.previousWasCR = false;
          continue;
        }
        this.collect(this.endLine(), out);
      } else if (char === '\r') {
        this.previousWasCR = true;
        this.collect(this.endLine(), out);
      } else {
        this.previousWasCR = false;
        this.line += char;
      }
    }
    return out;
  }

  /**
   * End of stream: also emits a last event that was not terminated by a blank line. The specification says
   * an unterminated event should be discarded, but when the response arrived in full and only the blank line
   * is missing, dropping it would report an executed call as a failure, so it is accepted.
   */
  finish(): JsonValue[] {
    const out: JsonValue[] = [];
    if (this.line.length > 0) this.collect(this.endLine(), out);
    this.collect(this.dispatch(), out);
    return out;
  }

  private collect(value: JsonValue | undefined, out: JsonValue[]): void {
    if (value !== undefined) out.push(value);
  }

  private endLine(): JsonValue | undefined {
    let text = this.line;
    this.line = '';
    if (this.atStreamStart) {
      this.atStreamStart = false;
      if (text.startsWith('﻿')) text = text.slice(1);
    }
    if (text.length === 0) return this.dispatch();
    if (text.startsWith(':')) return undefined;

    const colon = text.indexOf(':');
    const field = colon >= 0 ? text.slice(0, colon) : text;
    let value = colon >= 0 ? text.slice(colon + 1) : '';
    if (value.startsWith(' ')) value = value.slice(1);
    if (field !== 'data') return undefined;

    this.dataLines.push(value);
    // Nearly every server sends one data line per event; when that line is complete JSON, emit it right away
    // instead of waiting for the blank line.
    // Only for the first line: reparsing on every line of a multi-line data block is quadratic, and a peer
    // could use that to stall us.
    if (this.dataLines.length === 1) {
      const parsed = parseJsonLimited(value);
      if (parsed !== undefined) {
        this.emittedEarly = true;
        return parsed;
      }
    }
    return undefined;
  }

  private dispatch(): JsonValue | undefined {
    const lines = this.dataLines;
    const early = this.emittedEarly;
    this.dataLines = [];
    this.emittedEarly = false;
    if (lines.length === 0) return undefined;
    if (early && lines.length === 1) return undefined;
    return parseJsonLimited(lines.join('\n'));
  }
}

/** Parses a whole SSE text into an array of messages (fallback for an untruthful `Content-Type`, and for tests). */
export function parseSseMessages(text: string): JsonValue[] {
  const parser = new McpSseParser();
  return [...parser.push(text), ...parser.finish()];
}
