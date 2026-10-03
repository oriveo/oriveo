/**
 * Message keys (in the `mcp` namespace) for the "invalid address" state of the add-server flow. An
 * address with a userinfo component gets its own message telling the user to use an access token
 * instead, consistent with iOS.
 */

import type { McpInvalidUrlReason } from '@oriveo/core/mcp/index';

export type McpInvalidUrlMessageKey = 'addServer.invalidUrl' | 'addServer.invalidUrlHasUserinfo';

export function mcpInvalidUrlMessageKey(reason: McpInvalidUrlReason): McpInvalidUrlMessageKey {
  return reason === 'hasUserinfo' ? 'addServer.invalidUrlHasUserinfo' : 'addServer.invalidUrl';
}
