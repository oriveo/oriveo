'use client';

import { useState } from 'react';
import { mcpServerInitial } from '../../lib/core/mcp/mcp-presentation';
import { bundledMcpIconURL } from '@oriveo/core/mcp/index';
import { useIsDarkTheme } from '../../lib/hooks/useIsDarkTheme';
import styles from './Mcp.module.css';

/**
 * Server icon: a well-known vendor gets its original logo, bundled with the app; any other server that
 * supplies its own icon gets that one. Either is shown as is, with no outline and no backing plate. The
 * initial-letter tile is only the fallback for a missing icon or one that fails to load.
 */
export function McpServerIcon({ name, iconURL, serverURL, size = 36 }: { name: string; iconURL?: string | null; serverURL?: string | null; size?: number }) {
  const [failedURL, setFailedURL] = useState<string | null>(null);
  const dark = useIsDarkTheme();
  let remote: string | null = null;
  try {
    const url = new URL(iconURL ?? "");
    if (url.protocol === "https:" && !url.username && !url.password) remote = url.href;
  } catch { /* Unknown services can use an initial. */ }
  const resolvedIconURL = bundledMcpIconURL(name, serverURL, dark) ?? remote;
  const style = { width: size, height: size, fontSize: Math.round(size * 0.42), borderRadius: Math.round(size * 0.3) };
  if (resolvedIconURL && failedURL !== resolvedIconURL) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        className={styles.serverIconImage}
        style={{ width: size, height: size }}
        src={resolvedIconURL}
        alt=""
        referrerPolicy="no-referrer"
        onError={() => setFailedURL(resolvedIconURL)}
      />
    );
  }
  return (
    <span className={styles.serverTile} style={style} aria-hidden="true">
      {mcpServerInitial(name)}
    </span>
  );
}
