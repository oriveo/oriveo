'use client';

import { useTranslations } from 'next-intl';
import type { StreamActivity } from '@oriveo/core/providers/types';
import styles from './StreamActivityLine.module.css';

/** Display context for the `mcp_tool` activity. It is read from the step that is currently `running` in the message's `toolSteps`, not carried by the activity event. */
export interface StreamActivityMcpContext {
  server: string;
  tool: string;
}

/**
 * Activity to label. The typing indicator uses the same mapping when it swaps its label. The keys
 * are written as literals so that the unused-message check can see them.
 */
export function useStreamActivityLabel(label: StreamActivity | 'neutral', mcp?: StreamActivityMcpContext | null): string {
  const t = useTranslations('pages.chat');
  if (label === 'web_search') return t('activityWebSearch');
  // When the running step cannot be read yet (it has not been written to the message), fall back to the neutral label rather than half a sentence.
  if (label === 'mcp_tool' && mcp) return t('activityMcpTool', { server: mcp.server, tool: mcp.tool });
  return t('generating');
}

/**
 * The waiting line under the message body. `resolveStreamActivityPresentation` decides when it
 * shows; this component only decides how it looks.
 */
export function StreamActivityLine({ label, mcp }: { label: StreamActivity | 'neutral'; mcp?: StreamActivityMcpContext | null }) {
  const text = useStreamActivityLabel(label, mcp);
  return (
    <div className={styles.line} role="status">
      <span className={styles.shimmer}>{text}</span>
    </div>
  );
}
