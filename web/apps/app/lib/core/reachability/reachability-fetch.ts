import { isCancellationError } from './cancellation';
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
    // An abort caused by the user stopping generation / closing the page / cancelling the task is not a backend failure: report nothing and leave the reachability state alone.
    if (!isCancellationError(error, init?.signal ?? requestSignal(input))) {
      monitor.reportRemoteFailure('backendAPI');
    }
    throw error;
  }
}

function requestSignal(input: RequestInfo | URL): AbortSignal | undefined {
  return typeof Request !== 'undefined' && input instanceof Request ? input.signal : undefined;
}
