import { fireEvent, screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MCP_RUNTIME_CONFIG_FALLBACK, type McpRuntimeConfig } from '@oriveo/core/mcp/index';
import { McpToolsControl } from '../McpToolsControl';
import { GITHUB, LINEAR, NOTION, byokProvider, chatModel, connection, renderWithIntl, resetMcpStore, seedMcpStore, server, tool } from './mcp-test-kit';

const mocks = vi.hoisted(() => ({
  push: vi.fn(),
  supports: vi.fn(() => true),
  runtimeConfig: null as McpRuntimeConfig | null,
}));

// The global setup replaces next-intl with a fake translation that returns the key; switch back to the
// real one (use-intl) here so that, with renderWithIntl, assertions run against the real copy.
vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: mocks.push, replace: vi.fn() }) }));
// Whether a connection can carry tools is decided by the mcp-chat predicate (which has its own tests);
// this only checks how the UI renders that verdict.
vi.mock('../../../lib/core/mcp/mcp-chat', () => ({ connectionSupportsMcpTools: () => mocks.supports() }));
vi.mock('../../../lib/core/mcp/use-mcp-runtime-config', () => ({ useMcpRuntimeConfig: () => mocks.runtimeConfig }));

const SCOPE = 'conversation-1';

function seedThreeServers(enabled: string[] = [LINEAR, NOTION]) {
  seedMcpStore({
    servers: [server(LINEAR, 'Linear'), server(NOTION, 'Notion'), server(GITHUB, 'GitHub')],
    snapshots: {
      [LINEAR]: Array.from({ length: 7 }, (_, index) => tool(LINEAR, `linear_${index}`)),
      [NOTION]: Array.from({ length: 14 }, (_, index) => tool(NOTION, `notion_${index}`)),
      [GITHUB]: [tool(GITHUB, 'list_repos')],
    },
    connections: { [LINEAR]: connection(LINEAR, 'connected'), [NOTION]: connection(NOTION, 'connected'), [GITHUB]: connection(GITHUB, 'needsAuth') },
    conversationServers: { [SCOPE]: enabled },
  });
}

function renderControl(props: Partial<Parameters<typeof McpToolsControl>[0]> = {}) {
  return renderWithIntl(
    <McpToolsControl scope={SCOPE} provider={byokProvider} model={chatModel} isStreaming={false} onOpenModelSwitcher={vi.fn()} {...props} />,
  );
}

const pill = () => screen.getByRole('button', { name: 'Tools for this chat' });
const panel = () => screen.getByRole('dialog', { name: 'Tools for this chat' });

beforeEach(() => {
  mocks.push.mockReset();
  mocks.supports.mockReturnValue(true);
  mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK };
  resetMcpStore();
});

describe('Tools pill', () => {
  it('is not highlighted and shows no number when the conversation has no server switched on', () => {
    seedThreeServers([]);
    renderControl();
    expect(pill().getAttribute('data-emphasized')).toBe('false');
    expect(pill().textContent).toBe('Tools');
  });

  it('counts servers that are switched on and usable, excluding one that needs reauthorization', () => {
    seedThreeServers([LINEAR, NOTION, GITHUB]);
    renderControl();
    expect(pill().getAttribute('data-emphasized')).toBe('true');
    expect(pill().textContent).toBe('Tools2');
  });

  it('renders nothing at all when the master switch is off (the server config delivers enabled = false)', () => {
    mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK, enabled: false };
    seedThreeServers();
    const { container } = renderControl();
    expect(container.innerHTML).toBe('');
  });
});

