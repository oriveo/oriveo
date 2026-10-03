'use client';

import styles from './Mcp.module.css';

export function McpSwitch({ checked, disabled, label, onChange }: { checked: boolean; disabled?: boolean; label: string; onChange: (next: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      className={styles.switch}
      data-checked={checked || undefined}
      onClick={() => onChange(!checked)}
    >
      <span className={styles.switchThumb} aria-hidden="true" />
    </button>
  );
}
