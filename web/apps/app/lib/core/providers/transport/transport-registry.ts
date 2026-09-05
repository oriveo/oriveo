/**
 * The transport registry lives in @oriveo/core, so the web and desktop builds share one
 * implementation. Core takes telemetry through an optional TelemetryPort; this module is the web
 * adapter, injecting a TelemetryPort backed by trackEvent.
 */
import {
  getStrategyByKind as coreGetStrategyByKind,
  getStrategyForModel as coreGetStrategyForModel,
  resolveStrategyByKindOrFallback as coreResolveStrategyByKindOrFallback,
  knownTransportKinds,
  UnsupportedTransportError,
} from '@oriveo/core/providers/transport/transport-registry';
import { createNoopTelemetryPort, type TelemetryPort } from '@oriveo/core';
import type { AIModel } from '@oriveo/shared';
import { trackEvent } from '../../telemetry';
import type { TransportStrategy } from './transport-strategy';

export { knownTransportKinds, UnsupportedTransportError };

const webTelemetry: TelemetryPort = {
  ...createNoopTelemetryPort(),
  track: (event, props) => trackEvent(event, props),
};

export function getStrategyByKind(kind: string): TransportStrategy {
  return coreGetStrategyByKind(kind, webTelemetry);
}

export function getStrategyForModel(model: AIModel): TransportStrategy | null {
  return coreGetStrategyForModel(model, webTelemetry);
}

export function resolveStrategyByKindOrFallback(
  kind: string | undefined,
  fallback: TransportStrategy,
  context?: { providerKind?: string; modelID?: string },
): TransportStrategy {
  return coreResolveStrategyByKindOrFallback(kind, fallback, context, webTelemetry);
}
