import type { ReactElement } from 'react';
import { render } from '@testing-library/react';
import { IntlProvider } from 'use-intl';
import type { AIModel, McpToolStep, Provider } from '@oriveo/shared';
import type { McpConnectionState, McpServerRecord, McpToolSnapshot } from '@oriveo/core/mcp/index';
import enMessages from '../../../messages/en.json';
import { useMcpStore } from '../../../lib/core/mcp/mcp-store';

/**
 * Renders with the **real English copy**, so a missing key or a malformed ICU message fails here
 * instead of hiding behind a fake `t => key` translation. `IntlProvider` keeps the `t` reference
 * stable, which avoids the infinite re-render caused by a mock returning a new function every time.
 */
export function renderWithIntl(ui: ReactElement) {
  return render(
    <IntlProvider locale="en" messages={enMessages} timeZone="UTC" onError={(error) => { throw error; }}>
      {ui}
    </IntlProvider>,
  );
}

export const LINEAR = '11111111-1111-4111-8111-111111111111';
export const NOTION = '22222222-2222-4222-8222-222222222222';
export const GITHUB = '33333333-3333-4333-8333-333333333333';

export function server(id: string, name: string, overrides: Partial<McpServerRecord> = {}): McpServerRecord {
  return {
    id,
    name,
    slug: name.toLowerCase().replace(/[^a-z0-9]/g, ''),
    url: `https://mcp.${name.toLowerCase()}.example/mcp`,
    authKind: 'auto',
    iconURL: null,
    createdAt: 1,
    updatedAt: 1,
    schemaVersion: 1,
    ...overrides,
  };
}

export function tool(serverId: string, toolName: string, overrides: Partial<McpToolSnapshot> = {}): McpToolSnapshot {
  return {
    serverId,
    toolName,
    title: `Title of ${toolName}`,
    description: `Description of ${toolName}`,
    inputSchema: { type: 'object', properties: { query: { type: 'string' } } },
    annotations: {},
    contentHash: `hash-${toolName}`,
    readOnly: true,
    pendingReview: false,
    oversized: false,
    updatedAt: 1,
    ...overrides,
  };
}

export function connection(serverId: string, status: McpConnectionState['status'], lastSuccessAt: number | null = 1_700_000_000_000): McpConnectionState {
  return { serverId, status, lastSuccessAt, negotiatedVersion: '2026-07-28', generation: 'stateless', sessionId: null };
}

/** Puts the in-memory state straight into the desired shape (the UI only reads projections of the store; the persistence path has its own tests in mcp-idb / mcp-store). */
export function seedMcpStore(state: Partial<ReturnType<typeof useMcpStore.getState>>): void {
  useMcpStore.setState({ uid: 'user-1', hydrated: true, servers: [], snapshots: {}, permissions: {}, connections: {}, conversationServers: {}, ...state });
}

export function resetMcpStore(): void {
  useMcpStore.getState().reset();
}

export function step(overrides: Partial<McpToolStep> & Pick<McpToolStep, 'id'>): McpToolStep {
  return {
    scope: 'mcp',
    serverId: LINEAR,
    serverName: 'Linear',
    toolName: 'search_issues',
    title: 'Search issues',
    argsSummary: 'open · bug',
    status: 'done',
    step: 1,
    durationMs: 1200,
    ...overrides,
  };
}

export const byokProvider = { id: 'p-openai', kind: 'openai', name: 'OpenAI', authMode: 'apiKey' } as unknown as Provider;
export const chatModel = { id: 'gpt-test', name: 'gpt-test', capabilities: [], transport: 'openai_chat' } as unknown as AIModel;
