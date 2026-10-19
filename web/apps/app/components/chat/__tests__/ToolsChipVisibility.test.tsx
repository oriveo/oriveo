import { screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MCP_RUNTIME_CONFIG_FALLBACK, type McpRuntimeConfig } from '@oriveo/core/mcp/index';
import { McpToolsControl } from '../../mcp/McpToolsControl';
import { LINEAR, byokProvider, chatModel, connection, renderWithIntl, resetMcpStore, seedMcpStore, server } from '../../mcp/__tests__/mcp-test-kit';

// Visibility rule of the "Tools" pill in the capability bar: shown only when the master switch is on and at least one server has been added (even if all are off),
// same rule as the library pill; hidden when none has been added, and the discovery entry is in Settings > MCP. Same-named cases as iOS / Android.

const mocks = vi.hoisted(() => ({ runtimeConfig: null as McpRuntimeConfig | null }));

vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn(), replace: vi.fn() }) }));
vi.mock('../../../lib/core/mcp/mcp-chat', () => ({ connectionSupportsMcpTools: () => true }));
vi.mock('../../../lib/core/mcp/use-mcp-runtime-config', () => ({ useMcpRuntimeConfig: () => mocks.runtimeConfig }));

const SCOPE = 'conversation-1';

function renderControl() {
  return renderWithIntl(<McpToolsControl scope={SCOPE} provider={byokProvider} model={chatModel} isStreaming={false} onOpenModelSwitcher={vi.fn()} />);
}

function seedOneServerAllOff() {
  seedMcpStore({ servers: [server(LINEAR, 'Linear')], connections: { [LINEAR]: connection(LINEAR, 'connected') }, conversationServers: { [SCOPE]: [] } });
}

beforeEach(() => {
  mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK };
  resetMcpStore();
});

describe('Tools pill visibility rule', () => {
  it('no server added: hidden even with the master switch on', () => {
    seedMcpStore({});
    const { container } = renderControl();
    expect(container.innerHTML).toBe('');
  });

  it('panel state not read yet (local MCP store not loaded): hidden', () => {
    const { container } = renderControl();
    expect(container.innerHTML).toBe('');
  });

  it('servers added but all off for this conversation: shown, without a number', () => {
    seedOneServerAllOff();
    renderControl();
    const pill = screen.getByRole('button', { name: 'Tools for this chat' });
    expect(pill.textContent).toBe('Tools');
    expect(pill.getAttribute('data-emphasized')).toBe('false');
  });

  it('master switch off: hidden even with servers', () => {
    mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK, enabled: false };
    seedOneServerAllOff();
    const { container } = renderControl();
    expect(container.innerHTML).toBe('');
  });
});
