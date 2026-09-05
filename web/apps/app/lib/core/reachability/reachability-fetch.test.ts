import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ServiceReachabilityMonitor } from './service-reachability-monitor';
import { fetchWithReachability } from './reachability-fetch';

describe('fetchWithReachability', () => {
  let monitor: ServiceReachabilityMonitor;

  beforeEach(() => {
    monitor = new ServiceReachabilityMonitor();
  });

  it('reports backendAPI failure on network errors', async () => {
    const fetcher = vi.fn().mockRejectedValue(new TypeError('network down'));

    await expect(fetchWithReachability('/api/test', undefined, { fetcher, monitor })).rejects.toThrow('network down');

    expect(monitor.getSnapshot()).toBe('servicesUnreachable');
  });

  it('reports backendAPI failure on server errors and clears it on client responses', async () => {
    const fetcher = vi.fn()
      .mockResolvedValueOnce(new Response('{}', { status: 503 }))
      .mockResolvedValueOnce(new Response('{}', { status: 401 }));

    await fetchWithReachability('/api/test', undefined, { fetcher, monitor });
    expect(monitor.getSnapshot()).toBe('servicesUnreachable');

    monitor.dismissCurrentBanner();
    await fetchWithReachability('/api/test', undefined, { fetcher, monitor });
    expect(monitor.getSnapshot()).toBe('online');
    expect(monitor.getBannerSnapshot()).toBe('online');
  });

  it('reports success on successful backend responses', async () => {
    const fetcher = vi.fn()
      .mockRejectedValueOnce(new TypeError('network down'))
      .mockResolvedValueOnce(new Response('{}', { status: 200 }));

    await expect(fetchWithReachability('/api/test', undefined, { fetcher, monitor })).rejects.toThrow();
    expect(monitor.getSnapshot()).toBe('servicesUnreachable');

    await fetchWithReachability('/api/test', undefined, { fetcher, monitor });
    expect(monitor.getSnapshot()).toBe('online');
  });
});
