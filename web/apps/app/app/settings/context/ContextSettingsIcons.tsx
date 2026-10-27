// Monochrome icons for Settings > Context: transcribed verbatim from shared/icons/context-settings/*.svg; stroke / fill use currentColor and follow the color of the host element.

import type { ReactNode } from 'react';

export type ContextSettingsIconName =
  | 'cap-auto'
  | 'cap-custom'
  | 'cap-unlimited'
  | 'cost-extra'
  | 'cost-none'
  | 'header-cap'
  | 'header-overflow'
  | 'limit-window'
  | 'local-kept'
  | 'price-line';

const PATHS: Record<ContextSettingsIconName, ReactNode> = {
  'cap-auto': (
    <>
      <path d="M5.6 18.4A9 9 0 1 1 18.4 18.4" />
      <path d="M12 12l3.6-3.6" />
      <circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none" />
      <path d="M8.5 18.5h7" />
    </>
  ),
  'cap-custom': (
    <>
      <path d="M4 8h8.5M17.5 8H20M4 16h2.5M11.5 16H20" />
      <circle cx="15" cy="8" r="2.4" />
      <circle cx="9" cy="16" r="2.4" fill="currentColor" />
    </>
  ),
  'cap-unlimited': (
    <>
      <path d="M3.5 12h5.4M15.1 12h5.4" />
      <path d="M6.5 8.5L3 12l3.5 3.5M17.5 8.5L21 12l-3.5 3.5" />
      <circle cx="12" cy="12" r="2.6" />
    </>
  ),
  'cost-extra': (
    <>
      <circle cx="10" cy="13" r="7" />
      <path d="M7.8 10.6L10 13.3l2.2-2.7M7.8 14.5h4.4M10 13.3v3.2" />
      <path d="M19.5 3v5M17 5.5h5" />
    </>
  ),
  'cost-none': (
    <>
      <circle cx="12" cy="12" r="8" />
      <path d="M9.5 9.5L12 12.5l2.5-3M9.5 13.5h5M12 12.5v4" />
      <path d="M4 4l16 16" />
    </>
  ),
  'header-cap': (
    <>
      <path d="M4 19.5h16" />
      <path d="M4 5h2.5M9 5h2.5M14 5h2.5M19 5h1" />
      <path d="M12 16.5V9M8.8 12l3.2-3.2 3.2 3.2" />
    </>
  ),
  'header-overflow': (
    <>
      <path d="M3 9h2.5M8 9h2.2M14 9h1.5M18.5 9h2.5" />
      <path d="M7 20v-7M12 20V4.5M17 20v-4.5" />
      <path d="M9.8 5.8L12 3.6l2.2 2.2" />
    </>
  ),
  'limit-window': (
    <>
      <rect x="3.5" y="4.5" width="17" height="15" rx="4" />
      <path d="M7.5 9.5h5M7.5 13h9" />
      <circle cx="7.6" cy="16.5" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="10.2" cy="16.5" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="16.5" cy="9.5" r="1.3" fill="currentColor" stroke="none" />
    </>
  ),
  'local-kept': (
    <>
      <rect x="6" y="2.5" width="12" height="19" rx="3.2" />
      <path d="M9.6 11.8l1.8 1.8 3.2-3.4" />
      <path d="M10.8 18.3h2.4" />
    </>
  ),
  'price-line': (
    <>
      <path d="M3 11h2.2M8 11h2.2M13 11h2.2" strokeOpacity="0.6" />
      <path d="M3 19.5l5-5 3 2.2 6.5-7.2" />
      <path d="M14.6 9.5h2.9v2.9" />
      <circle cx="20" cy="4.8" r="1.7" fill="currentColor" stroke="none" />
    </>
  ),
};

export function ContextSettingsIcon({
  name,
  size = 16,
  className,
}: {
  name: ContextSettingsIconName;
  size?: number;
  className?: string;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      className={className}
    >
      {PATHS[name]}
    </svg>
  );
}
