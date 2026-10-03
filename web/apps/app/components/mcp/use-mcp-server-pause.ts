'use client';

import { useCallback } from 'react';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';

/**
 * "Pause this server for now": turns its switch off in every conversation. The server record,
 * credentials and tools are all kept, and quarantined tools stay quarantined; it can be switched back
 * on later from the tools panel of any conversation.
 */
export function useMcpServerPause(): (serverId: string) => Promise<void> {
  return useCallback(async (serverId: string) => {
    const store = useMcpStore.getState();
    const scopes = Object.entries(store.conversationServers)
      .filter(([, ids]) => ids.includes(serverId))
      .map(([scope]) => scope);
    for (const scope of scopes) {
      try {
        await store.setServerEnabled(scope, serverId, false);
      } catch {
        // A conversation that failed to switch off shows the "tools updated" notice in its panel again next time; the others are unaffected.
      }
    }
  }, []);
}
