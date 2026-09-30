import type { ComponentPropsWithRef } from 'react';
// Same flat look as BackButton (40px target, no fill/border/shadow, hover changes colour only,
// 50% opacity while pressed), so it reuses those styles directly
import styles from '../BackButton/BackButton.module.css';

interface CloseButtonProps extends Omit<ComponentPropsWithRef<'button'>, 'children' | 'aria-label'> {
  /** Screen reader label (localized by the caller, e.g. `tc('close')`). */
  label: string;
}

/**
 * The app-wide close button: a bare ×, same path as the iOS / Android `OriveoCloseButton`
 * (24 grid, 2 stroke). Defaults to --o-text; panels with their own palette set
 * `--o-icon-button-color` / `--o-icon-button-hover-color` through `style`. Do not pass
 * `style={{ color }}` (inline color beats :hover, so hover stops changing color), and do not
 * override color with a className, because the load order of two CSS Modules is not guaranteed.
 */
export function CloseButton({ label, className, type = 'button', ...rest }: CloseButtonProps) {
  return (
    <button
      type={type}
      aria-label={label}
      className={`${styles.backButton} ${className ?? ''}`}
      {...rest}
    >
      <svg
        width={22}
        height={22}
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        <path d="M7 7l10 10M17 7L7 17" />
      </svg>
    </button>
  );
}
