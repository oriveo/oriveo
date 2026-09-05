import type { CSSProperties } from 'react';
import { lucideForEmoji } from '../../lib/skills/skill-icon-mapping';

interface SkillIconProps {
  icon: string;
  /** Tint color; defaults to the parent currentColor, so outer CSS can drive it with var(--skill-color). */
  color?: string;
  /** Icon size in px. Lucide takes a size prop; the emoji fallback approximates it with fontSize. */
  size?: number;
  /** Container className, applied to both the svg and the fallback span. */
  className?: string;
  /** strokeWidth - Lucide defaults to 2; 1.75 to 2 looks right on UI cards. */
  strokeWidth?: number;
  /** Extra styles. */
  style?: CSSProperties;
}

/**
 * Skill icon renderer: draws a Lucide vector icon when the name maps to one, and falls back to
 * the original emoji otherwise.
 *
 * color defaults to "currentColor" so the svg inherits the parent CSS color; setting
 * `color: var(--skill-color)` on the container is enough to tint everything consistently.
 */
export function SkillIcon({
  icon,
  color = 'currentColor',
  size = 18,
  className,
  strokeWidth = 2,
  style,
}: SkillIconProps) {
  const Lucide = lucideForEmoji(icon);
  if (Lucide) {
    return (
      <Lucide
        size={size}
        color={color}
        strokeWidth={strokeWidth}
        aria-hidden="true"
        className={className}
        style={style}
      />
    );
  }
  return (
    <span
      aria-hidden="true"
      className={className}
      style={{ fontSize: size + 4, lineHeight: 1, ...style }}
    >
      {icon}
    </span>
  );
}
