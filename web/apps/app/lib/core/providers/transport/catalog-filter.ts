/**
 * Web adapter over the transport catalog filter in @oriveo/core, which holds the single shared
 * implementation. The core version takes telemetry and the app version through TelemetryPort and
 * EnvPort; this file injects a TelemetryPort backed by trackEvent and an EnvPort that reads
 * process.env on every call, leaving the Web call signature, telemetry and version fallback
 * behaviour unchanged.
 */
import {
  createCatalogFilterContext,
  shouldHideModelForTransport as coreShouldHideModelForTransport,
  __testing,
} from '@oriveo/core/providers/transport/catalog-filter';
import { createNoopTelemetryPort, type EnvPort, type TelemetryPort } from '@oriveo/core';
import { trackEvent } from '../../telemetry';

export { createCatalogFilterContext, __testing };

type FilterContext = ReturnType<typeof createCatalogFilterContext>;

const webTelemetry: TelemetryPort = {
  ...createNoopTelemetryPort(),
  track: (event, props) => trackEvent(event, props),
};

export function shouldHideModelForTransport(
  model: { id: string; transport?: string; minClientVersion?: string },
  ctx: FilterContext,
): boolean {
  const env: EnvPort = { appVersion: process.env.NEXT_PUBLIC_APP_VERSION };
  return coreShouldHideModelForTransport(model, ctx, webTelemetry, env);
}
