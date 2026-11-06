import { afterEach, expect } from 'vitest';

/**
 * When the reference read fails, purge fails closed: it swallows the error, deletes nothing and
 * leaves one console.info line. In tests that path also swallows a handwritten idb mock missing an
 * export, or jsdom having no IndexedDB, so a test whose assertions skip the deletions passes without
 * purge having run. Any test outside the file that covers this
 * abort path fails when it reaches it.
 */
const SILENT_ABORT = /^\[Image(?:Purge|OrphanSweep)\] .*aborted=references-unavailable$/;
const FILES_TESTING_THE_ABORT = /\/image-orphan-sweeper\.test\.ts$/;

let pending: string | null = null;

/** Returns the abort line recorded for this test and clears it. */
export function takeSilentPurgeAbort(): string | null {
  const line = pending;
  pending = null;
  return line;
}

export function installPurgeAbortGuard(): void {
  const originalInfo = console.info;
  console.info = (...args: unknown[]) => {
    const [first] = args;
    if (typeof first === 'string' && SILENT_ABORT.test(first)) {
      if (!FILES_TESTING_THE_ABORT.test(expect.getState().testPath ?? '')) pending = first;
    }
    originalInfo(...args);
  };
  afterEach(() => {
    const line = takeSilentPurgeAbort();
    if (line) {
      throw new Error(
        `${line}\nThe reference read failed closed, so purge never ran in this test. `
          + 'Check the idb and partition mocks for missing exports, or use fake-indexeddb and the real partition.',
      );
    }
  });
}
