import type { ReactNode } from 'react';
import styles from './InfoCard.module.css';

interface InfoCardProps {
  title: string;
  description: string;
  icon?: ReactNode;
  href?: string;
}

export function InfoCard({ title, description, icon, href }: InfoCardProps) {
  const Tag = href ? 'a' : 'div';
  return (
    <Tag className={styles.card} {...(href ? { href } : {})}>
      {icon && <div className={styles.icon}>{icon}</div>}
      <h3 className={styles.title}>{title}</h3>
      <p className={styles.description}>{description}</p>
    </Tag>
  );
}
