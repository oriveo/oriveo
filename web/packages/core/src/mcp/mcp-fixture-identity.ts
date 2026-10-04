import type { McpClientIdentity } from './mcp-auth';

/**
 * The client identity the frozen `auth/` fixtures (`shared/test-fixtures/mcp/auth`) were recorded
 * with. Test support only: the app derives its identity from the origin it is served from and never
 * uses this one.
 */
export const MCP_FIXTURE_CLIENT_ID = 'https://app.example.com/oauth/mcp-client.json';
export const MCP_FIXTURE_REDIRECT_URI = 'https://app.example.com/mcp/oauth/callback';

export const MCP_FIXTURE_CLIENT_IDENTITY: McpClientIdentity = {
  redirectUri: MCP_FIXTURE_REDIRECT_URI,
  redirectUris: ['oriveo://mcp/oauth/callback'],
  clientMetadataDocumentUrl: MCP_FIXTURE_CLIENT_ID,
  applicationType: 'native',
};
