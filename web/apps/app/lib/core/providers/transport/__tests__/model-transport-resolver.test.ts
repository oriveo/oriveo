/**
 * model-transport-resolver: metadata is authoritative, with a minimal fallback for Relay and manual models.
 */

import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../../metadata/metadata-client', () => ({
  getModelTransport: vi.fn(),
}));

import { getModelTransport } from '../../../metadata/metadata-client';
import { resolveModelTransport } from '../model-transport-resolver';

const getModelTransportMock = vi.mocked(getModelTransport);

describe('resolveModelTransport', () => {
  beforeEach(() => {
    getModelTransportMock.mockReset();
  });

  it('when metadata has a value it is returned directly (including a forward-compat new kind)', () => {
    getModelTransportMock.mockReturnValue('future_kind');
    expect(resolveModelTransport('openAI', 'gpt-9000')).toBe('future_kind');
    expect(getModelTransportMock).toHaveBeenCalledWith('gpt-9000', 'openAI');
  });

  it('when metadata is missing, only the minimal Relay/manual fallback openai_chat is kept', () => {
    getModelTransportMock.mockReturnValue(undefined);

    expect(resolveModelTransport('openAI', 'gpt-5-mini')).toBe('openai_chat');
    expect(resolveModelTransport('gemini', 'imagen-4')).toBe('openai_chat');
    expect(resolveModelTransport('relay', 'custom-model')).toBe('openai_chat');
  });
});
