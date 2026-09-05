'use client';

import { useState, useEffect } from 'react';
import styles from './UserAvatar.module.css';

interface UserAvatarProps {
  size: number;
  avatarURL?: string;
  fallbackName: string;
  className?: string;
  onClick?: () => void;
}

/**
 * Generic user avatar.
 * Loads the image URL and falls back to an initial on a gradient placeholder.
 */
export function UserAvatar({ size, avatarURL, fallbackName, className, onClick }: UserAvatarProps) {
  const [imgError, setImgError] = useState(false);
  useEffect(() => { setImgError(false); }, [avatarURL]);
  const initial = (fallbackName || '?').charAt(0).toUpperCase();
  const showImage = avatarURL && !imgError;
  const isGuest = !avatarURL && !fallbackName;

  return (
    <div
      className={`${styles.avatar} ${className ?? ''}`}
      style={{ width: size, height: size, fontSize: size * 0.4 }}
      onClick={onClick}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? (e) => e.key === 'Enter' && onClick() : undefined}
    >
      {showImage ? (
        // Avatar URLs are user-provided and may be arbitrary remote/blob URLs, which are not a good fit for next/image.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={avatarURL}
          alt=""
          className={styles.img}
          width={size}
          height={size}
          onError={() => setImgError(true)}
        />
      ) : isGuest ? (
        // Guest avatar shares the same sizing/styling path as remote avatars; keep a plain img to avoid bifurcated rendering.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src="/guest-avatar.svg"
          alt=""
          className={styles.img}
          width={size}
          height={size}
        />
      ) : (
        <span className={styles.initial}>{initial}</span>
      )}
    </div>
  );
}
