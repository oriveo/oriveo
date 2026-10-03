'use client';

import { useState } from 'react';
import { mcpServerInitial } from '../../lib/core/mcp/mcp-presentation';
import styles from './Mcp.module.css';

/**
 * Server icon: when the server supplies its own icon, show it as is, with no outline and no backing
 * plate. The initial-letter tile is only the fallback for a missing icon or one that fails to load.
 */
export function McpServerIcon({ name, iconURL, size = 36 }: { name: string; iconURL?: string | null; size?: number }) {
  const [failed, setFailed] = useState(false);
  const style = { width: size, height: size, fontSize: Math.round(size * 0.42), borderRadius: Math.round(size * 0.3) };
  if (iconURL && iconURL.startsWith('https://') && !failed) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        className={styles.serverIconImage}
        style={{ width: size, height: size }}
        src={iconURL}
        alt=""
        referrerPolicy="no-referrer"
        onError={() => setFailed(true)}
      />
    );
  }
  return (
    <span className={styles.serverTile} style={style} aria-hidden="true">
      {mcpServerInitial(name)}
    </span>
  );
}
