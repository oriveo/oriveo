import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { McpConfirmationChoice, McpConfirmationRequest, McpReauthorizationChoice } from '@oriveo/core/mcp/index';
import {
  currentMcpConfirmationGate,
  currentMcpReauthorizationGate,
  useMcpConfirmationStore,
  useMcpReauthorizationStore,
} from '../../../lib/core/mcp/mcp-confirmation';
import { McpChatPresence, McpGlobalPrompts } from '../McpGlobalPrompts';
import { IntlProvider } from 'use-intl';
import enMessages from '../../../messages/en.json';
import { NOTION, renderWithIntl, resetMcpStore, seedMcpStore, server } from './mcp-test-kit';

const telemetry = vi.hoisted(() => ({ trackEvent: vi.fn() }));
vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('../../../lib/core/telemetry', () => ({ trackEvent: telemetry.trackEvent }));

const CONVERSATION = 'conversation-1';
const LONG_TEXT = 'Weekly report. '.repeat(40);

function request(overrides: Partial<McpConfirmationRequest> = {}): McpConfirmationRequest {
  return {
    conversationId: CONVERSATION,
    serverId: NOTION,
    serverName: 'Notion',
    serverHost: 'mcp.notion.com',
    toolName: 'create_page',
    toolTitle: 'Create page',
    arguments: { parent: 'Weekly reports', title: 'Week 40 · open bugs (12)', content: LONG_TEXT },
    inputSchema: { type: 'object', properties: { parent: { type: 'string' }, title: { type: 'string' }, content: { type: 'string' } } },
    changesData: true,
    ...overrides,
  };
}

/** Goes through the production gate: the send path hands requests to the UI via `currentMcpConfirmationGate()`. */
function ask(overrides: Partial<McpConfirmationRequest> = {}, signal: AbortSignal = new AbortController().signal): Promise<McpConfirmationChoice> {
  let choice!: Promise<McpConfirmationChoice>;
  act(() => {
    choice = currentMcpConfirmationGate().requestConfirmation(request(overrides), signal);
  });
  return choice;
}

const dialog = () => screen.getByRole('dialog');

beforeEach(() => {
  telemetry.trackEvent.mockReset();
  resetMcpStore();
  seedMcpStore({ servers: [server(NOTION, 'Notion')] });
});

describe('wiring between the confirmation gate and the UI', () => {
  it('denies everything while the global host is not mounted, hands requests to the UI once mounted, and ends pending requests as denied on unmount', async () => {
    await expect(currentMcpConfirmationGate().requestConfirmation(request(), new AbortController().signal)).resolves.toBe('deny');

    const view = renderWithIntl(<McpGlobalPrompts />);
    const pending = ask();
    expect(useMcpConfirmationStore.getState().pending).toHaveLength(1);
    view.unmount();
    await expect(pending).resolves.toBe('deny');
    await expect(currentMcpConfirmationGate().requestConfirmation(request(), new AbortController().signal)).resolves.toBe('deny');
  });
});

