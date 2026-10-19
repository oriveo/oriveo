import { describe, expect, it } from 'vitest';

import {
  MemoryItems,
  type MemoryBackupMergeInput,
  type MemoryItem,
  type MemoryItemInput,
  type MemoryLegacySyncInput,
  type MemoryMergeInput,
  type MemoryMigrateInput,
  type MemoryPushInput,
} from '../memory-items';
import { ContextContractFixture } from './fixture';

interface Case<I = Record<string, unknown>, E = unknown> {
  id: string;
  input: I;
  expected: E;
}

interface MemoryItemsContract {
  constants: {
    uuidNamespace: { value: string };
    legacyKeys: { memoryText: string; antiForget: string };
    migrationMutationSuffix: string;
    contentMaxCodePoints: number;
    organizeSystemPrompt: string;
    organizeMaxItems: number;
    rawViewSeparator: string;
    serverTimestampSentinel: string;
  };
  fieldOrder: string[];
  canonicalCases: Array<Case<MemoryItemInput, MemoryItem>>;
  migrationCases: Array<Case<MemoryMigrateInput, MemoryItem[]>>;
  injectableCases: Array<
    Case<
      { items: MemoryItemInput[]; conversationId: string; folderId: string | null; now: string },
      { standingInstructions: string[]; memory: string[] }
    >
  >;
  mergeCases: Array<Case<MemoryMergeInput>>;
  orderCases: Array<Case<{ items: MemoryItemInput[] }, string[]>>;
  tombstoneCases: Array<
    Case<{ item: MemoryItemInput; mutationId: string; deviceId: string; deletedAt: string }, MemoryItem>
  >;
  pushCases: Array<Case<MemoryPushInput>>;
  conflictCases: Array<
    Case<
      { itemId: string; pending: MemoryItemInput; remote: MemoryItemInput },
      { original: Record<string, unknown>; copy: MemoryItem }
    >
  >;
  legacySyncCases: Array<
    Case<
      Omit<MemoryLegacySyncInput, 'now'>,
      { create: MemoryItem[]; update: Array<Record<string, unknown>>; writePrefs: unknown }
    >
  >;
  compileCases: Array<Case<{ uid: string; items: MemoryItem[] }>>;
  rawViewCases: Array<Case<{ items: MemoryItem[]; text?: string; newIds?: string[] }, Record<string, unknown>>>;
  organizeCases: Array<Case<{ content?: string; response?: string }>>;
  backupCases: Array<Case<Record<string, unknown>>>;
}

const contract = ContextContractFixture.load<MemoryItemsContract>('memory-items.v2.json');
// Time and ids the fixture does not compare: only there to satisfy the pure function's parameters.
const FIXED_NOW = '2026-10-16T00:00:00Z';
const ORIGINAL_MUTATION_ID = 'f0000000-0000-4000-8000-0000000000f0';

function cases<I, E>(group: Array<Case<I, E>>): Array<readonly [string, Case<I, E>]> {
  return group.map((c) => [c.id, c] as const);
}

/** Keeps only the keys the fixture states (partial expectations). */
function pick(actual: object, expected: Record<string, unknown>): Record<string, unknown> {
  const source = actual as Record<string, unknown>;
  return Object.fromEntries(Object.keys(expected).map((k) => [k, source[k]]));
}

const canonicalAll = (items: MemoryItemInput[]) => items.map(MemoryItems.canonical);

