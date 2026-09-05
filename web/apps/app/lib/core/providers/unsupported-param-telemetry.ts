import {
  selfHealTelemetryTransport,
  type UnsupportedParamDroppedReporter,
} from '@oriveo/core/providers/unsupported-param';
import {
  initMetadata,
  refreshMetadata,
  resolveCatalogModel,
} from '../metadata/metadata-client';
import { trackEvent } from '../telemetry';

export const reportUnsupportedParamDropped: UnsupportedParamDroppedReporter = ({
  providerKind,
  modelID,
  param,
  transport,
}) => {
  // The reported fields are exactly the allowlist: parameter name, status, transport, error class.
  // `transport` means the model's protocol transport only: the value the caller (the server route)
  // already resolved is preferred, the browser side falls back to the hydrated metadata catalog, and
  // when neither is available `unknown` is reported honestly.
  // providerKind is only a catalog lookup key here and is never reported as a value.
  const wireTransport = selfHealTelemetryTransport(
    transport ?? resolveCatalogModel(modelID, providerKind)?.transport,
  );
  trackEvent('self_heal_param_dropped', {
    parameter: param,
    status: 'recovered',
    transport: wireTransport,
    error_class: 'unsupported_parameter',
  });
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new CustomEvent('oriveo:unsupported-param-self-healed', {
      detail: { param, transport: wireTransport, modelId: modelID },
    }));
  }
  scheduleSelfHealMetadataRefresh();
};

/**
 * A self-healing report triggers one metadata revalidation. Concurrent calls are merged by the
 * refreshPromise in metadata-client, but serial calls are unbounded: dropping several parameters in
 * one request would fire several conditional GETs in a row. A minimal throttle of at most one per
 * 60 seconds is enough, since the refresh only exists to pick up a new snapshot and a minute of
 * delay costs nothing.
 */
const SELF_HEAL_REFRESH_MIN_INTERVAL_MS = 60_000;
let lastSelfHealRefreshAt = 0;

function scheduleSelfHealMetadataRefresh(): void {
  const now = Date.now();
  if (now - lastSelfHealRefreshAt < SELF_HEAL_REFRESH_MIN_INTERVAL_MS) return;
  lastSelfHealRefreshAt = now;
  void refreshMetadata().catch(() => initMetadata().catch(() => {}));
}

/** Test-only: clears the throttle window. */
export function __resetSelfHealMetadataRefreshThrottle(): void {
  lastSelfHealRefreshAt = 0;
}
