'use client';

import styles from './Mcp.module.css';

export function McpSwitch({
  checked,
  disabled,
  label,
  onChange,
  describedBy,
  testId,
}: {
  checked: boolean;
  disabled?: boolean;
  label: string;
  onChange: (next: boolean) => void;
  describedBy?: string;
  testId?: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      aria-describedby={describedBy}
      data-testid={testId}
      disabled={disabled}
      className={styles.switch}
      data-checked={checked || undefined}
      onClick={() => onChange(!checked)}
    >
      <span className={styles.switchThumb} aria-hidden="true" />
    </button>
  );
}
