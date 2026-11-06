import { describe, expect, it } from 'vitest';
import { takeSilentPurgeAbort } from './purge-abort-guard';

describe('purge abort guard', () => {
  it('records_referencesUnavailable_fromBothLogs', () => {
    const purge = '[ImagePurge] candidates=1 deleted=0 bytes=0 aborted=references-unavailable';
    const sweep = '[ImageOrphanSweep] candidates=0 deleted=0 bytes=0 stamped=0 aborted=references-unavailable';
    console.info(purge);
    expect(takeSilentPurgeAbort()).toBe(purge);
    console.info(sweep);
    expect(takeSilentPurgeAbort()).toBe(sweep);
  });

  it('ignores_otherOutcomes', () => {
    console.info('[ImagePurge] candidates=1 deleted=1 bytes=9 aborted=none');
    console.info('[ImagePurge] candidates=1 deleted=0 bytes=0 aborted=partition-changed');
    expect(takeSilentPurgeAbort()).toBeNull();
  });
});
