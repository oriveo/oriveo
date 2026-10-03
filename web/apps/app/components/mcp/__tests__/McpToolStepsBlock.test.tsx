import { useState } from 'react';
import { act, fireEvent, screen, within } from '@testing-library/react';
import type { McpToolStep } from '@oriveo/shared';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  enableMcpConfirmationUi,
  storeMcpReauthorizationGate,
  useMcpReauthorizationStore,
} from '../../../lib/core/mcp/mcp-confirmation';
import { McpToolStepsBlock } from '../McpToolStepsBlock';
import { LINEAR, NOTION, renderWithIntl, resetMcpStore, seedMcpStore, server, step } from './mcp-test-kit';

vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('../../../lib/core/mcp/mcp-idb', () => ({ fetchMcpStepPayload: vi.fn(async () => null) }));

const CONVERSATION = 'conversation-1';

function renderBlock(props: Partial<Parameters<typeof McpToolStepsBlock>[0]> & Pick<Parameters<typeof McpToolStepsBlock>[0], 'steps'>) {
  return renderWithIntl(<McpToolStepsBlock isStreaming={false} messageId="m1" conversationId={CONVERSATION} {...props} />);
}

const header = () => screen.getByRole('button', { expanded: undefined, name: /Using tools|Used \d+ tools?|Waiting for sign-in/ });
const rows = () => screen.queryAllByRole('listitem').map((row) => row.textContent);

let disableUi: (() => void) | null = null;
beforeEach(() => {
  resetMcpStore();
  seedMcpStore({ servers: [server(LINEAR, 'Linear'), server(NOTION, 'Notion')] });
});
afterEach(() => {
  disableUi?.();
  disableUi = null;
});

describe('while running', () => {
  it('is expanded by default with the Using tools title and the step number on the right, and the running row cannot open details', () => {
    renderBlock({
      isStreaming: true,
      steps: [
        step({ id: '1:a', step: 1 }),
        step({ id: '2:b', step: 2, title: 'Read issue', argsSummary: '12 results' }),
        step({ id: '3:c', step: 3, serverId: NOTION, serverName: 'Notion', title: 'Find page', argsSummary: 'Weekly report', status: 'running', durationMs: undefined }),
      ],
    });
    expect(header().textContent).toBe('Using toolsStep 3');
    expect(header().getAttribute('aria-expanded')).toBe('true');
    expect(rows()).toEqual(['Linear · Search issuesopen · bug', 'Linear · Read issue12 results', 'Notion · Find pageWeekly report']);
    const items = screen.getAllByRole('listitem');
    expect(within(items[0]).getByRole('img', { name: 'Done' })).not.toBeNull();
    expect(within(items[2]).getByRole('img', { name: 'Running' })).not.toBeNull();
    expect(within(items[0]).queryByRole('button')).not.toBeNull();
    expect(within(items[2]).queryByRole('button')).toBeNull();
  });

  it('stays in progress between two steps (the model is deciding the next one) and keeps the latest step number', () => {
    renderBlock({ isStreaming: true, steps: [step({ id: '1:a', step: 1 }), step({ id: '2:b', step: 2 })] });
    expect(header().textContent).toBe('Using toolsStep 2');
  });
});

