import type { AdditionalBodyRecord } from './additional-body-settings';

/**
 * The "Additional request body" entry row in advanced settings.
 */
export type AdditionalBodyEntryRow = {
  visible: true;
  enabled: boolean;
  status: 'notInUse' | 'fieldsCount';
  /** Number of root-level fields; omitted when the content is not a JSON object (the editor points out what is wrong). */
  count?: number;
};

export function additionalBodyEntryRow(
  record: Pick<AdditionalBodyRecord, 'raw' | 'enabled'> | null,
): AdditionalBodyEntryRow {
  if (!record?.enabled || !record.raw.trim()) return { visible: true, enabled: true, status: 'notInUse' };
  const count = rootFieldCount(record.raw);
  return { visible: true, enabled: true, status: 'fieldsCount', ...(count === undefined ? {} : { count }) };
}

function rootFieldCount(raw: string): number | undefined {
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? Object.keys(parsed).length : undefined;
  } catch {
    return undefined;
  }
}
