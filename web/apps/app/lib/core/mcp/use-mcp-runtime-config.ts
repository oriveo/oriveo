'use client';

import { useMemo, useSyncExternalStore } from 'react';
import type { McpRuntimeConfig } from '@oriveo/core/mcp/index';
import { getCachedMetadataVersion, onVersionChange } from '../metadata/metadata-client';
import { currentMcpRuntimeConfig } from './mcp-store';

/** The MCP runtime configuration read from the model catalog, recomputed whenever the metadata snapshot changes. The UI hides its entry points when `enabled = false`. */
export function useMcpRuntimeConfig(): McpRuntimeConfig {
  const metadataVersion = useSyncExternalStore(onVersionChange, getCachedMetadataVersion, () => 0);
  // `metadataVersion` is the invalidation key: the config is re-read whenever the snapshot changes.
  return useMemo(() => currentMcpRuntimeConfig(), [metadataVersion]);
}
