import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  openRouterValidateKey: vi.fn(),
  openRouterSyncModels: vi.fn(),
  openRouterSendMessageStream: vi.fn(),
  openAIValidateKey: vi.fn(),
  openAIValidateKeyDirect: vi.fn(),
  openAISyncModels: vi.fn(),
  openAISyncModelsDirect: vi.fn(),
  openAISendMessageStream: vi.fn(),
  deepSeekValidateKey: vi.fn(),
  deepSeekSyncModels: vi.fn(),
  deepSeekSendMessageStream: vi.fn(),
  grokValidateKey: vi.fn(),
  grokSyncModels: vi.fn(),
  grokSendMessageStream: vi.fn(),
  anthropicValidateKey: vi.fn(),
  anthropicSyncModels: vi.fn(),
  anthropicSendMessageStream: vi.fn(),
  geminiValidateKey: vi.fn(),
  geminiSyncModels: vi.fn(),
  geminiSendMessageStream: vi.fn(),
  togetherValidateKey: vi.fn(),
  togetherSyncModels: vi.fn(),
  togetherSendMessageStream: vi.fn(),
  fireworksValidateKey: vi.fn(),
  fireworksSyncModels: vi.fn(),
  fireworksSendMessageStream: vi.fn(),
  groqValidateKey: vi.fn(),
  groqSyncModels: vi.fn(),
  groqSendMessageStream: vi.fn(),
  miniMaxValidateKey: vi.fn(),
  miniMaxSyncModels: vi.fn(),
  miniMaxSendMessageStream: vi.fn(),
  zhipuValidateKey: vi.fn(),
  zhipuSyncModels: vi.fn(),
  qwenValidateKey: vi.fn(),
  qwenSyncModels: vi.fn(),
  moonshotValidateKey: vi.fn(),
  moonshotSyncModels: vi.fn(),
  siliconFlowValidateKey: vi.fn(),
  siliconFlowSyncModels: vi.fn(),
  siliconFlowSendMessageStream: vi.fn(),
}));

vi.mock('../adapters/openrouter', () => ({
  validateKey: (...args: unknown[]) => mocks.openRouterValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.openRouterSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.openRouterSendMessageStream(...args),
}));

vi.mock('../adapters/openai', () => ({
  validateKey: (...args: unknown[]) => mocks.openAIValidateKey(...args),
  validateKeyDirect: (...args: unknown[]) => mocks.openAIValidateKeyDirect(...args),
  syncModels: (...args: unknown[]) => mocks.openAISyncModels(...args),
  syncModelsDirect: (...args: unknown[]) => mocks.openAISyncModelsDirect(...args),
  sendMessageStream: (...args: unknown[]) => mocks.openAISendMessageStream(...args),
}));

vi.mock('../adapters/deepseek', () => ({
  validateKey: (...args: unknown[]) => mocks.deepSeekValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.deepSeekSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.deepSeekSendMessageStream(...args),
}));

vi.mock('../adapters/grok', () => ({
  validateKey: (...args: unknown[]) => mocks.grokValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.grokSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.grokSendMessageStream(...args),
}));

vi.mock('../adapters/anthropic', () => ({
  validateKey: (...args: unknown[]) => mocks.anthropicValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.anthropicSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.anthropicSendMessageStream(...args),
}));

vi.mock('../adapters/gemini', () => ({
  validateKey: (...args: unknown[]) => mocks.geminiValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.geminiSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.geminiSendMessageStream(...args),
}));

vi.mock('../adapters/together', () => ({
  validateKey: (...args: unknown[]) => mocks.togetherValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.togetherSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.togetherSendMessageStream(...args),
}));

vi.mock('../adapters/fireworks', () => ({
  validateKey: (...args: unknown[]) => mocks.fireworksValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.fireworksSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.fireworksSendMessageStream(...args),
}));

vi.mock('../adapters/groq', () => ({
  validateKey: (...args: unknown[]) => mocks.groqValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.groqSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.groqSendMessageStream(...args),
}));

vi.mock('../adapters/minimax', () => ({
  validateKey: (...args: unknown[]) => mocks.miniMaxValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.miniMaxSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.miniMaxSendMessageStream(...args),
}));

vi.mock('../adapters/zhipu', () => ({
  validateKey: (...args: unknown[]) => mocks.zhipuValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.zhipuSyncModels(...args),
}));

vi.mock('../adapters/qwen', () => ({
  validateKey: (...args: unknown[]) => mocks.qwenValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.qwenSyncModels(...args),
}));

vi.mock('../adapters/moonshot', () => ({
  validateKey: (...args: unknown[]) => mocks.moonshotValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.moonshotSyncModels(...args),
}));

vi.mock('../adapters/siliconflow', () => ({
  validateKey: (...args: unknown[]) => mocks.siliconFlowValidateKey(...args),
  syncModels: (...args: unknown[]) => mocks.siliconFlowSyncModels(...args),
  sendMessageStream: (...args: unknown[]) => mocks.siliconFlowSendMessageStream(...args),
}));

import { getAdapter } from '../registry';

