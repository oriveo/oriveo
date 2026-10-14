"use client";

import Image from "next/image";
import {
  ButterflyIcon,
  CompassIcon,
  FlameIcon,
  LighthouseIcon,
  MoonStarsIcon,
  MountainsIcon,
  PlanetIcon,
  SailboatIcon,
  SunHorizonIcon,
  TreeEvergreenIcon,
  type Icon,
} from "@phosphor-icons/react";
import { useIsDarkTheme } from "../lib/hooks/useIsDarkTheme";
import { resolveOfficialProviderLogo } from "./provider-logo-assets";
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

/** Default avatar icon -> Phosphor component and color token (fixture palette: detailRow.* -> --o-row-*, capability.* -> --o-cap-*). */
const RELAY_AVATAR_ICON_ART: Record<RelayAvatarIconId, { Icon: Icon; color: string }> = {
  planet: { Icon: PlanetIcon, color: "var(--o-row-indigo)" },
  compass: { Icon: CompassIcon, color: "var(--o-row-teal)" },
  sailboat: { Icon: SailboatIcon, color: "var(--o-row-cyan)" },
  lighthouse: { Icon: LighthouseIcon, color: "var(--o-cap-attachment)" },
  mountains: { Icon: MountainsIcon, color: "var(--o-cap-web-search)" },
  "sun-horizon": { Icon: SunHorizonIcon, color: "var(--o-row-orange)" },
  flame: { Icon: FlameIcon, color: "var(--o-row-rose)" },
  "tree-evergreen": { Icon: TreeEvergreenIcon, color: "var(--o-cap-vision)" },
  "moon-stars": { Icon: MoonStarsIcon, color: "var(--o-cap-reasoning)" },
  butterfly: { Icon: ButterflyIcon, color: "var(--o-cap-tools)" },
};

/** Draws just the icon (the sheet cells use it too); with forceDark the theme of this small box is pinned to dark so the color tokens take their dark values. */
export function RelayAvatarIconArt({ icon, size, forceDark }: { icon: RelayAvatarIconId; size: number; forceDark?: boolean }) {
  const { Icon: Art, color } = RELAY_AVATAR_ICON_ART[icon];
  return (
    <span className={styles.relayAvatar} style={{ width: size, height: size }} data-theme={forceDark ? "dark" : undefined}>
      <Art size={size} weight="duotone" color={color} aria-hidden="true" />
    </span>
  );
}

interface RelayAvatarProps {
  avatar: RelayAvatarValue;
  size: number;
  forceDark?: boolean;
}

/** Relay avatar: brand = official asset, icon = tinted Phosphor duotone, initial = neutral secondary text color, generic = relay icon; none has a base plate or a border. */
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
    const { Icon: Art, color } = RELAY_AVATAR_ICON_ART[avatar.icon];
    return (
      <span
        className={styles.relayAvatar}
        style={box}
        data-relay-avatar={marker}
        data-theme={forceDark ? "dark" : undefined}
      >
        <Art size={size} weight="duotone" color={color} aria-hidden="true" />
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
