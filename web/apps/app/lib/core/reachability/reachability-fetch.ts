import {
  serviceReachabilityMonitor,
  type ServiceReachabilityMonitor,
} from './service-reachability-monitor';

type Fetcher = typeof fetch;

interface ReachabilityFetchOptions {
  fetcher?: Fetcher;
  monitor?: ServiceReachabilityMonitor;
}

export async function fetchWithReachability(
  input: RequestInfo | URL,
  init?: RequestInit,
  options: ReachabilityFetchOptions = {},
): Promise<Response> {
  const fetcher = options.fetcher ?? fetch;
  const monitor = options.monitor ?? serviceReachabilityMonitor;

  try {
    const response = await fetcher(input, init);
    if (response.status >= 500) {
      monitor.reportRemoteFailure('backendAPI');
    } else {
      monitor.reportRemoteSuccess('backendAPI');
    }
    return response;
  } catch (error) {
    monitor.reportRemoteFailure('backendAPI');
    throw error;
  }
}
