// Inline SVG icons used by the chat interface, kept in one place.
// The path, viewBox, strokeWidth and fill values are copied verbatim from the original inline
// SVGs, so the rendering is unchanged. The icons in @oriveo/ui use different paths and stroke
// widths, so the chat-specific set is maintained separately rather than reused.

export interface IconProps {
  size?: number;
  className?: string;
  'aria-hidden'?: boolean;
}

export function MenuIcon({ size = 18, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <line x1="3" y1="6" x2="21" y2="6" />
      <line x1="3" y1="12" x2="21" y2="12" />
      <line x1="3" y1="18" x2="21" y2="18" />
    </svg>
  );
}

export function ChevronDownIcon({ size = 12, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <polyline points="6 9 12 15 18 9" />
    </svg>
  );
}

export function ChevronLeftIcon({ size = 14, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <polyline points="15 18 9 12 15 6" />
    </svg>
  );
}

interface CloseIconProps extends IconProps {
  /** The stroke width is adjustable: the TopBar memory popover uses 2.4 and the expensive-model hint in ChatView uses 2.5. */
  strokeWidth?: number;
}

export function CloseIcon({ size = 12, strokeWidth = 2.4, className, 'aria-hidden': ariaHidden = true }: CloseIconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
  );
}

export function EditIcon({ size = 14, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  );
}

export function EyeOffIcon({ size = 14, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <path d="M3 3l18 18" />
      <path d="M10.6 10.5a3 3 0 0 0 4.2 4.2" />
      <path d="M9.9 4.2A10.3 10.3 0 0 1 12 4c5 0 9.3 3.1 11 8-1 2.6-2.9 4.8-5.2 6.2" />
      <path d="M6.2 6.2C3.7 7.6 1.7 9.7 1 12c.7 2 2.2 3.9 4.2 5.3" />
    </svg>
  );
}

export function DownloadIcon({ size = 16, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7 10 12 15 17 10" />
      <line x1="12" y1="15" x2="12" y2="3" />
    </svg>
  );
}

export function AttachmentIcon({ size = 16, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
    </svg>
  );
}

export function WarningIcon({ size = 14, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden={ariaHidden}>
      <path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" />
    </svg>
  );
}

interface AttachmentSyncIconProps extends IconProps {
  /** A full quota (blocked) draws a different path from a general warning. */
  blocked?: boolean;
}

export function AttachmentSyncIcon({ size = 14, blocked = false, className, 'aria-hidden': ariaHidden = true }: AttachmentSyncIconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      {blocked
        ? <path d="M2 2l20 20M17.5 19H9a7 7 0 0 1-6.71-9M9.36 9.36A6 6 0 0 1 21 11.5" />
        : <path d="M12 9v4m0 4h.01M5.94 6A8 8 0 0 1 21 11.5 5 5 0 0 1 19 21H6a4 4 0 0 1-1.06-7.86" />}
    </svg>
  );
}

export function ReasoningIcon({ size = 16, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <path d="M12 2a8 8 0 0 0-8 8c0 3.4 2.1 6.3 5 7.4V20h6v-2.6c2.9-1.1 5-4 5-7.4a8 8 0 0 0-8-8z" />
      <line x1="12" y1="14" x2="12" y2="18" />
    </svg>
  );
}

export function GlobeIcon({ size = 16, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <circle cx="12" cy="12" r="10" />
      <line x1="2" y1="12" x2="22" y2="12" />
      <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
    </svg>
  );
}

export function StopIcon({ size = 16, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden={ariaHidden}>
      <rect x="6" y="6" width="12" height="12" rx="2" />
    </svg>
  );
}

export function SendIcon({ size = 16, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <path d="M12 19V5" />
      <path d="M5 12l7-7 7 7" />
    </svg>
  );
}

export function CheckIcon({ size = 11, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <polyline points="20 6 9 17 4 12" />
    </svg>
  );
}

export function CopyIcon({ size = 11, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

export function RetryIcon({ size = 11, className, 'aria-hidden': ariaHidden = true }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden={ariaHidden}>
      <polyline points="23 4 23 10 17 10" />
      <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
    </svg>
  );
}
