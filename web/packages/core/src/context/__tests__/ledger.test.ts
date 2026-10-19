import { describe, expect, it } from 'vitest';

import { RhoCalibration, RhoCalibrationTable } from '../calibration';
import { ContextManifestLog, type ContextManifest } from '../manifest';
import { ContextContractFixture, RHO_TOLERANCE } from './fixture';

const rho0 = ContextContractFixture.load<{ constants: { rho0: number } }>('budget.v1.json').constants.rho0;

function seeded(ratios: number[]): RhoCalibration {
  return ratios.reduce(
    (calibration, ratio) => calibration.recordingSample(ratio * 1000, 0, 1000),
    RhoCalibration.initial(),
  );
}

function manifest(conversationId: string, index: number): ContextManifest {
  return {
    requestId: `${conversationId}-req-${index}`,
    conversationId,
    purpose: 'chat',
    transport: 'transport-a',
    model: 'model-a',
    W: 128000,
    O: 8000,
    B: 115200,
    basis: 'estimated',
    estimatedInput: 1000 + index,
    segments: [{ kind: 'skill', tokens: 100 }],
    unansweredMerged: 0,
    reminder: false,
    createdAt: index,
  };
}

describe('ContextContractLedger', () => {
  it('table defaults to rho0 for unknown keys', () => {
    const table = new RhoCalibrationTable();
    const calibration = table.get('transport-a', 'model-a');
    expect(calibration.n).toBe(0);
    expect(calibration.rho).toBe(rho0);
    expect(calibration.rhoHi).toBe(rho0);
  });

  it('table isolates entries by (transportInstanceId, modelId)', () => {
    const table = new RhoCalibrationTable();
    table.set('transport-a', 'model-a', seeded([0.3, 0.28, 0.32]));
    table.set('transport-a', 'model-b', seeded([0.4]));

    expect(Math.abs(table.get('transport-a', 'model-a').rho - 0.3)).toBeLessThanOrEqual(RHO_TOLERANCE);
    expect(table.get('transport-a', 'model-a').n).toBe(3);
    expect(table.get('transport-a', 'model-b').n).toBe(1);
    expect(table.get('transport-a', 'model-b').rho).toBe(rho0);
    expect(table.get('transport-b', 'model-a').n).toBe(0);
    // Concatenated keys must not collide: ("a:b","c") and ("a","b:c") are two different entries
    table.set('a:b', 'c', seeded([0.2]));
    expect(table.get('a', 'b:c').n).toBe(0);
  });

  it('table round-trips through JSON including seed samples', () => {
    const table = new RhoCalibrationTable();
    table.set('transport-a', 'model-a', seeded([0.3, 0.28]));
    table.set('transport-b', 'model-a', seeded([0.3, 0.28, 0.32, 0.4]));

    const restored = RhoCalibrationTable.fromJSON(JSON.parse(JSON.stringify(table.toJSON())));
    expect(restored.toJSON()).toStrictEqual(table.toJSON());

    // Seed samples are saved with the table: after restoring, the 3rd sample is still reset to the mean of 1..3
    const continued = restored.get('transport-a', 'model-a').recordingSample(320, 0, 1000);
    expect(continued.n).toBe(3);
    expect(Math.abs(continued.rho - 0.3)).toBeLessThanOrEqual(RHO_TOLERANCE);
    expect(Math.abs(restored.get('transport-b', 'model-a').rho - 0.33)).toBeLessThanOrEqual(RHO_TOLERANCE);
  });

  it('manifest log keeps only the newest 50 per conversation', () => {
    const log = new ContextManifestLog();
    for (let i = 1; i <= 51; i += 1) log.append(manifest('conv-a', i));
    const entries = log.list('conv-a');
    expect(entries).toHaveLength(50);
    expect(entries[0].requestId).toBe('conv-a-req-2');
    expect(entries[49].requestId).toBe('conv-a-req-51');
    expect(log.latest('conv-a')?.requestId).toBe('conv-a-req-51');
  });

  it('manifest log isolates conversations', () => {
    const log = new ContextManifestLog();
    for (let i = 1; i <= 51; i += 1) log.append(manifest('conv-a', i));
    log.append(manifest('conv-b', 1));
    expect(log.list('conv-b').map((m) => m.requestId)).toEqual(['conv-b-req-1']);
    expect(log.list('conv-a')).toHaveLength(50);
    expect(log.list('conv-c')).toEqual([]);
    expect(log.latest('conv-c')).toBeUndefined();
  });
});
