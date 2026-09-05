'use client';

import { Plus, Trash2 } from 'lucide-react';
import type { RelayKeyValue } from '@oriveo/shared';
import styles from './RelayKeyValueEditor.module.css';

interface RelayKeyValueEditorProps {
  label: string;
  name: string;
  values?: RelayKeyValue[];
  onChange: (values: RelayKeyValue[] | undefined) => void;
  addLabel: string;
  removeLabel: string;
  keyPlaceholder: string;
  valuePlaceholder: string;
}

export function RelayKeyValueEditor({
  label,
  name,
  values,
  onChange,
  addLabel,
  removeLabel,
  keyPlaceholder,
  valuePlaceholder,
}: RelayKeyValueEditorProps) {
  const rows = values && values.length > 0 ? values : [{ key: '', value: '' }];

  const updateRow = (index: number, patch: Partial<RelayKeyValue>) => {
    const next = rows.map((row, rowIndex) => (
      rowIndex === index ? { ...row, ...patch } : row
    ));
    onChange(cleanRows(next));
  };

  const removeRow = (index: number) => {
    const next = rows.filter((_row, rowIndex) => rowIndex !== index);
    onChange(cleanRows(next));
  };

  const addRow = () => {
    onChange([...rows, { key: '', value: '' }]);
  };

  return (
    <div className={styles.editor}>
      <div className={styles.label}>{label}</div>
      <div className={styles.rows}>
        {rows.map((row, index) => (
          <div className={styles.row} key={`${index}-${row.key}`}>
            <input
              className={styles.input}
              value={row.key}
              aria-label={`${name}.${index}.key`}
              placeholder={keyPlaceholder}
              onChange={(event) => updateRow(index, { key: event.target.value })}
              autoComplete="off"
              spellCheck={false}
            />
            <input
              className={styles.input}
              value={row.value}
              aria-label={`${name}.${index}.value`}
              placeholder={valuePlaceholder}
              onChange={(event) => updateRow(index, { value: event.target.value })}
              autoComplete="off"
              spellCheck={false}
            />
            <button
              type="button"
              className={styles.iconButton}
              aria-label={`${removeLabel} ${index + 1}`}
              onClick={() => removeRow(index)}
            >
              <Trash2 size={15} strokeWidth={2.2} />
            </button>
          </div>
        ))}
      </div>
      <button type="button" className={styles.addButton} onClick={addRow}>
        <Plus size={14} strokeWidth={2.2} />
        {addLabel}
      </button>
    </div>
  );
}

function cleanRows(rows: RelayKeyValue[]): RelayKeyValue[] | undefined {
  const cleaned = rows
    .map((row) => ({ key: row.key.trim(), value: row.value }))
    .filter((row) => row.key.length > 0);
  return cleaned.length > 0 ? cleaned : undefined;
}
