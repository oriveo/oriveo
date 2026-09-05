import { describe, expect, it } from 'vitest';
import type { ContentPart, StreamOptions } from '../types';
import { toWireMessages, toWireOptions } from '../desktop-stream';

type Msg = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] };

describe('toWireMessages: ContentPart to wire, keeping every modality', () => {
  it('maps image_url to image, with imageRef holding the data URL plus mimeType', () => {
    const msgs: Msg[] = [
      {
        role: 'user',
        content: [
          { type: 'text', text: 'look' },
          { type: 'image_url', image_url: { url: 'data:image/png;base64,AAA' } },
        ],
      },
    ];
    expect(toWireMessages(msgs)[0].content).toEqual([
      { type: 'text', text: 'look' },
      { type: 'image', imageRef: 'data:image/png;base64,AAA', mimeType: 'image/png' },
    ]);
  });

  it('maps file to file, with dataRef holding file_data and mimeType parsed from the data URL', () => {
    const msgs: Msg[] = [
      { role: 'user', content: [{ type: 'file', file: { filename: 'a.pdf', file_data: 'data:application/pdf;base64,BBB' } }] },
    ];
    expect(toWireMessages(msgs)[0].content).toEqual([
      { type: 'file', fileName: 'a.pdf', mimeType: 'application/pdf', dataRef: 'data:application/pdf;base64,BBB' },
    ]);
  });

  it('passes string content through unchanged and maps video_url to a video wire part', () => {
    const msgs: Msg[] = [
      { role: 'user', content: 'plain' },
      { role: 'user', content: [{ type: 'video_url', video_url: { url: 'data:video/mp4;base64,CCC' } }] },
    ];
    const out = toWireMessages(msgs);
    expect(out[0].content).toBe('plain');
    expect(out[1].content).toEqual([
      { type: 'video', videoRef: 'data:video/mp4;base64,CCC', mimeType: 'video/mp4' },
    ]);
  });
});

describe('toWireOptions: load-bearing options survive (image generation and relay advanced settings)', () => {
  it('maps supportsImageGen, relay advanced options and custom headers, query, codex and UA to the wire', () => {
    const opts: StreamOptions = {
      reasoning: 'medium',
      supportsWebSearch: true,
      supportsImageGen: true,
      generationParameters: { temperature: { state: 'value', value: 0 } },
      relayServiceTier: 'flex',
      relayReasoningEffort: 'xhigh',
      relayStream: false,
      relayHeaders: [{ key: 'X-Custom', value: 'v' }],
      relayQueryParams: [{ key: 'q', value: '1' }],
      relayCodexCompatIdentity: true,
      relayCustomUserAgent: 'my-ua',
      // Connection identity for self-healing after a rejected parameter: the main process cannot rebuild it, and losing it costs one 400 per message.
      capabilityIdentity: {
        partitionId: 'uid-1',
        connectionInstanceId: 'relay-conn-1',
        connectionGeneration: 'gen-1',
        credentialEpoch: 'epoch-1',
        metadataRevision: 'W/"metadata-1"',
        generationRevision: 'W/"generation-1"',
      },
    };
    expect(toWireOptions(opts)).toEqual({
      reasoningMode: 'medium',
      webSearchEnabled: true,
      imageGenEnabled: true,
      generationParameters: { temperature: { state: 'value', value: 0 } },
      relayServiceTier: 'flex',
      relayReasoningEffort: 'xhigh',
      relayStream: false,
      relayHeaders: [{ key: 'X-Custom', value: 'v' }],
      relayQueryParams: [{ key: 'q', value: '1' }],
      relayCodexCompatIdentity: true,
      relayCustomUserAgent: 'my-ua',
      capabilityIdentity: opts.capabilityIdentity,
    });
  });

  it('returns undefined for empty options, adding no stray fields', () => {
    expect(toWireOptions(undefined)).toBeUndefined();
    expect(toWireOptions({})).toBeUndefined();
  });
});
