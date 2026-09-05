'use client';

import React from 'react';
import type { ReactNode } from 'react';
import { ChevronDown } from 'lucide-react';
import styles from './ComposerToolButton.module.css';

interface ComposerToolButtonProps {
  icon: ReactNode;
  label: string;
  value?: string;
  count?: number;
  active?: boolean;
  emphasized?: boolean;
  /** Active request capabilities, in the same web → reasoning order as iOS. */
  capabilityIcons?: ReadonlyArray<{ key: string; icon: ReactNode }>;
  /** Model-behavior-only overrides have no dedicated capability icon. */
  showEmphasisOrb?: boolean;
  expandable?: boolean;
  disabled?: boolean;
  /** A server-owned value is visible but never an interactive control. */
  readOnly?: boolean;
  onClick: () => void;
  ariaLabel?: string;
  /** Screen-reader equivalent of iOS accessibilityValue / Android stateDescription. */
  ariaDescription?: string;
  ariaExpanded?: boolean;
  /**
   * Id of the surface this button expands. `aria-expanded` on its own is an adjective with no
   * object — a screen reader can say "expanded" but not what got expanded. Only pass it while the
   * surface is mounted: `aria-controls` pointing at a missing id is itself an a11y defect.
   */
  ariaControls?: string;
  ariaPressed?: boolean;
  title?: string;
  /** Lets the owner return focus here when the surface it opened closes. */
  buttonRef?: React.Ref<HTMLButtonElement>;
}

export function ComposerToolButton({
  icon,
  label,
  value,
  count,
  active = false,
  emphasized = false,
  capabilityIcons = [],
  showEmphasisOrb = false,
  expandable = false,
  disabled = false,
  readOnly = false,
  onClick,
  ariaLabel,
  ariaDescription,
  ariaExpanded,
  ariaControls,
  ariaPressed,
  title,
  buttonRef,
}: ComposerToolButtonProps) {
  const meta = count != null && count > 0 ? String(count) : value;
  const accessibleLabel = ariaLabel ?? (readOnly && value ? `${label}: ${value}` : label);

  if (readOnly) {
    return (
      <div
        className={styles.button}
        data-read-only="true"
        aria-label={accessibleLabel}
        aria-description={ariaDescription}
        role="status"
      >
        <span className={styles.iconWrap} aria-hidden="true">{icon}</span>
        <span className={styles.label}>{label}</span>
        {meta ? <span className={styles.trailing}><span className={styles.meta}>{meta}</span></span> : null}
      </div>
    );
  }

  return (
    <button
      ref={buttonRef}
      type="button"
      className={styles.button}
      data-active={active}
      data-emphasized={emphasized}
      data-disabled={disabled || undefined}
      disabled={disabled || undefined}
      aria-label={accessibleLabel}
      aria-description={ariaDescription}
      aria-expanded={ariaExpanded}
      aria-controls={ariaControls}
      aria-pressed={ariaPressed}
      aria-disabled={disabled || undefined}
      title={title}
      onClick={disabled ? undefined : onClick}
    >
      <span className={styles.iconWrap} aria-hidden="true">
        {icon}
      </span>
      <span className={styles.label}>{label}</span>
      {capabilityIcons.length > 0 ? (
        <span className={styles.capabilityIcons} aria-hidden="true">
          {capabilityIcons.map((item) => (
            <span key={item.key} data-capability={item.key}>{item.icon}</span>
          ))}
        </span>
      ) : showEmphasisOrb ? <span className={styles.emphasisOrb} aria-hidden="true" /> : null}
      {(meta || expandable) && (
        <span className={styles.trailing}>
          {meta ? <span className={styles.meta}>{meta}</span> : null}
          {expandable ? <ChevronDown className={styles.chevron} size={14} aria-hidden="true" /> : null}
        </span>
      )}
    </button>
  );
}