describe('after completion', () => {
  const done = [
    step({ id: '1:a', step: 1 }),
    step({ id: '2:b', step: 2, serverId: NOTION, serverName: 'Notion', title: 'Create page', argsSummary: 'Weekly report' }),
  ];

  /** Flips the same component instance from generating to completed, as happens when the message stream ends. */
  function StreamingHarness({ steps }: { steps: McpToolStep[] }) {
    const [isStreaming, setStreaming] = useState(true);
    return (
      <>
        <button type="button" onClick={() => setStreaming(false)}>finish</button>
        <McpToolStepsBlock isStreaming={isStreaming} messageId="m1" conversationId={CONVERSATION} steps={steps} />
      </>
    );
  }

  it('collapses to one line when the reply completes: N tools used plus the server names', () => {
    renderWithIntl(<StreamingHarness steps={done} />);
    expect(header().getAttribute('aria-expanded')).toBe('true');
    fireEvent.click(screen.getByRole('button', { name: 'finish' }));
    expect(header().textContent).toBe('Used 2 toolsLinear · Notion');
    expect(header().getAttribute('aria-expanded')).toBe('false');
    expect(rows()).toEqual([]);
  });

  it('expands when the collapsed row is clicked', () => {
    renderBlock({ steps: done });
    fireEvent.click(header());
    expect(rows()).toEqual(['Linear · Search issuesopen · bug', 'Notion · Create pageWeekly report']);
    expect(header().getAttribute('aria-expanded')).toBe('true');
  });

  it('no longer collapses on completion once the user has toggled it by hand', () => {
    renderWithIntl(<StreamingHarness steps={done} />);
    fireEvent.click(header());
    fireEvent.click(header());
    expect(header().getAttribute('aria-expanded')).toBe('true');
    fireEvent.click(screen.getByRole('button', { name: 'finish' }));
    expect(header().getAttribute('aria-expanded')).toBe('true');
    expect(rows()).toHaveLength(2);
  });

  it('makes every row clickable to open the step details', async () => {
    renderBlock({ steps: done });
    fireEvent.click(header());
    await act(async () => {
      fireEvent.click(within(screen.getAllByRole('listitem')[1]).getByRole('button'));
    });
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'Create page' })).not.toBeNull();
    expect(within(dialog).getByText('Notion · took 1.2 s · Done')).not.toBeNull();
  });
});

describe('abnormal states, including interrupted', () => {
  it('shows a denied step with the gray slashed circle and the denied-not-run text, and the header right side as 1 step denied', () => {
    renderBlock({ steps: [step({ id: '1:a' }), step({ id: '2:b', step: 2, status: 'denied', errorCode: 'user_denied', title: 'Create page' })] });
    expect(header().textContent).toBe('Used 1 tool1 declined');
    fireEvent.click(header());
    const denied = screen.getAllByRole('listitem')[1];
    expect(denied.getAttribute('data-status')).toBe('denied');
    expect(denied.textContent).toBe("Linear · Create pageYou declined, so it wasn't run");
    expect(within(denied).getByRole('img', { name: 'Declined' })).not.toBeNull();
  });

  it('shows a failed step in red with the explanation for its closed-set error code and no server text, and the header right side as 1 step failed', () => {
    renderBlock({
      steps: [
        step({ id: '1:a' }),
        step({ id: '2:b', step: 2, status: 'failed', errorCode: 'timeout' }),
        step({ id: '3:c', step: 3, status: 'failed', errorCode: 'tool_error' }),
        step({ id: '4:d', step: 4, status: 'failed', errorCode: 'unreachable' }),
      ],
    });
    expect(header().textContent).toBe('Used 1 tool3 failed');
    fireEvent.click(header());
    expect(rows().slice(1)).toEqual([
      "Linear · Search issuesThe server didn't respond in time",
      "Linear · Search issuesThe tool didn't finish",
      "Linear · Search issuesCouldn't reach the server",
    ]);
    expect(within(screen.getAllByRole('listitem')[1]).getByRole('img', { name: 'Failed' })).not.toBeNull();
  });

  it('draws a step that is still running as interrupted when the message is no longer generating', () => {
    renderBlock({ steps: [step({ id: '1:a', status: 'running', durationMs: undefined })] });
    fireEvent.click(header());
    const row = screen.getByRole('listitem');
    expect(row.getAttribute('data-status')).toBe('interrupted');
    expect(row.textContent).toBe('Linear · Search issuesInterrupted');
  });

  it('explains the step limit in a trailing row and folds earlier steps behind a show-earlier-steps entry', () => {
    const steps = Array.from({ length: 8 }, (_, index) => step({ id: `${index + 1}:x`, step: index + 1, title: 'Read issue', argsSummary: `ORV-${index}` }));
    renderBlock({ steps, limitReached: true });
    expect(header().textContent).toBe('Used 8 toolsLinear');
    fireEvent.click(header());
    expect(rows()).toEqual(['Linear · Read issueORV-6', 'Linear · Read issueORV-7']);
    expect(screen.getByText('Tool limit reached. The answer below uses the results so far.')).not.toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Show 6 earlier steps' }));
    expect(rows()).toHaveLength(8);
  });

  it('has no such row below the limit', () => {
    renderBlock({ steps: [step({ id: '1:a' })] });
    fireEvent.click(header());
    expect(screen.queryByText(/Tool limit reached/)).toBeNull();
  });
});

