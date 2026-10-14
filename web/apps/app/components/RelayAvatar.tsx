"use client";

import Image from "next/image";
import { useIsDarkTheme } from "../lib/hooks/useIsDarkTheme";
import { resolveOfficialProviderLogo } from "./provider-logo-assets";
import { RELAY_AVATAR_BRAND_LOGO_KIND, relayAvatarMarker, type RelayAvatar as RelayAvatarValue } from "./relay-avatar";
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

interface RelayAvatarProps {
  avatar: RelayAvatarValue;
  size: number;
  forceDark?: boolean;
}

/** Relay avatar: brand = official asset, initial = neutral secondary text color, generic = relay icon; none has a base plate or a border. */
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
