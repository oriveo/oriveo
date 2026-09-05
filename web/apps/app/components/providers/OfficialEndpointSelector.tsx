'use client';

import styles from './OfficialEndpointSelector.module.css';

export interface OfficialEndpointCardOption {
  id: string;
  label: string;
  baseURL: string;
}

interface OfficialEndpointSelectorProps {
  description?: string | null;
  options: OfficialEndpointCardOption[];
  value: string;
  onChange: (id: string) => void;
}

export function OfficialEndpointSelector({
  description,
  options,
  value,
  onChange,
}: OfficialEndpointSelectorProps) {
  return (
    <div className={styles.selector}>
      {description ? <p className={styles.description}>{description}</p> : null}
      <div className={styles.grid}>
        {options.map((option) => {
          const isSelected = option.id === value;
          return (
            <button
              key={option.id}
              type="button"
              className={styles.option}
              data-selected={isSelected}
              aria-pressed={isSelected}
              onClick={() => onChange(option.id)}
            >
              <div className={styles.optionHeader}>
                <span className={styles.optionTitle}>{option.label}</span>
                <span className={styles.optionCode}>{option.id}</span>
              </div>
              <span className={styles.optionUrl}>
                {option.baseURL.replace(/^https?:\/\//, '')}
              </span>
              <span className={styles.optionCheck} aria-hidden="true">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                  <path
                    d="M5 13l4 4L19 7"
                    stroke="currentColor"
                    strokeWidth="2.4"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
