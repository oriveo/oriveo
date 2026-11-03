// Memory draft / organize requests must carry relay runtime options so a LocalHttp relay is not rejected as cleartext.
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({ sendStream: vi.fn() }));

vi.mock('../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../utils/chat-stream-utils', () => ({ readStream: async () => ({ fullText: '- likes tea' }) }));

import { requestMemoryDraft } from '../memory-draft';
import { requestMemoryOrganize } from '../memory/memory-organize';

const localRelay = {
  id: 'relay-local',
  kind: 'relay',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: 'sk-local',
  apiKeyPreview: '••local',
  baseURLText: 'http://127.0.0.1:1234/v1',
  relayResolvedBaseURLText: 'http://127.0.0.1:1234/v1',
  relayResolvedTransport: 'openai_chat_completions',
  relayResolvedAuthMode: 'bearer',
  relayResolvedHeaderProfile: 'none',
  relayResolvedFamilyHint: 'openai',
  relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', securityMode: 'local_http' },
} as unknown as Provider;
const model = { id: 'qwen-local', name: 'qwen-local', isAvailable: true } as unknown as AIModel;

const relayOptions = expect.objectContaining({
  relaySecurityMode: 'local_http',
  relayTransport: 'openai_chat_completions',
});

afterEach(() => {
  mocks.sendStream.mockReset();
});

describe('memory requests on a LocalHttp relay', () => {
  it('memory_draft_forwards_relay_options', async () => {
    mocks.sendStream.mockReturnValue({ stream: new ReadableStream() });
    await requestMemoryDraft({ provider: localRelay, model, excerpts: 'I like tea' });
    expect(mocks.sendStream).toHaveBeenCalledWith(
      'relay', 'sk-local', 'qwen-local', expect.any(Array), 'http://127.0.0.1:1234/v1', relayOptions,
    );
  });

  it('memory_organize_forwards_relay_options', async () => {
    mocks.sendStream.mockReturnValue({ stream: new ReadableStream() });
    await requestMemoryOrganize({ provider: localRelay, model, content: 'I like tea and coffee' });
    expect(mocks.sendStream).toHaveBeenCalledWith(
      'relay', 'sk-local', 'qwen-local', expect.any(Array), 'http://127.0.0.1:1234/v1', relayOptions,
    );
  });
});
