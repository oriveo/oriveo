import { act, fireEvent, screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { McpStepDetailDialog } from '../McpStepDetailDialog';
import { LINEAR, renderWithIntl, resetMcpStore, seedMcpStore, server, step } from './mcp-test-kit';

const mocks = vi.hoisted(() => ({ fetchMcpStepPayload: vi.fn() }));
vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('../../../lib/core/mcp/mcp-idb', () => ({ fetchMcpStepPayload: mocks.fetchMcpStepPayload }));

async function renderDetail(props: Partial<Parameters<typeof McpStepDetailDialog>[0]> = {}) {
  await act(async () => {
    renderWithIntl(<McpStepDetailDialog step={step({ id: '1:a' })} status="done" messageId="m1" onClose={vi.fn()} {...props} />);
  });
  return screen.getByRole('dialog');
}

beforeEach(() => {
  mocks.fetchMcpStepPayload.mockReset();
  resetMcpStore();
  seedMcpStore({ servers: [server(LINEAR, 'Linear')] });
});

describe('step details dialog', () => {
  it('shows arguments and result as monospace text, a subtitle of server, duration and status, and reads the payload by partition, message and step', async () => {
    mocks.fetchMcpStepPayload.mockResolvedValue({ messageId: 'm1', stepId: '1:a', arguments: '{"label":"bug","state":"open"}', resultPrefix: 'ORV-2291  Stream stops after lock\n  iOS · High', createdAt: 1 });
    const dialog = await renderDetail();
    expect(mocks.fetchMcpStepPayload).toHaveBeenCalledWith('user-1', 'm1', '1:a');
    expect(within(dialog).getByRole('heading', { name: 'Search issues' })).not.toBeNull();
    expect(within(dialog).getByText('Linear · took 1.2 s · Done')).not.toBeNull();
    expect(Array.from(dialog.querySelectorAll('pre')).map((node) => node.textContent)).toEqual([
      '{\n  "label": "bug",\n  "state": "open"\n}',
      'ORV-2291  Stream stops after lock\n  iOS · High',
    ]);
    expect(within(dialog).getByText("Results come from a third-party server. Only the first 2 KB is shown. Oriveo hasn't checked the content.")).not.toBeNull();
  });

  it('copies exactly the part of the result that is shown', async () => {
    const writeText = vi.fn(async () => {});
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } });
    mocks.fetchMcpStepPayload.mockResolvedValue({ messageId: 'm1', stepId: '1:a', arguments: '{}', resultPrefix: 'first 2 KB only', createdAt: 1 });
    const dialog = await renderDetail();
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'Copy' }));
    });
    expect(writeText).toHaveBeenCalledWith('first 2 KB only');
    expect(within(dialog).getByRole('button', { name: 'Copied' })).not.toBeNull();
  });

  it('replaces both code blocks with a note when the step payload is missing (the message was restored from a backup, for example)', async () => {
    mocks.fetchMcpStepPayload.mockResolvedValue(null);
    const dialog = await renderDetail();
    expect(dialog.querySelector('[data-mcp-state="payload-missing"]')?.textContent).toBe('Details are only kept on the device that ran this step.');
    expect(dialog.querySelectorAll('pre')).toHaveLength(0);
    expect(within(dialog).queryByRole('button', { name: 'Copy' })).toBeNull();
  });

  it('treats a payload read error as missing on this device instead of leaving an empty dialog', async () => {
    mocks.fetchMcpStepPayload.mockRejectedValue(new Error('idb'));
    const dialog = await renderDetail();
    expect(dialog.querySelector('[data-mcp-state="payload-missing"]')).not.toBeNull();
  });

  it('shows the server error text as the result of a failed step (only here) and omits the duration when there is none', async () => {
    mocks.fetchMcpStepPayload.mockResolvedValue({ messageId: 'm1', stepId: '2:b', arguments: '{"id":"x"}', resultPrefix: 'Page not found', createdAt: 1 });
    const dialog = await renderDetail({ step: step({ id: '2:b', status: 'failed', errorCode: 'tool_error', durationMs: undefined }), status: 'failed' });
    expect(within(dialog).getByText('Linear · Failed')).not.toBeNull();
    expect(dialog.querySelectorAll('pre')[1].textContent).toBe('Page not found');
  });

  it('shows durations under one second in milliseconds', async () => {
    mocks.fetchMcpStepPayload.mockResolvedValue(null);
    const dialog = await renderDetail({ step: step({ id: '1:a', durationMs: 340 }) });
    expect(within(dialog).getByText('Linear · took 340 ms · Done')).not.toBeNull();
  });
});
