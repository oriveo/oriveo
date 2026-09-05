import type { ReactNode, AnchorHTMLAttributes } from 'react';
import styles from './ButtonLink.module.css';

interface ButtonLinkProps extends AnchorHTMLAttributes<HTMLAnchorElement> {
  tone?: 'primary' | 'secondary';
  label?: string;
  children?: ReactNode;
}

export function ButtonLink({
  tone = 'primary',
  label,
  children,
  className,
  ...rest
}: ButtonLinkProps) {
  return (
    <a
      className={`${styles.link} ${styles[tone]} ${className ?? ''}`}
      {...rest}
    >
      {children ?? label}
    </a>
  );
}