describe('provider registry', () => {
  beforeEach(() => {
    Object.values(mocks).forEach((mockFn) => mockFn.mockReset());
  });

  it('forwards the API key to the OpenAI adapter without baseURL (the official endpoint is fixed)', async () => {
    mocks.openAIValidateKey.mockResolvedValue(undefined);

    await getAdapter('openAI').validateKey('sk-test', 'api.openai.com/v1/');

    // The OpenAI direct endpoint is fixed, so the registry does not pass baseURL to the adapter
    expect(mocks.openAIValidateKey).toHaveBeenCalledWith('sk-test');
  });

  it('uses the direct OpenAI-compatible adapter for relay providers', async () => {
    mocks.openAISyncModelsDirect.mockResolvedValue({ models: [] });

    await getAdapter('relay').syncModels('sk-relay', 'relay.example.com/v1/');

    expect(mocks.openAISyncModelsDirect).toHaveBeenCalledWith('sk-relay', 'https://relay.example.com/v1');
  });

  it('routes DeepSeek sync through the dedicated adapter with normalized base URL', async () => {
    mocks.deepSeekSyncModels.mockResolvedValue({ models: [] });

    await getAdapter('deepseek').syncModels('sk-deepseek', 'api.deepseek.com/v1/');

    expect(mocks.deepSeekSyncModels).toHaveBeenCalledWith('sk-deepseek', 'https://api.deepseek.com/v1');
  });

  it('requires a base URL for providers that cannot operate without one', async () => {
    expect(() => {
      getAdapter('togetherAI').validateKey('sk-together');
    }).toThrow('Base URL is required for Together AI');

    expect(mocks.togetherValidateKey).not.toHaveBeenCalled();
  });

  it('uses Z.ai in zhipu configuration errors', () => {
    expect(() => {
      getAdapter('zhipu').validateKey('sk-zhipu');
    }).toThrow('Base URL is required for Z.ai');

    expect(mocks.zhipuValidateKey).not.toHaveBeenCalled();
  });

  it('routes Kimi through the OpenAI-compatible adapter with normalized base URL', async () => {
    mocks.moonshotValidateKey.mockResolvedValue(undefined);

    await getAdapter('moonshot').validateKey('sk-kimi', 'api.moonshot.ai/v1/');

    expect(mocks.moonshotValidateKey).toHaveBeenCalledWith('sk-kimi', 'https://api.moonshot.ai/v1');
  });

  it('passes image generation support through the OpenRouter adapter', () => {
    const messages = [{ role: 'user' as const, content: 'draw' }];

    getAdapter('openRouter').sendStream('sk-openrouter', 'openai/gpt-4.1', messages, undefined, {
      supportsImageGen: true,
    });

    expect(mocks.openRouterSendMessageStream).toHaveBeenCalledWith(
      'sk-openrouter',
      'openai/gpt-4.1',
      messages,
      { supportsImageGen: true },
      true,
      undefined,
    );
  });

  it('routes OpenAI-compatible official providers through their own streaming adapters', () => {
    const messages = [{ role: 'user' as const, content: 'hi' }];
    const options = { reasoning: 'balanced' as const };

    getAdapter('groq').sendStream('sk-groq', 'llama-3', messages, 'api.groq.com/openai/v1/', options);
    getAdapter('togetherAI').sendStream('sk-together', 'meta-llama/Llama-3', messages, 'api.together.xyz/v1/', options);
    getAdapter('fireworksAI').sendStream('sk-fireworks', 'accounts/fireworks/models/llama-v3', messages, 'api.fireworks.ai/inference/v1/', options);
    getAdapter('miniMax').sendStream('sk-minimax', 'MiniMax-M2.5', messages, 'api.minimax.io/v1/', options);
    getAdapter('siliconFlow').sendStream('sk-sf', 'Qwen/Qwen3', messages, 'api.siliconflow.cn/v1/', options);

    expect(mocks.groqSendMessageStream).toHaveBeenCalledWith(
      'sk-groq',
      'llama-3',
      messages,
      'https://api.groq.com/openai/v1',
      options,
    );
    expect(mocks.togetherSendMessageStream).toHaveBeenCalledWith(
      'sk-together',
      'meta-llama/Llama-3',
      messages,
      'https://api.together.xyz/v1',
      options,
    );
    expect(mocks.fireworksSendMessageStream).toHaveBeenCalledWith(
      'sk-fireworks',
      'accounts/fireworks/models/llama-v3',
      messages,
      'https://api.fireworks.ai/inference/v1',
      options,
    );
    expect(mocks.miniMaxSendMessageStream).toHaveBeenCalledWith(
      'sk-minimax',
      'MiniMax-M2.5',
      messages,
      'https://api.minimax.io/v1',
      options,
    );
    expect(mocks.siliconFlowSendMessageStream).toHaveBeenCalledWith(
      'sk-sf',
      'Qwen/Qwen3',
      messages,
      'https://api.siliconflow.cn/v1',
      options,
    );
    expect(mocks.openAISendMessageStream).not.toHaveBeenCalled();
  });

});
