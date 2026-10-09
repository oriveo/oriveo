/**
 * State of the "additional request body" entry row in advanced settings: the row shows "not in use" or "N fields" according to the stored record.
 */
import { describe, expect, it } from 'vitest';
import { additionalBodyEntryRow } from '../additional-body-entry';

describe('additional request body entry row', () => {
  it('no record, a disabled record, or empty content -> not in use', () => {
    expect(additionalBodyEntryRow(null)).toEqual({ visible: true, enabled: true, status: 'notInUse' });
    expect(additionalBodyEntryRow({ raw: '{"a":1}', enabled: false })).toEqual({ visible: true, enabled: true, status: 'notInUse' });
    expect(additionalBodyEntryRow({ raw: ' \n', enabled: true })).toEqual({ visible: true, enabled: true, status: 'notInUse' });
  });

  it('sending on: number of root-level fields', () => {
    expect(additionalBodyEntryRow({ raw: '{"top_k":3,"chat_template_kwargs":{"enable_thinking":true,"x":1}}', enabled: true }))
      .toEqual({ visible: true, enabled: true, status: 'fieldsCount', count: 2 });
  });
});
