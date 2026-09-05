import { describe, expect, it, vi } from 'vitest';
import { ServiceReachabilityMonitor } from './service-reachability-monitor';

describe('ServiceReachabilityMonitor', () => {
  it('keeps remote failures out of the global banner while preserving state', () => {
    vi.useFakeTimers();
    const monitor = new ServiceReachabilityMonitor();

    monitor.reportRemoteFailure('metadata');
    expect(monitor.getSnapshot()).toBe('servicesUnreachable');
    expect(monitor.getBannerSnapshot()).toBe('online');

    monitor.reportRemoteSuccess('metadata');
    expect(monitor.getSnapshot()).toBe('online');
    expect(monitor.getBannerSnapshot()).toBe('online');

    vi.advanceTimersByTime(2500);
    expect(monitor.getSnapshot()).toBe('online');
    expect(monitor.getBannerSnapshot()).toBe('online');
    vi.useRealTimers();
  });

  it('dismisses only the current banner state instance', () => {
    const monitor = new ServiceReachabilityMonitor();

    monitor.applyPathSatisfiedForTesting(false);
    expect(monitor.getSnapshot()).toBe('noNetwork');
    expect(monitor.getBannerSnapshot()).toBe('noNetwork');

    monitor.dismissCurrentBanner();
    expect(monitor.getSnapshot()).toBe('noNetwork');
    expect(monitor.getBannerSnapshot()).toBe('online');

    monitor.applyPathSatisfiedForTesting(true);
    expect(monitor.getSnapshot()).toBe('online');
    expect(monitor.getBannerSnapshot()).toBe('online');
  });

  it('expires a stale remote failure window without waiting for another event', () => {
    vi.useFakeTimers();
    const monitor = new ServiceReachabilityMonitor();

    monitor.reportRemoteFailure('metadata');
    expect(monitor.getSnapshot()).toBe('servicesUnreachable');

    vi.advanceTimersByTime(60_000);
    expect(monitor.getSnapshot()).toBe('online');
    expect(monitor.getBannerSnapshot()).toBe('online');
    vi.useRealTimers();
  });

  it('does not carry remote failures from an offline period into the online state', () => {
    const monitor = new ServiceReachabilityMonitor();

    monitor.applyPathSatisfiedForTesting(false);
    monitor.reportRemoteFailure('metadata');
    expect(monitor.getSnapshot()).toBe('noNetwork');

    monitor.applyPathSatisfiedForTesting(true);
    expect(monitor.getSnapshot()).toBe('online');
    expect(monitor.getBannerSnapshot()).toBe('online');
  });

  it('does not clear metadata failures with backend API successes', () => {
    const monitor = new ServiceReachabilityMonitor();

    monitor.reportRemoteFailure('metadata');
    monitor.reportRemoteSuccess('backendAPI');

    expect(monitor.getSnapshot()).toBe('servicesUnreachable');

    monitor.reportRemoteSuccess('metadata');
    expect(monitor.getSnapshot()).toBe('online');
  });
});
