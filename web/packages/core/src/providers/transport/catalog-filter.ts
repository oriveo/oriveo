/**
 * Catalog model filtering.
 *
 * Used during catalog-resolver / metadata construction to drop:
 *   1. models whose transport kind is unrecognized (so the client cannot pick one and blow up later)
 *   2. models whose minClientVersion is above the running client (forward-compat hiding)
 *
 * Reporting policy: each (kind|version) emits telemetry only once per metadata cycle, to keep the
 * logs from exploding. Clearing the per-cycle memory when metadata `onVersionChange` fires is enough.
 *
 * telemetry is injected through TelemetryPort and the client version through EnvPort, so core never
 * reads process.env or an SDK directly.
 */

import type { EnvPort, TelemetryPort } from '../../ports';
import { isKnownTransportKind } from './transport-kind';

/** Client runtime version, taken from the injected EnvPort (falls back to '0.0.0' when absent). */
function getClientVersion(env?: EnvPort): string {
  const raw = env?.appVersion;
  return typeof raw === 'string' && raw.trim() ? raw.trim() : '0.0.0';
}

/**
 * SemVer comparison: returns the sign of a-b.
 *   - >0 -> a is newer than b
 *   - <0 -> a is older than b
 *   - =0 -> equal
 *
 * Pre-release suffixes (-alpha.1 and friends) are not supported and fall back to lexicographic order.
 */
function compareSemver(a: string, b: string): number {
  const parse = (v: string): number[] => {
    const trimmed = v.trim().replace(/^v/, '');
    const core = trimmed.split('-')[0]; // drop the pre-release suffix
    return core.split('.').map((p) => {
      const n = Number(p);
      return Number.isFinite(n) ? n : 0;
    });
  };
  const aa = parse(a);
  const bb = parse(b);
  const max = Math.max(aa.length, bb.length, 3);
  for (let i = 0; i < max; i += 1) {
    const x = aa[i] ?? 0;
    const y = bb[i] ?? 0;
    if (x !== y) return x - y;
  }
  return 0;
}

interface FilterContext {
  /** The (kind|version) pairs that have already emitted telemetry, so nothing is reported twice. */
  reportedSignatures: Set<string>;
  modelIdsHidden: string[];
}

/**
 * Create a filter context. Calling `createCatalogFilterContext()` once per catalog build keeps a
 * repeated (kind|version) within that cycle down to a single emit.
 */
export function createCatalogFilterContext(): FilterContext {
  return { reportedSignatures: new Set(), modelIdsHidden: [] };
}

/**
 * Decide whether a model should be hidden.
 *
 * @returns true to hide, false to let it through
 */
export function shouldHideModelForTransport(
  model: { id: string; transport?: string; minClientVersion?: string },
  ctx: FilterContext,
  telemetry?: TelemetryPort,
  env?: EnvPort,
): boolean {
  // 1. Unrecognized transport kind -> hide
  if (model.transport && !isKnownTransportKind(model.transport)) {
    const sig = `kind:${model.transport}`;
    if (!ctx.reportedSignatures.has(sig)) {
      ctx.reportedSignatures.add(sig);
      telemetry?.track('unknown_transport_kind', { kind: model.transport, modelId: model.id });
    }
    ctx.modelIdsHidden.push(model.id);
    return true;
  }

  // 2. minClientVersion above this client -> hide (forward-compat)
  if (model.minClientVersion) {
    const client = getClientVersion(env);
    if (compareSemver(client, model.minClientVersion) < 0) {
      const sig = `ver:${model.minClientVersion}|${client}`;
      if (!ctx.reportedSignatures.has(sig)) {
        ctx.reportedSignatures.add(sig);
        telemetry?.track('unknown_transport_kind', {
          kind: 'min_client_version',
          required: model.minClientVersion,
          current: client,
          modelId: model.id,
        });
      }
      ctx.modelIdsHidden.push(model.id);
      return true;
    }
  }

  return false;
}

// Test only: exposes the SemVer comparison so e2e can cover the boundary cases.
export const __testing = { compareSemver };
