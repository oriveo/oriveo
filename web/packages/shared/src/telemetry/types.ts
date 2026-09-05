import type {
  TelemetryEventName,
  TelemetryPlatform,
  TelemetryProperties,
} from './events';

/** What a telemetry implementation is handed at construction time. */
export interface TelemetryConfig {
  /** Credential for the sink. Without one there is nothing to send to, so the no-op is used. */
  apiKey: string | null | undefined;
  /** Sink base URL, for a self-hosted or region-specific endpoint. */
  host?: string;
  platform: TelemetryPlatform;
  appVersion: string;
  locale?: string;
  releaseChannel?: 'debug' | 'release';
  debug?: boolean;
}

export interface Telemetry {
  isEnabled(): boolean;
  identify(distinctId: string, props?: TelemetryProperties): void;
  track(event: TelemetryEventName, props?: TelemetryProperties): void;
  page(path: string, props?: TelemetryProperties): void;
  reset(): void;
  setSuperProperties(props: TelemetryProperties): void;
  optIn(): void;
  optOut(): void;
  shutdown(): Promise<void> | void;
}
