import type { ReactNode } from 'react';
import styles from './PageSection.module.css';

interface PageSectionProps {
  eyebrow?: string;
  title: string;
  description?: string;
  children?: ReactNode;
}

export function PageSection({ eyebrow, title, description, children }: PageSectionProps) {
  return (
    <section className={styles.section}>
      {eyebrow && <span className={styles.eyebrow}>{eyebrow}</span>}
      <h2 className={styles.title}>{title}</h2>
      {description && <p className={styles.description}>{description}</p>}
      {children && <div className={styles.body}>{children}</div>}
    </section>
  );
}