describe('authorization expiring mid-run: pause, resume, skip', () => {
  const paused = [
    step({ id: '1:a' }),
    step({ id: '2:b', step: 2, title: 'Read issue' }),
    step({ id: '3:c', step: 3, serverId: NOTION, serverName: 'Notion', title: 'Find page', status: 'needsAuth', errorCode: 'needs_auth' }),
  ];

  /** Goes through the production gate: this is how the executor tells the UI that a step is waiting for reauthorization. */
  function pause(stepId = '3:c', conversationId = CONVERSATION) {
    const controller = new AbortController();
    const choice = storeMcpReauthorizationGate.requestReauthorization({ conversationId, serverId: NOTION, serverName: 'Notion', stepId }, controller.signal);
    return { choice, controller };
  }

  it('shows the waiting-for-reauthorization title, two side-by-side buttons and one line of explanation while the loop is paused on the step', () => {
    disableUi = enableMcpConfirmationUi();
    let pending!: ReturnType<typeof pause>;
    act(() => { pending = pause(); });
    renderBlock({ isStreaming: true, steps: paused });
    expect(header().textContent).toBe('Waiting for sign-inStep 3');
    expect(screen.getAllByRole('listitem')[2].textContent).toBe("Notion · Find pageNotion's sign-in expired");
    expect(screen.getByRole('button', { name: 'Sign in again' })).not.toBeNull();
    expect(screen.getByRole('button', { name: 'Skip this step' })).not.toBeNull();
    expect(screen.getByText('After you sign in, it picks up from this step. Earlier results are kept.')).not.toBeNull();
    pending.controller.abort();
  });

  it('hands skip back to the executor on Skip this step and removes the buttons', async () => {
    disableUi = enableMcpConfirmationUi();
    let pending!: ReturnType<typeof pause>;
    act(() => { pending = pause(); });
    renderBlock({ isStreaming: true, steps: paused });
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Skip this step' }));
    });
    await expect(pending.choice).resolves.toBe('skip');
    expect(useMcpReauthorizationStore.getState().pending).toEqual([]);
    expect(screen.queryByRole('button', { name: 'Skip this step' })).toBeNull();
  });

  it('ends the wait as skipped when the user presses stop, leaving no request pending forever', async () => {
    disableUi = enableMcpConfirmationUi();
    const pending = pause();
    pending.controller.abort();
    await expect(pending.choice).resolves.toBe('skip');
    expect(useMcpReauthorizationStore.getState().pending).toEqual([]);
  });

  it('shows no buttons in this message for a step paused in another conversation', () => {
    disableUi = enableMcpConfirmationUi();
    let pending!: ReturnType<typeof pause>;
    act(() => { pending = pause('3:c', 'another-conversation'); });
    renderBlock({ isStreaming: true, steps: paused });
    expect(screen.queryByRole('button', { name: 'Skip this step' })).toBeNull();
    pending.controller.abort();
  });

  it('keeps only the explanation and no buttons after a skip (no longer waiting)', () => {
    renderBlock({ steps: [step({ id: '1:a', serverName: 'Notion', status: 'needsAuth', errorCode: 'auth_skipped' })] });
    expect(header().textContent).toBe('Used 0 tools1 failed');
    fireEvent.click(header());
    expect(screen.getByRole('listitem').textContent).toBe("Notion · Search issuesNotion's sign-in expired");
    expect(screen.queryByRole('button', { name: 'Sign in again' })).toBeNull();
  });
});
