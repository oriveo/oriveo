/**
 * Service reachability monitoring: combines the browser network status with error signals from
 * remote services (metadata catalog, provider APIs) into one state for the top banner.
 *
 * Design notes:
 * - The system network layer is observed passively through `navigator.onLine` and the `window`
 *   `online`/`offline` events.
 * - Remote service reachability is reported passively: when a module catches a network-layer
 *   failure it calls `reportRemoteFailure`. A 60 second sliding window expires without new
 *   failures, so no active polling is needed.
 * - The banner only keeps a global prompt for a lost system connection. Remote service failures
 *   stay in the underlying state and are surfaced in place by the page or action that hit them,
 *   so returning to the foreground does not keep pushing a yellow bar at the user.
 * - Where an ISP blocks a catalog or provider domain the browser is online while that service is
 *   unreachable; `servicesUnreachable` gives the user an accurate message for that case.
 *
 * Exposes a React-friendly subscribe API compatible with `useSyncExternalStore`.
 */

export type ServiceReachabilityState =
  | 'online'
  | 'noNetwork'
  | 'servicesUnreachable';

/** Source of a reported remote failure, kept for telemetry aggregation; the banner does not distinguish sources. */
export type ServiceReachabilityFailureScope =
  | 'metadata'
  | 'backendAPI';

type Listener = () => void;

/** Remote failure window: a failure reported inside the window means unreachable; no new failure outside it counts as recovered. */
const UNREACHABLE_WINDOW_MS = 60_000;
const FAILURE_SCOPES: ServiceReachabilityFailureScope[] = ['metadata', 'backendAPI'];

export class ServiceReachabilityMonitor {
  private currentState: ServiceReachabilityState = 'online';
  private currentBannerState: ServiceReachabilityState = 'online';
  private pathSatisfied = true;
  private readonly lastRemoteFailureAt = new Map<ServiceReachabilityFailureScope, number>();
  private readonly remoteFailureExpiryTimers = new Map<
    ServiceReachabilityFailureScope,
    ReturnType<typeof setTimeout>
  >();
  private hasStarted = false;
  private currentStateInstance = 0;
  private dismissedStateInstance: number | null = null;
  private readonly listeners = new Set<Listener>();

  /** SSR-safe startup: navigator/window listeners are registered only in a browser environment. */
  start(): void {
    if (this.hasStarted) return;
    if (typeof window === 'undefined' || typeof navigator === 'undefined') return;
    this.hasStarted = true;

    this.pathSatisfied = navigator.onLine !== false;

    window.addEventListener('online', this.handleOnline);
    window.addEventListener('offline', this.handleOffline);

    // Run recompute once with the initial values so the real network state shows up right after SSR hydration
    this.recompute();
  }

  /** Test hook: tear down listeners and reset internal state. Not called on production paths. */
  stop(): void {
    if (typeof window !== 'undefined') {
      window.removeEventListener('online', this.handleOnline);
      window.removeEventListener('offline', this.handleOffline);
    }
    this.clearAllRemoteFailures();
    this.hasStarted = false;
    this.pathSatisfied = true;
    this.currentStateInstance = 0;
    this.dismissedStateInstance = null;
    this.setState('online');
  }

  /** subscribe, compatible with useSyncExternalStore. */
  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  /** getSnapshot, compatible with useSyncExternalStore - returns the current state synchronously. */
  getSnapshot = (): ServiceReachabilityState => this.currentState;

  /** Banner snapshot for useSyncExternalStore: exposes only the states worth interrupting globally. */
  getBannerSnapshot = (): ServiceReachabilityState => this.currentBannerState;

  /**
   * SSR snapshot for useSyncExternalStore: there is no navigator/window on the server, so this
   * always reports online.
   */
  getServerSnapshot = (): ServiceReachabilityState => 'online';

