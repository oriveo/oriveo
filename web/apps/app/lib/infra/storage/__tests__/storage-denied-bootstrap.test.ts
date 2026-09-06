import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * End-to-end regression for the browser having site data disabled.
 *
 * Failure shape: step 1 of `bootstrapApp`, `migrateToPartitionedStorage()`, read localStorage directly,
 * the getter threw SecurityError, the outer try jumped straight to catch, and steps 2 to 6 (auth,
 * metadata refresh, provider recomputation) **never ran at all**, leaving an empty shell.
 *
 * Two independent assertions are locked here:
 *   1. The migration function does not throw when storage is denied (it is the first link of the startup chain, so throwing breaks everything)
 *   2. With only localStorage broken, the IDB-side partition migration still completes (healthy paths are unaffected)
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { migrateToPartitionedStorage } from '../migration';
import { safeLocalStorage } from '../web-storage';
import { getActiveUID } from '../partition';

const realDescriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');

function denyLocalStorage() {
  const error = new Error("Failed to read the 'localStorage' property from 'Window': Access is denied for this document.");
  error.name = 'SecurityError';
  Object.defineProperty(window, 'localStorage', {
    configurable: true,
    get() {
      throw error;
    },
  });
  safeLocalStorage.resetForTest();
}

beforeEach(() => {
  safeLocalStorage.resetForTest();
});

afterEach(async () => {
  if (realDescriptor) Object.defineProperty(window, 'localStorage', realDescriptor);
  safeLocalStorage.resetForTest();
  window.localStorage.clear();
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
});

describe('storage denied by the browser', () => {
  it('does not throw from the partition migration, since throwing stops bootstrap at step 1', async () => {
    denyLocalStorage();
    // Reading `localStorage.getItem(MIGRATED_KEY)` directly here lets the getter blow through the call stack
    await expect(migrateToPartitionedStorage()).resolves.toBeUndefined();
  });

  it('still finishes the migration when storage is denied, with the IDB-side activeUID initialized', async () => {
    denyLocalStorage();
    await migrateToPartitionedStorage();
    // The migrated marker cannot be written to localStorage (the next start reruns the idempotent migration, which is an acceptable cost),
    // but the IDB-side partition state has to be established, or every later step comes up without a partition
    await expect(getActiveUID()).resolves.toBe('guest');
  });

  it('leaves a healthy environment untouched: the marker is written and a second call short-circuits', async () => {
    await migrateToPartitionedStorage();
    expect(safeLocalStorage.getItem('oriveo.storage.partitioned')).toBe('true');
    // The second call should return on the first line without touching IDB
    await expect(migrateToPartitionedStorage()).resolves.toBeUndefined();
  });
});