describe('confirmation before a write', () => {
  it('shows title, subtitle, server and host name and the first few arguments (keys verbatim), and for long text its length plus a view-full-text entry', () => {
    renderWithIntl(<McpGlobalPrompts />);
    void ask();
    expect(within(dialog()).getByRole('heading', { name: 'Allow Notion to Create page?' })).not.toBeNull();
    expect(within(dialog()).getByText("This step changes your data in Notion. Here's what the model is about to send.")).not.toBeNull();
    const terms = Array.from(dialog().querySelectorAll('dt')).map((node) => node.textContent);
    const values = Array.from(dialog().querySelectorAll('dd')).map((node) => node.textContent);
    expect(terms).toEqual(['Server', 'parent', 'title', 'content']);
    expect(values).toEqual(['Notion · mcp.notion.com', 'Weekly reports', 'Week 40 · open bugs (12)', `About ${LONG_TEXT.length} characters · View all`]);
    // The long text itself is not laid out in full in the dialog
    expect(dialog().textContent).not.toContain(LONG_TEXT);
  });

  it('does not say the tool will modify your content for a read-only tool whose permission is set to ask every time', () => {
    renderWithIntl(<McpGlobalPrompts />);
    void ask({ changesData: false });
    expect(within(dialog()).getByText("This step uses Notion. Here's what the model is about to send.")).not.toBeNull();
    expect(dialog().textContent).not.toContain('changes your data');
  });

  it('lists only the first 4 arguments when there are more and offers an entry to the rest', () => {
    renderWithIntl(<McpGlobalPrompts />);
    void ask({ arguments: { a: '1', b: '2', c: '3', d: '4', e: '5', f: '6' }, inputSchema: {} });
    expect(Array.from(dialog().querySelectorAll('dt')).map((node) => node.textContent).filter(Boolean)).toEqual(['Server', 'a', 'b', 'c', 'd']);
    expect(within(dialog()).getByRole('button', { name: '2 more fields' })).not.toBeNull();
  });

  it.each([
    ['Allow once', 'once'],
    ['Always allow in this chat', 'conversation'],
    ['Decline', 'deny'],
  ] as const)('three buttons: "%s" resolves to %s and records one mcp_confirm_choice', async (label, expected) => {
    renderWithIntl(<McpGlobalPrompts />);
    const pending = ask();
    await act(async () => {
      fireEvent.click(within(dialog()).getByRole('button', { name: label }));
    });
    await expect(pending).resolves.toBe(expected);
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(telemetry.trackEvent.mock.calls).toEqual([['mcp_confirm_choice', { choice: expected }]]);
  });

  it('shows several tools needing confirmation in one leg one at a time, in proposal order', async () => {
    renderWithIntl(<McpGlobalPrompts />);
    const first = ask({ toolTitle: 'Create page' });
    const second = ask({ toolTitle: 'Update page', toolName: 'update_page' });
    expect(within(dialog()).getByRole('heading').textContent).toBe('Allow Notion to Create page?');
    await act(async () => {
      fireEvent.click(within(dialog()).getByRole('button', { name: 'Decline' }));
    });
    await expect(first).resolves.toBe('deny');
    // Denying one of them does not stop the others from being asked
    expect(within(dialog()).getByRole('heading').textContent).toBe('Allow Notion to Update page?');
    await act(async () => {
      fireEvent.click(within(dialog()).getByRole('button', { name: 'Allow once' }));
    });
    await expect(second).resolves.toBe('once');
  });

  it('still appears when the chat page of that conversation is not on screen, since unmounting the chat page (settings, another conversation) is not a denial', async () => {
    // The root layout holds only the global host; the screen shows the chat page of another conversation,
    // which is then unmounted too (the user went to settings).
    const view = renderWithIntl(
      <>
        <McpGlobalPrompts />
        <McpChatPresence conversationId="another-conversation" />
      </>,
    );
    const pending = ask();
    expect(within(dialog()).getByRole('heading', { name: 'Allow Notion to Create page?' })).not.toBeNull();
    view.rerender(
      <IntlProvider locale="en" messages={enMessages} timeZone="UTC">
        <McpGlobalPrompts />
      </IntlProvider>,
    );
    // The request is still waiting; it was not denied on the user's behalf.
    expect(useMcpConfirmationStore.getState().pending).toHaveLength(1);
    await act(async () => {
      fireEvent.click(within(dialog()).getByRole('button', { name: 'Allow once' }));
    });
    await expect(pending).resolves.toBe('once');
  });

  it('puts default focus on Deny so that Enter pressed as the dialog appears does not approve, on the second layer too', async () => {
    renderWithIntl(<McpGlobalPrompts />);
    const pending = ask();
    await waitFor(() => expect(document.activeElement?.getAttribute('data-mcp-confirm')).toBe('deny'));
    expect(document.activeElement?.textContent).toBe('Decline');
    fireEvent.click(within(dialog()).getByRole('button', { name: 'View all' }));
    expect(dialog().querySelector('[data-mcp-confirm-view="full"]')).not.toBeNull();
    // Enter activates the focused button (the browser turns it into a click).
    (dialog().querySelector<HTMLElement>("[data-mcp-confirm='deny']"))!.focus();
    await act(async () => {
      (document.activeElement as HTMLElement).click();
    });
    await expect(pending).resolves.toBe('deny');
  });

  it('dismisses the dialog when the user presses stop, ends the wait as denied and records no choice event (it was not a choice made in the dialog)', async () => {
    renderWithIntl(<McpGlobalPrompts />);
    const controller = new AbortController();
    const pending = ask({}, controller.signal);
    expect(screen.queryByRole('dialog')).not.toBeNull();
    act(() => controller.abort());
    await expect(pending).resolves.toBe('deny');
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(telemetry.trackEvent).not.toHaveBeenCalled();
  });
});

