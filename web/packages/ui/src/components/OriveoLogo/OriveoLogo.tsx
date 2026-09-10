import styles from './OriveoLogo.module.css';

interface OriveoLogoProps {
  size?: number;
  /** Show the outer breathing glow (hero usage only). */
  withGlow?: boolean;
  className?: string;
}

/**
 * The Oriveo logo.
 *
 * The mark is a raster gradient ring rather than something an SVG can draw procedurally, so this
 * renders `/brand-logo.png` (256px, transparent background — a dark tile behind the mark reads as a
 * pasted-on square, most obviously in a light theme). Bitmap scaling has none of the small-size
 * stroke-width problems the previous vector mark had, so there is no separate micro variant.
 *
 * The file lives in `apps/app/public/`, the only app that currently uses this component. Another
 * app adopting it has to ship the image too.
 */
export function OriveoLogo({ size = 24, withGlow = false, className }: OriveoLogoProps) {
  const img = (
    // eslint-disable-next-line @next/next/no-img-element -- packages/ui does not depend on next/image
    <img
      src="/brand-logo.png"
      alt=""
      aria-hidden="true"
      width={size}
      height={size}
      draggable={false}
      className={styles.logo}
    />
  );

  if (!withGlow) {
    return <span className={`${styles.wrap} ${className ?? ''}`}>{img}</span>;
  }

  return (
    <span
      className={`${styles.wrap} ${styles.wrapHero} ${className ?? ''}`}
      style={{ width: size, height: size }}
    >
      <span className={styles.glowOuter} aria-hidden="true" />
      <span className={styles.glowInner} aria-hidden="true" />
      {img}
    </span>
  );
}
