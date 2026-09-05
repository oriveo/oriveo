import styles from './StatusPill.module.css';

interface StatusPillProps {
  status: 'connected' | 'syncing' | 'issue';
  label?: string;
}

const defaultLabels: Record<StatusPillProps['status'], string> = {
  connected: 'Connected',
  syncing: 'Syncing…',
  issue: 'Issue',
};

export function StatusPill({ status, label }: StatusPillProps) {
  return (
    <span className={`${styles.pill} ${styles[status]}`}>
      <span className={styles.dot} />
      {label ?? defaultLabels[status]}
    </span>
  );
}