describe('viewing the full text to be submitted', () => {
  it('is a second layer of the same dialog that lists every argument verbatim, keeps only Allow once and Deny, and can go back', async () => {
    renderWithIntl(<McpGlobalPrompts />);
    const pending = ask();
    fireEvent.click(within(dialog()).getByRole('button', { name: 'View all' }));
    expect(within(dialog()).getByRole('heading', { name: 'What will be sent' })).not.toBeNull();
    expect(within(dialog()).getByText('The model wrote this. It will be sent to Notion exactly as shown.')).not.toBeNull();
    expect(Array.from(dialog().querySelectorAll('pre')).map((node) => node.textContent)).toEqual(['Weekly reports', 'Week 40 · open bugs (12)', LONG_TEXT]);
    expect(within(dialog()).queryByRole('button', { name: 'Always allow in this chat' })).toBeNull();
    expect(within(dialog()).getByRole('button', { name: 'Allow once' })).not.toBeNull();
    expect(within(dialog()).getByRole('button', { name: 'Decline' })).not.toBeNull();

    fireEvent.click(within(dialog()).getByRole('button', { name: 'Back' }));
    expect(within(dialog()).getByRole('heading', { name: 'Allow Notion to Create page?' })).not.toBeNull();

    fireEvent.click(within(dialog()).getByRole('button', { name: 'View all' }));
    await act(async () => {
      fireEvent.click(within(dialog()).getByRole('button', { name: 'Allow once' }));
    });
    await expect(pending).resolves.toBe('once');
  });
});

describe('the authorization-expired pause notice follows the user', () => {
  /** Goes through the production gate: the loop tells the UI that a step is waiting for reauthorization via `currentMcpReauthorizationGate()`. */
  function pause(signal: AbortSignal = new AbortController().signal): Promise<McpReauthorizationChoice> {
    let choice!: Promise<McpReauthorizationChoice>;
    act(() => {
      choice = currentMcpReauthorizationGate()!.requestReauthorization({ conversationId: CONVERSATION, serverId: NOTION, serverName: 'Notion', stepId: 'step-1' }, signal);
    });
    return choice;
  }

  it('has no pause gate while the host is not mounted (the loop degrades to needs_auth)', () => {
    expect(currentMcpReauthorizationGate()).toBeNull();
  });

  it('shows the notice globally when that conversation is not on screen, and Skip this step resolves to skip', async () => {
    renderWithIntl(<McpGlobalPrompts />);
    const pending = pause();
    expect(within(dialog()).getByRole('heading', { name: "Notion's sign-in expired" })).not.toBeNull();
    expect(within(dialog()).getByRole('button', { name: 'Sign in again' })).not.toBeNull();
    await act(async () => {
      fireEvent.click(within(dialog()).getByRole('button', { name: 'Skip this step' }));
    });
    await expect(pending).resolves.toBe('skip');
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('does not show a separate notice while the chat page of that conversation is on screen (the step block has its own buttons), only after leaving it', () => {
    const view = renderWithIntl(
      <>
        <McpGlobalPrompts />
        <McpChatPresence conversationId={CONVERSATION} />
      </>,
    );
    void pause();
    expect(screen.queryByRole('dialog')).toBeNull();
    view.rerender(
      <IntlProvider locale="en" messages={enMessages} timeZone="UTC">
        <McpGlobalPrompts />
      </IntlProvider>,
    );
    expect(within(dialog()).getByRole('heading', { name: "Notion's sign-in expired" })).not.toBeNull();
    expect(useMcpReauthorizationStore.getState().pending).toHaveLength(1);
  });

  it('does not decide for the user when the notice is closed: the step keeps waiting', async () => {
    renderWithIntl(<McpGlobalPrompts />);
    let settled = false;
    void pause().then(() => {
      settled = true;
    });
    fireEvent.keyDown(document, { key: 'Escape' });
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(settled).toBe(false);
    expect(useMcpReauthorizationStore.getState().pending).toHaveLength(1);
  });
});
