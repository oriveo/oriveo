import type { ReactNode, ButtonHTMLAttributes } from 'react';
import styles from './Button.module.css';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  tone?: 'primary' | 'secondary' | 'danger';
  size?: 'sm' | 'md';
  children: ReactNode;
}

export function Button({
  tone = 'primary',
  size = 'md',
  children,
  className,
  ...rest
}: ButtonProps) {
  return (
    <button
      className={`${styles.btn} ${styles[tone]} ${styles[size]} ${className ?? ''}`}
      {...rest}
    >
      {children}
    </button>
  );
}
