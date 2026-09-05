export {
  TELEMETRY_EVENTS,
  TELEMETRY_PII_BLACKLIST,
  type TelemetryEventName,
  type TelemetryPlatform,
  type TelemetryPropertyValue,
  type TelemetryProperties,
} from './events';

export { sanitizeProperties, sanitizeTelemetryPath } from './sanitize';
export { createNoopTelemetry } from './noop-client';

export type { Telemetry, TelemetryConfig } from './types';
