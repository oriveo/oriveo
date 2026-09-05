import type { Telemetry, TelemetryConfig } from './types';

/** Fallback used when there is no API key or when running under SSR: every method is a no-op with the same interface as the real client. */
export function createNoopTelemetry(_config?: TelemetryConfig): Telemetry {
  return {
    isEnabled: () => false,
    identify: () => {},
    track: () => {},
    page: () => {},
    reset: () => {},
    setSuperProperties: () => {},
    optIn: () => {},
    optOut: () => {},
    shutdown: () => {},
  };
}
