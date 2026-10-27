'use client';

// Two-tone icons for the settings home. They do not follow the theme color and are shared by light and dark.
// Gradient ids come from useId() so the same icon rendered several times on one page never cross-contaminates colors.

import { useId, type ReactNode } from 'react';

export type SettingsIconName =
  | 'memory'
  | 'context'
  | 'skills'
  | 'voice'
  | 'library'
  | 'mcp'
  | 'theme'
  | 'language'
  | 'backup'
  | 'feedback'
  | 'faq'
  | 'rate'
  | 'search'
  | 'keyboard';

interface IconDef {
  stops: Array<[string, number]>;
  paths: (gradient: string) => ReactNode;
}

const ICONS: Record<SettingsIconName, IconDef> = {
  memory: {
    stops: [["#F5B8FF", 0], ["#A855F7", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M4.3 7.4A3.3 3.3 0 1 1 10.9 7.4A3.3 3.3 0 1 1 4.3 7.4ZM2.3 11.8A3.3 3.3 0 1 1 8.9 11.8A3.3 3.3 0 1 1 2.3 11.8ZM4.3 16.4A3.3 3.3 0 1 1 10.9 16.4A3.3 3.3 0 1 1 4.3 16.4ZM9 4.1H9.6A1.4 1.4 0 0 1 11 5.5V18.3A1.4 1.4 0 0 1 9.6 19.7H9A1.4 1.4 0 0 1 7.6 18.3V5.5A1.4 1.4 0 0 1 9 4.1ZM13.1 7.4A3.3 3.3 0 1 1 19.7 7.4A3.3 3.3 0 1 1 13.1 7.4ZM15.1 11.8A3.3 3.3 0 1 1 21.7 11.8A3.3 3.3 0 1 1 15.1 11.8ZM13.1 16.4A3.3 3.3 0 1 1 19.7 16.4A3.3 3.3 0 1 1 13.1 16.4ZM14.4 4.1H15A1.4 1.4 0 0 1 16.4 5.5V18.3A1.4 1.4 0 0 1 15 19.7H14.4A1.4 1.4 0 0 1 13 18.3V5.5A1.4 1.4 0 0 1 14.4 4.1Z" fill={gradient} />
      <path d="M8.2 9.6c1.2.2 2 1 2 2.2M15.8 9.6c-1.2.2-2 1-2 2.2M7 14.8c1.3-.2 2.4.5 2.8 1.6M17 14.8c-1.3-.2-2.4.5-2.8 1.6" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  context: {
    stops: [["#7DEBFA", 0], ["#0EA5E9", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M5.1 3H18.9A2.1 2.1 0 0 1 21 5.1V5.1A2.1 2.1 0 0 1 18.9 7.2H5.1A2.1 2.1 0 0 1 3 5.1V5.1A2.1 2.1 0 0 1 5.1 3ZM5.1 16.8H18.9A2.1 2.1 0 0 1 21 18.9V18.9A2.1 2.1 0 0 1 18.9 21H5.1A2.1 2.1 0 0 1 3 18.9V18.9A2.1 2.1 0 0 1 5.1 16.8Z" fill={gradient} />
      <path d="M9 9.2l3 2.2 3-2.2M9 14.8l3-2.2 3 2.2" fill="none" stroke="#0EA5E9" strokeOpacity="1" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  skills: {
    stops: [["#FDE68A", 0], ["#F97316", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M3.16 18.44L11.64 9.96L14.04 12.36L5.56 20.84ZM16.5 2.6l1.3 3.6 3.6 1.3-3.6 1.3-1.3 3.6-1.3-3.6-3.6-1.3 3.6-1.3ZM21 13.2l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6Z" fill={gradient} />
      </>
    ),
  },
  voice: {
    stops: [["#86EFC1", 0], ["#10B981", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M3.4 9H3.4A1.4 1.4 0 0 1 4.8 10.4V13.6A1.4 1.4 0 0 1 3.4 15H3.4A1.4 1.4 0 0 1 2 13.6V10.4A1.4 1.4 0 0 1 3.4 9ZM7.7 6H7.7A1.4 1.4 0 0 1 9.1 7.4V16.6A1.4 1.4 0 0 1 7.7 18H7.7A1.4 1.4 0 0 1 6.3 16.6V7.4A1.4 1.4 0 0 1 7.7 6ZM12 3H12A1.4 1.4 0 0 1 13.4 4.4V19.6A1.4 1.4 0 0 1 12 21H12A1.4 1.4 0 0 1 10.6 19.6V4.4A1.4 1.4 0 0 1 12 3ZM16.3 6H16.3A1.4 1.4 0 0 1 17.7 7.4V16.6A1.4 1.4 0 0 1 16.3 18H16.3A1.4 1.4 0 0 1 14.9 16.6V7.4A1.4 1.4 0 0 1 16.3 6ZM20.6 9H20.6A1.4 1.4 0 0 1 22 10.4V13.6A1.4 1.4 0 0 1 20.6 15H20.6A1.4 1.4 0 0 1 19.2 13.6V10.4A1.4 1.4 0 0 1 20.6 9Z" fill={gradient} />
      </>
    ),
  },
  library: {
    stops: [["#B4C0FF", 0], ["#6366F1", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M4.2 5H5.8A1.2 1.2 0 0 1 7 6.2V18.8A1.2 1.2 0 0 1 5.8 20H4.2A1.2 1.2 0 0 1 3 18.8V6.2A1.2 1.2 0 0 1 4.2 5ZM9.2 3H10.8A1.2 1.2 0 0 1 12 4.2V18.8A1.2 1.2 0 0 1 10.8 20H9.2A1.2 1.2 0 0 1 8 18.8V4.2A1.2 1.2 0 0 1 9.2 3ZM16.92 4.09L20.80 5.06L17.08 20.01L13.20 19.04Z" fill={gradient} />
      <path d="M3.8 8.5h2.4M8.8 6.5h2.4M3.8 16.8h2.4M8.8 16.8h2.4" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  mcp: {
    stops: [["#FFB4BF", 0], ["#F43F5E", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M9.1 2.5H9.1A1.1 1.1 0 0 1 10.2 3.6V7.4A1.1 1.1 0 0 1 9.1 8.5H9.1A1.1 1.1 0 0 1 8 7.4V3.6A1.1 1.1 0 0 1 9.1 2.5ZM14.9 2.5H14.9A1.1 1.1 0 0 1 16 3.6V7.4A1.1 1.1 0 0 1 14.9 8.5H14.9A1.1 1.1 0 0 1 13.8 7.4V3.6A1.1 1.1 0 0 1 14.9 2.5ZM5.5 8H18.5V11.5A6.5 6.5 0 0 1 5.5 11.5ZM12 17H12A1 1 0 0 1 13 18V21A1 1 0 0 1 12 22H12A1 1 0 0 1 11 21V18A1 1 0 0 1 12 17Z" fill={gradient} />
      <path d="M12.8 9.8l-2 3h2.4l-1.6 2.8" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  theme: {
    stops: [["#FDBA74", 0], ["#F43F5E", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M2.8 12A9.2 9.2 0 1 1 21.2 12A9.2 9.2 0 1 1 2.8 12Z" fill={gradient} />
      <path d="M12 2.8A9.2 9.2 0 0 1 12 21.2Z" fill="#FFFFFF" fillOpacity="0.55" />
      </>
    ),
  },
  language: {
    stops: [["#93D5FF", 0], ["#3B82F6", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M2.8 12A9.2 9.2 0 1 1 21.2 12A9.2 9.2 0 1 1 2.8 12Z" fill={gradient} />
      <path d="M2.8 12h18.4M12 2.8c2.6 2.7 2.6 15.7 0 18.4M12 2.8c-2.6 2.7-2.6 15.7 0 18.4" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  backup: {
    stops: [["#7FF0DF", 0], ["#14B8A6", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M6.5 12H18.1A3.5 3.5 0 0 1 21.6 15.5V15.5A3.5 3.5 0 0 1 18.1 19H6.5A3.5 3.5 0 0 1 3 15.5V15.5A3.5 3.5 0 0 1 6.5 12ZM4.6 11.8A4.4 4.4 0 1 1 13.4 11.8A4.4 4.4 0 1 1 4.6 11.8ZM9.2 9.6A5.4 5.4 0 1 1 20 9.6A5.4 5.4 0 1 1 9.2 9.6Z" fill={gradient} />
      <path d="M12.4 17v-5.2M10.1 13.9l2.3-2.3 2.3 2.3" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  feedback: {
    stops: [["#A5C8FF", 0], ["#6366F1", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M5 4h14a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3h-6.5L7 21.5V18H5a3 3 0 0 1-3-3V7a3 3 0 0 1 3-3Z" fill={gradient} />
      <path d="M7 9.5h10M7 13h6" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  faq: {
    // Fixed icon colors from the design: icons do not follow the theme color and are shared by light and dark
    stops: [["#D6CBFF", 0], ["#8B5CF6", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M2.5 12A9.5 9.5 0 1 1 21.5 12A9.5 9.5 0 1 1 2.5 12Z" fill={gradient} />
      <path d="M9.5 9.5a2.6 2.6 0 1 1 3.6 2.4c-.7.3-1.1.9-1.1 1.6v.5M12 16.8v.01" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  keyboard: {
    stops: [["#CBD5E1", 0], ["#475569", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M5 5.5H19A3 3 0 0 1 22 8.5V15.5A3 3 0 0 1 19 18.5H5A3 3 0 0 1 2 15.5V8.5A3 3 0 0 1 5 5.5Z" fill={gradient} />
      <path d="M6 9.6h1M9.5 9.6h1M13 9.6h1M16.5 9.6h1.5M6 12.6h1M9.5 12.6h1M13 12.6h1M16.5 12.6h1.5M8 15.6h8" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  rate: {
    stops: [["#FDE68A", 0], ["#F59E0B", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M12 2.5l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5L12 17.3l-5.8 3.1 1.1-6.5L2.6 9.3l6.5-.9Z" fill={gradient} />
      </>
    ),
  },
  search: {
    stops: [["#D9F99D", 0], ["#65A30D", 1]],
    paths: (gradient: string) => (
      <>
      <path d="M3 10.5A7.5 7.5 0 1 1 18 10.5A7.5 7.5 0 1 1 3 10.5ZM16.56 14.29L21.51 19.24L19.24 21.51L14.29 16.56Z" fill={gradient} />
      <path d="M7.2 9.4a3.6 3.6 0 0 1 3-3" fill="none" stroke="#FFFFFF" strokeOpacity="0.92" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
};

export function SettingsIcon({ name, size = 26, className }: { name: SettingsIconName; size?: number; className?: string }) {
  const id = `settings-icon-${name}-${useId().replace(/:/g, '')}`;
  const icon = ICONS[name];
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      aria-hidden="true"
      focusable="false"
      className={className}
      data-settings-icon={name}
    >
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
          {icon.stops.map(([color, offset]) => (
            <stop key={offset} offset={offset} stopColor={color} />
          ))}
        </linearGradient>
      </defs>
      {icon.paths(`url(#${id})`)}
    </svg>
  );
}
