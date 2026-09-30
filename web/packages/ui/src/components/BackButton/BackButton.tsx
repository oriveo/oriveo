import type { ComponentPropsWithRef } from 'react';
import styles from './BackButton.module.css';

// Accepts a ref so callers can move focus onto the back button when a secondary pane opens
// (in React 19 `ref` is a regular prop and travels with the rest props).
interface BackButtonProps extends Omit<ComponentPropsWithRef<'button'>, 'children' | 'aria-label'> {
  /** Screen reader label (localized by the caller, e.g. `tc('back')`). */
  label: string;
}

/**
 * The app-wide page back button: a bare chevron with no fill, border or shadow.
 *
 * Uses the same path as the iOS / Android `OriveoBackButton` (24 grid, 2.2 stroke): 22px icon,
 * 40px touch target, --o-text; hover only changes the colour, pressed drops to 50% opacity,
 * and it mirrors in RTL. The caller passes the action through `onClick`. To line the icon box up
 * with the page margin, give it `margin-inline-start: -9px`.
 */
export function BackButton({ label, className, type = 'button', ...rest }: BackButtonProps) {
  return (
    <button
      type={type}
      aria-label={label}
      className={`${styles.backButton} ${className ?? ''}`}
      {...rest}
    >
      <svg
        className={styles.icon}
        width={22}
        height={22}
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2.2}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        <path d="M14.5 5.5L8 12l6.5 6.5" />
      </svg>
    </button>
  );
}
