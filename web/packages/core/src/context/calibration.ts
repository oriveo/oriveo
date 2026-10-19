/**
 * Per (transport instance, model) text-token ratio calibration (context pipeline §5).
 * Spec: context-contracts/budget.v1.json rules; operand order matters (IEEE double).
 */

import { CONTEXT_BUDGET_CONSTANTS } from './budget';

const { rho0, ewmaAlpha, rhoClamp, safetyFactor, minSamples, overflowMissFactor } = CONTEXT_BUDGET_CONSTANTS;

function clampRho(value: number): number {
  return Math.min(rhoClamp[1], Math.max(rhoClamp[0], value));
}

export interface RhoCalibrationJSON {
  n: number;
  rho: number;
  seeds: number[];
}

export class RhoCalibration {
  private constructor(
    readonly n: number,
    readonly rho: number,
    /** Samples 1..minSamples, kept so the seeding mean survives persistence. */
    readonly seeds: readonly number[],
  ) {}

  static initial(): RhoCalibration {
    return new RhoCalibration(0, rho0, []);
  }

  static fromJSON(json: RhoCalibrationJSON): RhoCalibration {
    return new RhoCalibration(json.n, json.rho, [...json.seeds]);
  }

  get rhoHi(): number {
    return this.n >= minSamples ? this.rho * safetyFactor : this.rho;
  }

  recordingSample(observedInput: number | null | undefined, mediaTokens: number, textBytes: number): RhoCalibration {
    if (observedInput === null || observedInput === undefined || textBytes <= 0) return this;
    const sample = (observedInput - mediaTokens) / textBytes;
    if (!Number.isFinite(sample) || sample <= 0) return this;

    const n = this.n + 1;
    if (n < minSamples) {
      return new RhoCalibration(n, this.rho, [...this.seeds, sample]);
    }
    if (n === minSamples) {
      const seeds = [...this.seeds, sample];
      const sum = seeds.reduce((total, value) => total + value, 0);
      return new RhoCalibration(n, clampRho(sum / seeds.length), seeds);
    }
    return new RhoCalibration(n, clampRho(ewmaAlpha * sample + (1 - ewmaAlpha) * this.rho), this.seeds);
  }

  recordingOverflowMiss(): RhoCalibration {
    return new RhoCalibration(this.n, Math.min(rhoClamp[1], this.rho * overflowMissFactor), this.seeds);
  }

  toJSON(): RhoCalibrationJSON {
    return { n: this.n, rho: this.rho, seeds: [...this.seeds] };
  }
}

export interface RhoCalibrationTableJSON {
  version: 1;
  entries: Array<{ transportInstanceId: string; modelId: string } & RhoCalibrationJSON>;
}

function tableKey(transportInstanceId: string, modelId: string): string {
  return JSON.stringify([transportInstanceId, modelId]);
}

interface TableKey {
  transportInstanceId: string;
  modelId: string;
}

// Compare field by field on UTF-16 code units by (transportInstanceId, modelId), so every platform serializes in the same order.
function compareStrings(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareKeys(a: TableKey, b: TableKey): number {
  return compareStrings(a.transportInstanceId, b.transportInstanceId) || compareStrings(a.modelId, b.modelId);
}

/** In-memory calibration table keyed by (transportInstanceId, modelId); persistence lands separately. */
export class RhoCalibrationTable {
  private readonly entries = new Map<
    string,
    { transportInstanceId: string; modelId: string; calibration: RhoCalibration }
  >();

  get(transportInstanceId: string, modelId: string): RhoCalibration {
    return this.entries.get(tableKey(transportInstanceId, modelId))?.calibration ?? RhoCalibration.initial();
  }

  set(transportInstanceId: string, modelId: string, calibration: RhoCalibration): void {
    this.entries.set(tableKey(transportInstanceId, modelId), { transportInstanceId, modelId, calibration });
  }

  update(
    transportInstanceId: string,
    modelId: string,
    transform: (calibration: RhoCalibration) => RhoCalibration,
  ): RhoCalibration {
    const next = transform(this.get(transportInstanceId, modelId));
    this.set(transportInstanceId, modelId, next);
    return next;
  }

  toJSON(): RhoCalibrationTableJSON {
    return {
      version: 1,
      entries: [...this.entries.values()]
        .sort((a, b) => compareKeys(a, b))
        .map(({ transportInstanceId, modelId, calibration }) => ({
        transportInstanceId,
        modelId,
        ...calibration.toJSON(),
      })),
    };
  }

  static fromJSON(json: RhoCalibrationTableJSON): RhoCalibrationTable {
    if (json.version !== 1) {
      throw new Error(`Unsupported RhoCalibrationTable version: ${String(json.version)}`);
    }
    const table = new RhoCalibrationTable();
    for (const entry of json.entries) {
      table.set(entry.transportInstanceId, entry.modelId, RhoCalibration.fromJSON(entry));
    }
    return table;
  }
}