describe('tools popover', () => {
  it('shows one server per row with tool count and switch state, and Reauthorize instead of a switch when authorization expired', () => {
    seedThreeServers();
    renderControl();
    fireEvent.click(pill());
    const rows = within(panel()).getAllByRole('listitem');
    // All three are well-known vendors, so each row shows the bundled logo instead of an initial tile.
    expect(rows.map((row) => row.textContent)).toEqual(['Linear7 tools', 'Notion14 tools', 'GitHubSign-in expiredSign in again']);
    expect(rows.map((row) => row.querySelector('img')?.getAttribute('src'))).toEqual(['/mcp-icons/light/linear.png', '/mcp-icons/light/notion.png', '/mcp-icons/light/github.png']);
    expect(within(rows[0]).getByRole('switch', { name: 'Use Linear in this chat' }).getAttribute('aria-checked')).toBe('true');
    expect(within(rows[2]).queryByRole('switch')).toBeNull();
    expect((within(rows[2]).getByRole('button', { name: 'Sign in again' }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('shows a token estimate at the bottom, taken from the same assembly function the send path uses', () => {
    seedThreeServers();
    renderControl();
    fireEvent.click(pill());
    const foot = within(panel()).getByText(/tools on\. Their descriptions are sent with every request/);
    // 21 tools; the estimate is rounded to the nearest hundred and prefixed with about
    expect(foot.textContent).toMatch(/^21 tools on\. Their descriptions are sent with every request, about [\d,]+00 tokens, billed at your model's price\.$/);
  });

  it('replaces the bottom note with a warning above the per-request tool limit (the number comes from runtime config)', () => {
    mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK, maxToolsPerRequest: 10 };
    seedThreeServers();
    renderControl();
    fireEvent.click(pill());
    const warning = within(panel()).getByRole('status');
    expect(warning.textContent).toBe('More than 10 tools are on. Only the first 10 will be sent.');
    expect(warning.getAttribute('data-tone')).toBe('warning');
  });

  it('shows the last successful time for an unreachable server and disables its switch when it is off', () => {
    seedMcpStore({
      servers: [server(LINEAR, 'Linear')],
      snapshots: { [LINEAR]: [tool(LINEAR, 'search')] },
      connections: { [LINEAR]: connection(LINEAR, 'unreachable', Date.now() - 3 * 3600_000) },
    });
    renderControl();
    fireEvent.click(pill());
    expect(within(panel()).getByText("Can't connect · last worked 3 hours ago")).not.toBeNull();
    expect((within(panel()).getByRole('switch') as HTMLButtonElement).disabled).toBe(true);
  });

  it('writes a switch toggle to this conversation scope only and leaves other conversations alone', () => {
    seedThreeServers([LINEAR]);
    const setServerEnabled = vi.fn(async () => {});
    seedMcpStore({ ...{ servers: [server(LINEAR, 'Linear'), server(NOTION, 'Notion')], snapshots: { [LINEAR]: [tool(LINEAR, 'a')], [NOTION]: [tool(NOTION, 'b')] }, conversationServers: { [SCOPE]: [LINEAR] } }, setServerEnabled });
    renderControl();
    fireEvent.click(pill());
    fireEvent.click(within(panel()).getByRole('switch', { name: 'Use Notion in this chat' }));
    expect(setServerEnabled).toHaveBeenCalledWith(SCOPE, NOTION, true);
    fireEvent.click(within(panel()).getByRole('switch', { name: 'Use Linear in this chat' }));
    expect(setServerEnabled).toHaveBeenLastCalledWith(SCOPE, LINEAR, false);
  });

  it('opens the management page in settings from Manage MCP servers', () => {
    seedThreeServers();
    renderControl();
    fireEvent.click(pill());
    fireEvent.click(within(panel()).getByRole('button', { name: 'Manage MCP servers' }));
    expect(mocks.push).toHaveBeenCalledWith('/settings/mcp');
    expect(screen.queryByRole('dialog', { name: 'Tools for this chat' })).toBeNull();
  });

  it('closes the popover on Esc', () => {
    seedThreeServers();
    renderControl();
    fireEvent.click(pill());
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('dialog', { name: 'Tools for this chat' })).toBeNull();
  });

  it('moves focus into the popover on open and returns it to the pill on Esc or a second pill click instead of dropping it on the page', () => {
    seedThreeServers();
    renderControl();
    pill().focus();
    fireEvent.click(pill());
    expect(document.activeElement).toBe(panel());

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(document.activeElement).toBe(pill());

    // Closing while focus is on a control inside the popover (here by clicking the pill again): returned as well
    fireEvent.click(pill());
    within(panel()).getAllByRole('switch')[0].focus();
    expect(panel().contains(document.activeElement)).toBe(true);
    fireEvent.click(pill());
    expect(screen.queryByRole('dialog', { name: 'Tools for this chat' })).toBeNull();
    expect(document.activeElement).toBe(pill());
  });
});

describe('empty state', () => {
  it('shows an explanation and a primary button into the add flow when there are no servers', () => {
    seedMcpStore({});
    renderControl();
    fireEvent.click(pill());
    expect(panel().querySelector('[data-mcp-state="empty"]')).not.toBeNull();
    expect(within(panel()).getByText('No tools yet')).not.toBeNull();
    fireEvent.click(within(panel()).getByRole('button', { name: 'Add MCP server' }));
    expect(mocks.push).toHaveBeenCalledWith('/settings/mcp?add=1');
  });
});

describe('current connection cannot carry tools', () => {
  it('dims the pill but still opens it, explains that the model cannot use tools, and shows the list dimmed and inert', () => {
    mocks.supports.mockReturnValue(false);
    seedThreeServers();
    const onOpenModelSwitcher = vi.fn();
    const { container } = renderControl({ onOpenModelSwitcher });
    expect(container.querySelector('[data-mcp-unsupported]')).not.toBeNull();
    // No number while dimmed: none of these servers' tools can be sent right now
    expect(pill().textContent).toBe('Tools');
    expect((pill() as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(pill());
    expect(within(panel()).getByText("This model can't use tools")).not.toBeNull();
    expect(within(panel()).getByText("This model doesn't support tool calling. Switch to another model to use tools.")).not.toBeNull();
    expect(panel().querySelector('[data-mcp-state="unsupported"]')).not.toBeNull();
    for (const toggle of within(panel()).getAllByRole('switch')) expect((toggle as HTMLButtonElement).disabled).toBe(true);
    expect(within(panel()).queryByRole('button', { name: 'Sign in again' })).toBeNull();
    // No token estimate: no tools will be sent
    expect(within(panel()).queryByText(/tools on\./)).toBeNull();
    fireEvent.click(within(panel()).getByRole('button', { name: 'Switch model' }));
    expect(onOpenModelSwitcher).toHaveBeenCalledTimes(1);
  });
});

describe('tool changes', () => {
  it('shows the change confirmation first on entering the panel when an enabled server has quarantined tools, but not while a reply is in progress', () => {
    const seed = () => seedMcpStore({
      servers: [server(LINEAR, 'Linear')],
      snapshots: { [LINEAR]: [tool(LINEAR, 'search'), tool(LINEAR, 'bulk_update', { readOnly: false, pendingReview: true })] },
      connections: { [LINEAR]: connection(LINEAR, 'connected') },
      conversationServers: { [SCOPE]: [LINEAR] },
    });
    seed();
    const first = renderControl({ isStreaming: true });
    fireEvent.click(pill());
    expect(screen.queryByText("Linear's tools have changed")).toBeNull();
    // The row plainly says there is an update, and the quarantined tool is not counted
    expect(within(panel()).getByText('Tools changed')).not.toBeNull();
    first.unmount();

    seed();
    renderControl();
    fireEvent.click(pill());
    expect(screen.getByText("Linear's tools have changed")).not.toBeNull();
    expect(screen.getByText('Title of bulk_update')).not.toBeNull();
  });
});
