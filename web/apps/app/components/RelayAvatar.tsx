"use client";

import Image from "next/image";
import { useIsDarkTheme } from "../lib/hooks/useIsDarkTheme";
import { resolveOfficialProviderLogo } from "./provider-logo-assets";
import { RELAY_AVATAR_GLYPHS } from "./relay-avatar-glyphs.generated";
import {
  RELAY_AVATAR_BRAND_LOGO_KIND,
  relayAvatarMarker,
  type RelayAvatar as RelayAvatarValue,
  type RelayAvatarIconId,
} from "./relay-avatar";
import styles from "./ProviderIcon.module.css";

/**
 * Relay fallback icon - "path nodes" form (replacing the earlier "up/down double arrows", which the owner found ugly)
 *
 * Design: 3 dots joined by thin lines into a triangular path, plus a short line on top for data flowing in,
 * visually conveying "data flows through a relay node", isomorphic to the platform symbols
 * `point.3.connected.trianglepath.dotted` / Android Material `Hub`.
 */
export function RelayWaypointsIcon({ size, className }: { size: number; className?: string }) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {/* Path connecting lines */}
      <path d="M7.5 6.5l9 0M7.5 6.5l-3 11M16.5 6.5l3 11M5.5 17.5l13 0" opacity="0.55" />
      {/* Nodes (filled circles) */}
      <circle cx="7.5" cy="6.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="16.5" cy="6.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="5" cy="17.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="19" cy="17.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" />
    </svg>
  );
}

/** Default avatar icon -> color token (fixture palette: detailRow.* -> --o-row-*, capability.* -> --o-cap-*; dark 400 / light 600 by theme). */
const RELAY_AVATAR_ICON_COLOR: Record<RelayAvatarIconId, string> = {
  "paper-plane": "var(--o-row-indigo)",
  "signal-tower": "var(--o-row-teal)",
  "relay-bell": "var(--o-cap-attachment)",
  satellite: "var(--o-cap-reasoning)",
  signpost: "var(--o-cap-vision)",
  "arch-bridge": "var(--o-cap-web-search)",
  kite: "var(--o-row-rose)",
  "message-bottle": "var(--o-row-cyan)",
  pennant: "var(--o-row-orange)",
  "hot-air-balloon": "var(--o-cap-tools)",
};

/**
 * Original icon art (generated file relay-avatar-glyphs.generated.ts, 24x24 grid): single-color currentColor,
 * with layer opacity carried by the asset; paths with a null stroke are filled, the rest are stroked only. Fills the avatar box, with no base plate and no border.
 */
function RelayAvatarGlyph({ icon, size }: { icon: RelayAvatarIconId; size: number }) {
  const groups = RELAY_AVATAR_GLYPHS[icon] ?? [];
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      style={{ color: RELAY_AVATAR_ICON_COLOR[icon] }}
      aria-hidden="true"
      focusable="false"
      data-relay-avatar-glyph={icon}
    >
      {groups.map((group, groupIndex) => (
        <g key={groupIndex} transform={group.transform ?? undefined}>
          {group.paths.map((path, pathIndex) =>
            path.stroke ? (
              <path
                key={pathIndex}
                d={path.d}
                fill="none"
                stroke="currentColor"
                strokeWidth={path.stroke.width}
                strokeLinecap={path.stroke.cap as "butt" | "round" | "square"}
                opacity={path.opacity ?? undefined}
              />
            ) : (
              <path key={pathIndex} d={path.d} fill="currentColor" opacity={path.opacity ?? undefined} />
            ),
          )}
        </g>
      ))}
    </svg>
  );
}

interface RelayAvatarProps {
  avatar: RelayAvatarValue;
  size: number;
  forceDark?: boolean;
}

/** Relay avatar: brand = official asset, icon = original icon in a single tint, initial = neutral secondary text color, generic = relay icon; none has a base plate or a border. */
export function RelayAvatar({ avatar, size, forceDark }: RelayAvatarProps) {
  const systemDark = useIsDarkTheme();
  const isDark = forceDark ?? systemDark;
  const marker = relayAvatarMarker(avatar);
  const box = { width: size, height: size };

  if (avatar.kind === "brand") {
    const logo = resolveOfficialProviderLogo(RELAY_AVATAR_BRAND_LOGO_KIND[avatar.brand], isDark);
    if (logo) {
      return (
        <span className={styles.relayAvatar} style={box} data-relay-avatar={marker}>
          <Image className={styles.bareLogo} src={logo} alt="" width={size} height={size} draggable={false} />
        </span>
      );
    }
  }
  if (avatar.kind === "icon") {
    return (
      <span
        className={styles.relayAvatar}
        style={box}
        data-relay-avatar={marker}
        data-theme={forceDark ? "dark" : undefined}
      >
        <RelayAvatarGlyph icon={avatar.icon} size={size} />
      </span>
    );
  }
  if (avatar.kind === "initial") {
    return (
      <span
        className={`${styles.relayAvatar} ${styles.relayAvatarInitial}`}
        style={{ ...box, fontSize: Math.round(size * 0.62) }}
        data-relay-avatar={marker}
      >
        {avatar.text}
      </span>
    );
  }
  return (
    <span className={styles.relayAvatar} style={box} data-relay-avatar="generic">
      <RelayWaypointsIcon size={size} className={styles.bareFallback} />
    </span>
  );
}
