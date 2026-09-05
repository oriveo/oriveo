import { useId } from 'react';
import styles from './OriveoLogo.module.css';

interface OriveoLogoProps {
  size?: number;
  /** Show the outer breathing glow (hero usage only). */
  withGlow?: boolean;
  className?: string;
}

/** Below 40px the orbit stroke falls under 1.2px and the micro variant is needed; see the comment below. */
const MICRO_MAX_SIZE = 40;

/**
 * The Oriveo logo.
 *
 * The two orbits have different radii (371x186 and 376x228): perfectly congruent ellipses are
 * almost tangent where they cross and produce a long, muddy parallel stretch. The electron carries
 * a background-colored clearance ring, because the orbits themselves have a gradient that spans
 * both light and dark ends and no single electron color can stay legible across it.
 *
 * At 40 and above: the full mark, orbit stroke width 30 (1.17px at 40px, above the visibility threshold).
 * Below 40: the micro variant, stroke widened to 56 (1.31px at 24px), and no electron at all
 *   since it only turns into noise at that size. Both orbits are kept; a single one reads as Saturn
 *   rather than an atom.
 */
export function OriveoLogo({ size = 24, withGlow = false, className }: OriveoLogoProps) {
  // useId keeps the SVG defs of multiple instances from colliding.
  const uid = useId().replace(/[:]/g, '');
  const bgId = `o-logo-bg-${uid}`;
  const orbId = `o-logo-orb-${uid}`;
  const haloId = `o-logo-halo-${uid}`;
  const ring1Id = `o-logo-r1-${uid}`;
  const ring2Id = `o-logo-r2-${uid}`;
  const socketId = `o-logo-socket-${uid}`;

  const isMicro = size < MICRO_MAX_SIZE;

  const svg = (
    <svg
      aria-hidden="true"
      fill="none"
      viewBox="0 0 1024 1024"
      width={size}
      height={size}
      className={styles.logo}
      style={{ borderRadius: Math.max(4, Math.round(size * 0.22)) }}
    >
      <defs>
        <radialGradient id={bgId} cx="50%" cy="40%" r="72%">
          <stop offset="0%" stopColor="#3B2A86" />
          <stop offset="60%" stopColor="#231657" />
          <stop offset="100%" stopColor="#120B33" />
        </radialGradient>
        <radialGradient id={orbId} cx="36%" cy="30%" r="70%">
          <stop offset="0%" stopColor="#ffffff" />
          <stop offset="40%" stopColor="#E4CCFF" />
          <stop offset="100%" stopColor="#8A55F0" />
        </radialGradient>
        {!isMicro && (
          <>
            <radialGradient id={haloId} cx="50%" cy="50%" r="50%">
              <stop offset="0%" stopColor="rgba(192,142,255,0.42)" />
              <stop offset="100%" stopColor="rgba(192,142,255,0)" />
            </radialGradient>
            {/* gradientTransform cancels each ellipse's rotate so the highlight direction stays in canvas space. */}
            <linearGradient
              id={ring1Id}
              gradientUnits="userSpaceOnUse"
              x1="180"
              y1="180"
              x2="844"
              y2="844"
              gradientTransform="rotate(26, 512, 512)"
            >
              <stop offset="0%" stopColor="#F4EAFF" />
              <stop offset="100%" stopColor="#B084FF" />
            </linearGradient>
            <linearGradient
              id={ring2Id}
              gradientUnits="userSpaceOnUse"
              x1="180"
              y1="180"
              x2="844"
              y2="844"
              gradientTransform="rotate(-56, 512, 512)"
            >
              <stop offset="0%" stopColor="#A97CFF" />
              <stop offset="100%" stopColor="#9260FF" />
            </linearGradient>
            <radialGradient id={socketId} cx="50%" cy="50%" r="50%">
              <stop offset="0%" stopColor="#1A0F44" stopOpacity="0.58" />
              <stop offset="55%" stopColor="#1A0F44" stopOpacity="0.40" />
              <stop offset="100%" stopColor="#1A0F44" stopOpacity="0" />
            </radialGradient>
          </>
        )}
      </defs>

      <rect width="1024" height="1024" fill={`url(#${bgId})`} />

      {isMicro ? (
        <>
          {/* The gradient sweep is invisible at this size, so use the mid-tone solid color of the full mark. */}
          <ellipse
            cx="512"
            cy="512"
            rx="376"
            ry="228"
            stroke="#9F72FF"
            strokeWidth="56"
            transform="rotate(56, 512, 512)"
          />
          <ellipse
            cx="512"
            cy="512"
            rx="371"
            ry="186"
            stroke="#E4D3FF"
            strokeWidth="56"
            transform="rotate(-26, 512, 512)"
          />
          <circle cx="512" cy="512" r="118" fill={`url(#${orbId})`} />
        </>
      ) : (
        <>
          <circle cx="512" cy="512" r="330" fill={`url(#${haloId})`} />

          {/* Far orbit first, near orbit second; the lightness difference then reads as depth. */}
          <ellipse
            cx="512"
            cy="512"
            rx="376"
            ry="228"
            stroke={`url(#${ring2Id})`}
            strokeWidth="30"
            transform="rotate(56, 512, 512)"
          />
          <ellipse
            cx="512"
            cy="512"
            rx="371"
            ry="186"
            stroke={`url(#${ring1Id})`}
            strokeWidth="30"
            transform="rotate(-26, 512, 512)"
          />

          <circle cx="512" cy="512" r="150" fill={`url(#${socketId})`} />
          <circle cx="512" cy="512" r="84" fill={`url(#${orbId})`} />
          <ellipse
            cx="484"
            cy="478"
            rx="22"
            ry="15"
            fill="#ffffff"
            opacity="0.5"
            transform="rotate(-32, 484, 478)"
          />

          {/* The clearance ring #27195F is the measured backdrop color here: it separates the electron over an orbit and disappears over the background. */}
          <circle cx="845.4" cy="349.4" r="44" fill="#27195F" />
          <circle cx="845.4" cy="349.4" r="34" fill="#FFFFFF" />
          <circle cx="301.7" cy="200.3" r="40" fill="#27195F" />
          <circle cx="301.7" cy="200.3" r="30" fill="#F4ECFF" />
          <circle cx="178.6" cy="674.6" r="36" fill="#27195F" />
          <circle cx="178.6" cy="674.6" r="26" fill="#EDE0FF" />
          <circle cx="722.3" cy="823.7" r="32" fill="#27195F" />
          <circle cx="722.3" cy="823.7" r="22" fill="#DCC9FF" />
        </>
      )}
    </svg>
  );

  if (!withGlow) {
    return <span className={`${styles.wrap} ${className ?? ''}`}>{svg}</span>;
  }

  return (
    <span
      className={`${styles.wrap} ${styles.wrapHero} ${className ?? ''}`}
      style={{ width: size, height: size }}
    >
      <span className={styles.glowOuter} aria-hidden="true" />
      <span className={styles.glowInner} aria-hidden="true" />
      {svg}
    </span>
  );
}
