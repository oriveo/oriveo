'use client';

import { useSyncExternalStore } from 'react';
import {
  serviceReachabilityMonitor,
  type ServiceReachabilityState,
} from '../core/reachability/service-reachability-monitor';

/**
 * Subscribes to the global service reachability state. During SSR it reports 'online', matching
 * the initial value used at startup, and syncs to the real state as soon as the client hydrates.
 */
export function useServiceReachability(): ServiceReachabilityState {
  return useSyncExternalStore(
    serviceReachabilityMonitor.subscribe,
    serviceReachabilityMonitor.getSnapshot,
    serviceReachabilityMonitor.getServerSnapshot,
  );
}

export function useServiceReachabilityBanner(): ServiceReachabilityState {
  return useSyncExternalStore(
    serviceReachabilityMonitor.subscribe,
    serviceReachabilityMonitor.getBannerSnapshot,
    serviceReachabilityMonitor.getServerSnapshot,
  );
}
