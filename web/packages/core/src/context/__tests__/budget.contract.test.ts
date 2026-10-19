import { describe, expect, it } from 'vitest';

import {
  ContextBudget,
  budgetCapWire,
  parseBudgetCap,
  type BudgetCapOption,
  type ContextWindowBudget,
  type DisplayInput,
  type PHatInput,
  type WindowBudgetInput,
} from '../budget';
import { RhoCalibration } from '../calibration';
import { ContextContractFixture, RHO_TOLERANCE } from './fixture';

interface BudgetContract {
  constants: {
    rho0: number;
    messageOverheadTokens: number;
    minKnownWindow: number;
    defaultMaxOutput: number;
    budgetCapOptions: string[];
    budgetCapDefault: string;
    customCapMin: number;
    customCapMax: number;
    autoCapDefault: number;
    priceLineCapMin: number;
    capTickLadder: number[];
  };
  windowCases: Array<{
    id: string;
    input: Omit<WindowBudgetInput, 'budgetCap'> & { budgetCap: unknown };
    expected: ContextWindowBudget;
  }>;
  capCases: Array<{ id: string; input: unknown; expected: { cap: BudgetCapOption } | { rejected: true } }>;
  capTickCases: Array<{
    id: string;
    input: { U: number | null; priceLineTokens: number | null };
    expected: { ticks: number[] };
  }>;
  rhoCases: Array<{
    id: string;
    events: Array<
      | { type: 'sample'; observedInput: number | null; mediaTokens: number; textBytes: number }
      | { type: 'overflowMiss' }
    >;
    expected: Array<{ n: number; rho: number; rhoHi: number }>;
  }>;
  estimateCases: Array<{
    id: string;
    input: { text: string; rhoHi: number };
    expected: { utf8Bytes: number; textTokens: number; messageTokens: number };
  }>;
  observedCases: Array<{ id: string; input: PHatInput; expected: { pHat: number; basis: string } }>;
  displayCases: Array<{ id: string; input: DisplayInput; expected: Record<string, unknown> }>;
}

const contract = ContextContractFixture.load<BudgetContract>('budget.v1.json');

describe('ContextContractBudget', () => {
  it('case counts match the fixture', () => {
    expect(contract.windowCases).toHaveLength(34);
    expect(contract.capCases).toHaveLength(19);
    expect(contract.capTickCases).toHaveLength(13);
  });

  it('constants_match_fixture', () => {
    expect(ContextBudget.constants.rho0).toBe(contract.constants.rho0);
    expect(ContextBudget.constants.messageOverheadTokens).toBe(contract.constants.messageOverheadTokens);
    expect(ContextBudget.constants.minKnownWindow).toBe(contract.constants.minKnownWindow);
    expect(ContextBudget.constants.defaultMaxOutput).toBe(contract.constants.defaultMaxOutput);
    expect(ContextBudget.constants.budgetCapOptions).toEqual(contract.constants.budgetCapOptions);
    expect(ContextBudget.constants.budgetCapDefault).toBe(contract.constants.budgetCapDefault as BudgetCapOption);
    expect(ContextBudget.constants.customCapMin).toBe(contract.constants.customCapMin);
    expect(ContextBudget.constants.customCapMax).toBe(contract.constants.customCapMax);
    expect(ContextBudget.constants.autoCapDefault).toBe(contract.constants.autoCapDefault);
    expect(ContextBudget.constants.priceLineCapMin).toBe(contract.constants.priceLineCapMin);
    expect(ContextBudget.constants.capTickLadder).toEqual(contract.constants.capTickLadder);
  });

  describe('windowCases', () => {
    it.each(contract.windowCases.map((c) => [c.id, c] as const))('%s', (id, c) => {
      const budgetCap = parseBudgetCap(c.input.budgetCap);
      expect(budgetCap, `${id} budgetCap`).not.toBeNull();
      const input: WindowBudgetInput = { ...c.input, budgetCap: budgetCap as BudgetCapOption };
      expect(ContextBudget.window(input), id).toStrictEqual(c.expected);
    });
  });

  it('non-integer custom cap and price line fall back to auto without a price line', () => {
    const base: WindowBudgetInput = {
      W: 2000000,
      windowKind: 'total',
      maxOutput: { model: 32000 },
      budgetCap: 'auto',
    };
    const expected = ContextBudget.window(base);
    const actual = ContextBudget.window({ ...base, budgetCap: Number.NaN, priceLineTokens: 200000.5 });
    expect(actual.B).toBe(expected.B);
    expect(actual.B).toBe(ContextBudget.constants.autoCapDefault);
    expect(actual).toStrictEqual(expected);
  });

  describe('capCases', () => {
    it.each(contract.capCases.map((c) => [c.id, c] as const))('%s', (id, c) => {
      const parsed = parseBudgetCap(c.input);
      if ('rejected' in c.expected) {
        expect(parsed, id).toBeNull();
        return;
      }
      expect(parsed, id).toBe(c.expected.cap);
      expect(parseBudgetCap(budgetCapWire(c.expected.cap)), `${id} wire round trip`).toBe(c.expected.cap);
    });
  });

  describe('capTickCases', () => {
    it.each(contract.capTickCases.map((c) => [c.id, c] as const))('%s', (id, c) => {
      expect(ContextBudget.capTicks(c.input.U, c.input.priceLineTokens), id).toStrictEqual(c.expected.ticks);
    });
  });

  describe('rhoCases', () => {
    it.each(contract.rhoCases.map((c) => [c.id, c] as const))('%s', (id, c) => {
      let calibration = RhoCalibration.initial();
      c.events.forEach((event, index) => {
        calibration =
          event.type === 'sample'
            ? calibration.recordingSample(event.observedInput, event.mediaTokens, event.textBytes)
            : calibration.recordingOverflowMiss();
        const expected = c.expected[index];
        const label = `${id}[${index}]`;
        expect(calibration.n, label).toBe(expected.n);
        expect(Math.abs(calibration.rho - expected.rho), `${label} rho ${calibration.rho}`).toBeLessThanOrEqual(
          RHO_TOLERANCE,
        );
        expect(
          Math.abs(calibration.rhoHi - expected.rhoHi),
          `${label} rhoHi ${calibration.rhoHi}`,
        ).toBeLessThanOrEqual(RHO_TOLERANCE);
      });
    });
  });

  describe('estimateCases', () => {
    it.each(contract.estimateCases.map((c) => [c.id, c] as const))('%s', (id, c) => {
      expect(ContextBudget.utf8Bytes(c.input.text), id).toBe(c.expected.utf8Bytes);
      expect(ContextBudget.estimateText(c.input.text, c.input.rhoHi), id).toBe(c.expected.textTokens);
      expect(ContextBudget.estimateMessage(c.input.text, c.input.rhoHi), id).toBe(c.expected.messageTokens);
    });
  });

  describe('observedCases', () => {
    it.each(contract.observedCases.map((c) => [c.id, c] as const))('%s', (id, c) => {
      expect(ContextBudget.pHat(c.input), id).toStrictEqual(c.expected);
    });
  });

  describe('displayCases', () => {
    it.each(contract.displayCases.map((c) => [c.id, c] as const))('%s', (id, c) => {
      expect(ContextBudget.display(c.input), id).toStrictEqual(c.expected);
    });
  });
});