describe('ContextContractMemoryItems', () => {
  it('constants match the module', () => {
    const constants = MemoryItems.constants;
    expect(constants.uuidNamespace).toBe(contract.constants.uuidNamespace.value);
    expect(constants.legacyKeys).toStrictEqual(contract.constants.legacyKeys);
    expect(constants.migrationMutationSuffix).toBe(contract.constants.migrationMutationSuffix);
    expect(constants.contentMaxCodePoints).toBe(contract.constants.contentMaxCodePoints);
    expect(constants.organizeSystemPrompt).toBe(contract.constants.organizeSystemPrompt);
    expect(constants.organizeMaxItems).toBe(contract.constants.organizeMaxItems);
    expect(constants.rawViewSeparator).toBe(contract.constants.rawViewSeparator);
  });

  it.each(cases(contract.canonicalCases))('canonical %s', (_, c) => {
    const item = MemoryItems.canonical(c.input);
    expect(Object.keys(item)).toStrictEqual(contract.fieldOrder);
    expect(item).toStrictEqual(c.expected);
  });

  it.each(cases(contract.migrationCases))('migrate %s', (_, c) => {
    expect(MemoryItems.migrate(c.input)).toStrictEqual(c.expected);
  });

  it.each(cases(contract.injectableCases))('injectable %s', (_, c) => {
    const result = MemoryItems.injectable({ ...c.input, items: canonicalAll(c.input.items) });
    expect({
      standingInstructions: result.standingInstructions.map((m) => m.id),
      memory: result.memory.map((m) => m.id),
    }).toStrictEqual(c.expected);
  });

  it.each(cases(contract.orderCases))('listOrder %s', (_, c) => {
    expect(MemoryItems.listOrder(canonicalAll(c.input.items)).map((m) => m.id)).toStrictEqual(c.expected);
  });

  it.each(cases(contract.tombstoneCases))('tombstone %s', (_, c) => {
    const item = MemoryItems.tombstone({ ...c.input, item: MemoryItems.canonical(c.input.item) });
    expect(item).toStrictEqual(c.expected);
  });

  it.each(cases(contract.mergeCases))('merge %s', (_, c) => {
    expect(MemoryItems.merge(c.input)).toStrictEqual(c.expected);
  });

  it.each(cases(contract.pushCases))('push %s', (_, c) => {
    expect(MemoryItems.push(c.input)).toStrictEqual(c.expected);
  });

  it.each(cases(contract.conflictCases))('conflictCopy %s', (_, c) => {
    const result = MemoryItems.conflictCopy({
      itemId: c.input.itemId,
      pending: MemoryItems.canonical(c.input.pending),
      remote: MemoryItems.canonical(c.input.remote),
      originalMutationId: ORIGINAL_MUTATION_ID,
    });
    expect(pick(result.original, c.expected.original)).toStrictEqual(c.expected.original);
    expect(result.original.mutationId).toBe(ORIGINAL_MUTATION_ID);
    expect(result.copy).toStrictEqual(c.expected.copy);
  });

  it.each(cases(contract.compileCases))('compileLegacy %s', (_, c) => {
    expect(MemoryItems.compileLegacy(c.input)).toStrictEqual(c.expected);
  });

  it.each(cases(contract.legacySyncCases))('legacySync %s', (_, c) => {
    const result = MemoryItems.legacySync({ ...c.input, now: FIXED_NOW });
    expect(result.create).toStrictEqual(c.expected.create);
    expect(result.update.map((item, i) => pick(item, c.expected.update[i] ?? {}))).toStrictEqual(c.expected.update);
    expect(result.writePrefs).toStrictEqual(c.expected.writePrefs);
  });

  const rawRenderCases = contract.rawViewCases.filter((c) => c.input.text === undefined);
  const rawApplyCases = contract.rawViewCases.filter((c) => c.input.text !== undefined);

  it.each(cases(rawRenderCases))('rawRender %s', (_, c) => {
    expect({ text: MemoryItems.rawRender(c.input.items) }).toStrictEqual(c.expected);
  });

  it.each(cases(rawApplyCases))('rawApply %s', (_, c) => {
    const result = MemoryItems.rawApply({
      items: c.input.items,
      text: c.input.text ?? '',
      newIds: c.input.newIds ?? [],
    });
    expect(result).toStrictEqual(c.expected);
  });

  const organizeRequestCases = contract.organizeCases.filter((c) => c.input.content !== undefined);
  const organizeParseCases = contract.organizeCases.filter((c) => c.input.response !== undefined);

  it.each(cases(organizeRequestCases))('organizeRequest %s', (_, c) => {
    expect(MemoryItems.organizeRequest(c.input.content ?? '')).toStrictEqual(c.expected);
  });

  it.each(cases(organizeParseCases))('organizeParse %s', (_, c) => {
    expect(MemoryItems.organizeParse(c.input.response ?? '')).toStrictEqual(c.expected);
  });

  const backupSectionCases = contract.backupCases.filter((c) => c.input.mode === undefined);
  const backupMergeCases = contract.backupCases.filter((c) => c.input.mode !== undefined);

  it.each(cases(backupSectionCases))('backupSection %s', (_, c) => {
    expect(MemoryItems.backupSection(c.input.items as MemoryItem[])).toStrictEqual(c.expected);
  });

  it.each(cases(backupMergeCases))('backupMerge %s', (_, c) => {
    expect(MemoryItems.backupMerge(c.input as unknown as MemoryBackupMergeInput)).toStrictEqual(c.expected);
  });
});
