/**
 * Balance lookup API tests: response format mapping for 4 providers, plus error classification.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BalanceUnauthorizedError,
  BalanceUnsupportedError,
  __resetBalanceCacheForTest,
  fetchDeepSeekBalance,
  fetchMoonshotBalance,
  fetchOpenRouterBalance,
  fetchSiliconFlowBalance,
  getProviderBalanceCached,
  isBalanceCapable,
} from '../balance';

function mockFetchOnce(body: unknown, init: Partial<Response> = {}): void {
  const res = new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: { 'content-type': 'application/json' },
  });
  vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(res));
}

function mockFetchSequence(responses: Array<{ body: unknown; status?: number }>): void {
  const fn = vi.fn();
  for (const r of responses) {
    fn.mockResolvedValueOnce(
      new Response(JSON.stringify(r.body), {
        status: r.status ?? 200,
        headers: { 'content-type': 'application/json' },
      }),
    );
  }
  vi.stubGlobal('fetch', fn);
}

afterEach(() => {
  vi.unstubAllGlobals();
  __resetBalanceCacheForTest();
});

describe('isBalanceCapable', () => {
  it('recognizes which providers expose a balance', () => {
    expect(isBalanceCapable('openRouter')).toBe(true);
    expect(isBalanceCapable('siliconFlow')).toBe(true);
    expect(isBalanceCapable('deepseek')).toBe(true);
    expect(isBalanceCapable('moonshot')).toBe(true);
    expect(isBalanceCapable('openAI')).toBe(false);
    expect(isBalanceCapable('anthropic')).toBe(false);
    expect(isBalanceCapable('relay')).toBe(false);
  });
});

describe('fetchOpenRouterBalance', () => {
  it('total_credits - total_usage = balance', async () => {
    mockFetchOnce({ data: { total_credits: 30, total_usage: 13.74 } });
    const b = await fetchOpenRouterBalance('sk-or-test');
    expect(b.currency).toBe('USD');
    expect(b.total).toBeCloseTo(16.26, 4);
    expect(b.topUp).toBe(30);
    expect(b.totalUsage).toBeCloseTo(13.74, 4);
    expect(b.granted).toBeUndefined();
  });

  it('401 → BalanceUnsupportedError ( )', async () => {
    mockFetchOnce({ error: 'requires management key' }, { status: 401 });
    await expect(fetchOpenRouterBalance('sk-bad')).rejects.toBeInstanceOf(BalanceUnsupportedError);
  });
});

describe('fetchSiliconFlowBalance', () => {
  it('splits totalBalance / balance / chargeBalance from CNY strings', async () => {
    mockFetchOnce({
      data: { balance: '0.88', chargeBalance: '88.00', totalBalance: '88.88' },
    });
    const b = await fetchSiliconFlowBalance('sk-sf');
    expect(b.currency).toBe('CNY');
    expect(b.total).toBe(88.88);
    expect(b.granted).toBe(0.88);
    expect(b.topUp).toBe(88);
  });
});

describe('fetchDeepSeekBalance', () => {
  it('prefers the USD currency entry', async () => {
    mockFetchOnce({
      is_available: true,
      balance_infos: [
        {
          currency: 'CNY',
          total_balance: '12.50',
          granted_balance: '0',
          topped_up_balance: '12.50',
        },
        {
          currency: 'USD',
          total_balance: '1.85',
          granted_balance: '0',
          topped_up_balance: '1.85',
        },
      ],
    });
    const b = await fetchDeepSeekBalance('sk-ds');
    expect(b.currency).toBe('USD');
    expect(b.total).toBe(1.85);
  });

  it('falls back to the first entry when there is no USD', async () => {
    mockFetchOnce({
      balance_infos: [
        {
          currency: 'CNY',
          total_balance: '8.00',
          granted_balance: '0',
          topped_up_balance: '8.00',
        },
      ],
    });
    const b = await fetchDeepSeekBalance('sk-ds');
    expect(b.currency).toBe('CNY');
    expect(b.total).toBe(8);
  });

  it('403 → BalanceUnauthorizedError', async () => {
    mockFetchOnce({ error: 'invalid key' }, { status: 403 });
    await expect(fetchDeepSeekBalance('sk-bad')).rejects.toBeInstanceOf(BalanceUnauthorizedError);
  });
});

describe('fetchMoonshotBalance', () => {
  it('splits available / voucher / cash', async () => {
    mockFetchOnce({
      data: {
        available_balance: 49.58894,
        voucher_balance: 46.58893,
        cash_balance: 3.00001,
      },
    });
    const b = await fetchMoonshotBalance('sk-moon');
    expect(b.currency).toBe('USD');
    expect(b.total).toBeCloseTo(49.58894, 4);
    expect(b.granted).toBeCloseTo(46.58893, 4);
    expect(b.topUp).toBeCloseTo(3.00001, 4);
  });

  it('allows a negative cash_balance for an overdue account', async () => {
    mockFetchOnce({
      data: { available_balance: 10, voucher_balance: 12, cash_balance: -2 },
    });
    const b = await fetchMoonshotBalance('sk-moon');
    expect(b.topUp).toBe(-2);
  });
});

describe('regional endpoints: host derivation and currency selection', () => {
  it('Moonshot .ai host → USD', async () => {
    mockFetchOnce({
      data: { available_balance: 10, voucher_balance: 0, cash_balance: 10 },
    });
    const b = await fetchMoonshotBalance('sk-moon', 'https://api.moonshot.ai/v1');
    expect(b.currency).toBe('USD');
    const fetchCall = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    // The origin is extracted and joined with an absolute path, so no `/v1/v1/...` duplication appears.
    expect(fetchCall[0]).toBe('https://api.moonshot.ai/v1/users/me/balance');
  });

  it('Moonshot .cn host maps to CNY, deriving the currency from the host rather than hardcoding USD', async () => {
    mockFetchOnce({
      data: { available_balance: 50, voucher_balance: 20, cash_balance: 30 },
    });
    const b = await fetchMoonshotBalance('sk-moon-cn', 'https://api.moonshot.cn/v1');
    expect(b.currency).toBe('CNY');
    const fetchCall = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(fetchCall[0]).toBe('https://api.moonshot.cn/v1/users/me/balance');
  });

  it('a custom Moonshot host falls back to USD, so the experience is not broken', async () => {
    mockFetchOnce({
      data: { available_balance: 1, voucher_balance: 0, cash_balance: 1 },
    });
    const b = await fetchMoonshotBalance('sk-moon', 'https://my-proxy.example.com/v1');
    expect(b.currency).toBe('USD');
  });

  it('a DeepSeek baseURL containing /v1 still requests the root path /user/balance without duplicating /v1', async () => {
    mockFetchOnce({
      is_available: true,
      balance_infos: [{ currency: 'USD', total_balance: '1', granted_balance: '0', topped_up_balance: '1' }],
    });
    await fetchDeepSeekBalance('sk-ds', 'https://api.deepseek.com/v1');
    const fetchCall = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    // Chat uses /v1/chat/completions, but the balance lives at the root path /user/balance, not /v1/user/balance.
    expect(fetchCall[0]).toBe('https://api.deepseek.com/user/balance');
  });

  it('an OpenRouter baseURL that already contains /api/v1 is not duplicated', async () => {
    mockFetchOnce({ data: { total_credits: 10, total_usage: 1 } });
    await fetchOpenRouterBalance('sk-or', 'https://openrouter.ai/api/v1');
    const fetchCall = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(fetchCall[0]).toBe('https://openrouter.ai/api/v1/credits');
  });

  it('a SiliconFlow baseURL containing /v1 is not duplicated', async () => {
    mockFetchOnce({
      data: { balance: '0', chargeBalance: '88', totalBalance: '88' },
    });
    await fetchSiliconFlowBalance('sk-sf', 'https://api.siliconflow.cn/v1');
    const fetchCall = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(fetchCall[0]).toBe('https://api.siliconflow.cn/v1/user/info');
  });

  it('the international SiliconFlow endpoint requests .com and shows the balance in USD', async () => {
    mockFetchOnce({
      data: { balance: '0.5', chargeBalance: '8', totalBalance: '8.5' },
    });
    const balance = await fetchSiliconFlowBalance(
      'sk-sf-intl',
      'https://api.siliconflow.com/v1',
    );
    const fetchCall = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(fetchCall[0]).toBe('https://api.siliconflow.com/v1/user/info');
    expect(balance.currency).toBe('USD');
  });
});

describe('getProviderBalanceCached', () => {
  beforeEach(() => {
    __resetBalanceCacheForTest();
  });

  it('hits the cache within 5 minutes', async () => {
    mockFetchSequence([
      { body: { data: { total_credits: 30, total_usage: 0 } } },
    ]);
    const first = await getProviderBalanceCached('p1', 'openRouter', 'k1', undefined, false);
    const second = await getProviderBalanceCached('p1', 'openRouter', 'k1', undefined, false);
    expect(first.total).toBe(second.total);
    // fetch  
    expect((globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls).toHaveLength(1);
  });

  it('bypassCache=true forces a refresh', async () => {
    mockFetchSequence([
      { body: { data: { total_credits: 30, total_usage: 0 } } },
      { body: { data: { total_credits: 30, total_usage: 5 } } },
    ]);
    const first = await getProviderBalanceCached('p2', 'openRouter', 'k1', undefined, false);
    const second = await getProviderBalanceCached('p2', 'openRouter', 'k1', undefined, true);
    expect(first.total).toBe(30);
    expect(second.total).toBe(25);
  });

  it('a changed API key or baseURL replaces the old cache entry', async () => {
    mockFetchSequence([
      { body: { data: { available_balance: 10, voucher_balance: 0, cash_balance: 10 } } },
      { body: { data: { available_balance: 20, voucher_balance: 0, cash_balance: 20 } } },
      { body: { data: { available_balance: 50, voucher_balance: 0, cash_balance: 50 } } },
      { body: { data: { available_balance: 20, voucher_balance: 0, cash_balance: 20 } } },
    ]);
    const globalBalance = await getProviderBalanceCached(
      'moonshot-1',
      'moonshot',
      'k1',
      'https://api.moonshot.ai/v1',
      false,
    );
    const replacedKeyBalance = await getProviderBalanceCached(
      'moonshot-1',
      'moonshot',
      'k2',
      'https://api.moonshot.ai/v1',
      false,
    );
    const chinaBalance = await getProviderBalanceCached(
      'moonshot-1',
      'moonshot',
      'k2',
      'https://api.moonshot.cn/v1',
      false,
    );
    const switchedBackBalance = await getProviderBalanceCached(
      'moonshot-1',
      'moonshot',
      'k2',
      'https://api.moonshot.ai/v1',
      false,
    );

    expect(globalBalance.currency).toBe('USD');
    expect(replacedKeyBalance.total).toBe(20);
    expect(chinaBalance.currency).toBe('CNY');
    expect(switchedBackBalance.total).toBe(20);
    expect((globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls).toHaveLength(4);
  });
});