  /**
   * Reported when a module catches a network-layer failure from a remote call (host unreachable,
   * timeout, 502/503/504 and so on). Business errors (401 auth, 404 missing, 422 bad parameters)
   * must not be reported, to avoid false positives.
   */
  reportRemoteFailure(_scope: ServiceReachabilityFailureScope): void {
    if (!this.pathSatisfied) {
      this.recompute();
      return;
    }
    const failureAt = Date.now();
    this.lastRemoteFailureAt.set(_scope, failureAt);
    this.scheduleRemoteFailureExpiry(_scope, failureAt);
    this.recompute();
  }

  /** Reported when a remote call succeeds, to speed up the unreachable -> online transition. */
  reportRemoteSuccess(scope: ServiceReachabilityFailureScope): void {
    if (!this.lastRemoteFailureAt.has(scope)) return;
    this.clearRemoteFailure(scope);
    this.recompute();
  }

  /** User dismissed the current banner: only this state instance is silenced, the next state change shows it again. */
  dismissCurrentBanner(): void {
    this.dismissedStateInstance = this.currentStateInstance;
    this.currentBannerState = 'online';
    this.emit();
  }

  /** Test hook: simulate browser online/offline events. */
  applyPathSatisfiedForTesting(satisfied: boolean): void {
    this.applyPathSatisfied(satisfied);
  }

  private handleOnline = (): void => {
    this.applyPathSatisfied(true);
  };

  private handleOffline = (): void => {
    this.applyPathSatisfied(false);
  };

  private applyPathSatisfied(satisfied: boolean): void {
    this.pathSatisfied = satisfied;
    if (!satisfied) {
      this.clearAllRemoteFailures();
    }
    this.recompute();
  }

  private recompute(): void {
    let next: ServiceReachabilityState;

    if (!this.pathSatisfied) {
      next = 'noNetwork';
    } else if (this.hasActiveRemoteFailure()) {
      next = 'servicesUnreachable';
    } else {
      next = 'online';
    }

    if (next === this.currentState) return;
    this.setState(next);
  }

  private scheduleRemoteFailureExpiry(
    scope: ServiceReachabilityFailureScope,
    failureAt: number,
  ): void {
    const existing = this.remoteFailureExpiryTimers.get(scope);
    if (existing != null) {
      clearTimeout(existing);
    }
    const timer = setTimeout(() => {
      this.remoteFailureExpiryTimers.delete(scope);
      if (this.lastRemoteFailureAt.get(scope) === failureAt) {
        this.lastRemoteFailureAt.delete(scope);
        this.recompute();
      }
    }, UNREACHABLE_WINDOW_MS);
    this.remoteFailureExpiryTimers.set(scope, timer);
  }

  private clearRemoteFailure(scope: ServiceReachabilityFailureScope): void {
    this.lastRemoteFailureAt.delete(scope);
    const timer = this.remoteFailureExpiryTimers.get(scope);
    if (timer != null) {
      clearTimeout(timer);
      this.remoteFailureExpiryTimers.delete(scope);
    }
  }

  private clearAllRemoteFailures(): void {
    FAILURE_SCOPES.forEach((scope) => this.clearRemoteFailure(scope));
  }

  private hasActiveRemoteFailure(): boolean {
    const now = Date.now();
    for (const failureAt of this.lastRemoteFailureAt.values()) {
      if (now - failureAt < UNREACHABLE_WINDOW_MS) {
        return true;
      }
    }
    return false;
  }

  private setState(next: ServiceReachabilityState): void {
    this.currentState = next;
    this.currentStateInstance += 1;
    this.currentBannerState = this.nextBannerState(next);
    this.emit();
  }

  private nextBannerState(state: ServiceReachabilityState): ServiceReachabilityState {
    if (state !== 'noNetwork') return 'online';
    return this.dismissedStateInstance === this.currentStateInstance ? 'online' : state;
  }

  private emit(): void {
    this.listeners.forEach((listener) => {
      try {
        listener();
      } catch {
        // One subscriber throwing must not affect the others
      }
    });
  }
}

/** Global singleton. */
export const serviceReachabilityMonitor = new ServiceReachabilityMonitor();
