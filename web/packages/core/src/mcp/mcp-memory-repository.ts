/**
 * In-memory server storage (`McpServerRepository`), for tests and hosts without a persistence layer. Semantics
 * match the production implementation: adding is atomic (validate everything, then write once) and the slug
 * is made unique in the same step.
 */

import { McpServerLimitError, type McpServerAddition, type McpServerRepository } from './mcp-add-probe';
import { uniqueSlug } from './mcp-pure';
import {
  MCP_SERVER_SCHEMA_VERSION,
  type McpConnectionState,
  type McpServerRecord,
  type McpToolPermission,
  type McpToolSnapshot,
} from './mcp-types';

export interface McpMemoryServerRepository extends McpServerRepository {
  records: Map<string, McpServerRecord>;
  snapshots: Map<string, McpToolSnapshot[]>;
  permissions: Map<string, Record<string, McpToolPermission>>;
  connectionStates: Map<string, McpConnectionState>;
}

export function createMemoryMcpServerRepository(): McpMemoryServerRepository {
  const records = new Map<string, McpServerRecord>();
  const snapshots = new Map<string, McpToolSnapshot[]>();
  const permissions = new Map<string, Record<string, McpToolPermission>>();
  const connectionStates = new Map<string, McpConnectionState>();
  return {
    records,
    snapshots,
    permissions,
    connectionStates,
    async hasServer(id) {
      return records.has(id);
    },
    async serverCount() {
      return records.size;
    },
    async addServer(addition: McpServerAddition, maxServers: number) {
      if (records.has(addition.id)) throw new Error('MCP server id already exists');
      if (records.size >= maxServers) throw new McpServerLimitError(maxServers);
      const record: McpServerRecord = {
        id: addition.id,
        name: addition.name,
        slug: uniqueSlug(addition.name, [...records.values()].map((r) => r.slug)),
        url: addition.url,
        authKind: addition.authKind,
        iconURL: addition.iconURL,
        createdAt: addition.createdAt,
        updatedAt: addition.createdAt,
        schemaVersion: MCP_SERVER_SCHEMA_VERSION,
      };
      records.set(record.id, record);
      snapshots.set(record.id, addition.snapshots);
      permissions.set(record.id, { ...addition.permissions });
      connectionStates.set(record.id, addition.connectionState);
      return record;
    },
    async deleteServer(id) {
      records.delete(id);
      snapshots.delete(id);
      permissions.delete(id);
      connectionStates.delete(id);
    },
  };
}
