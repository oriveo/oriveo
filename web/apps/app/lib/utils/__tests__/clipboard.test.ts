import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

vi.mock('../../../components/Toast', () => ({ showToast: vi.fn() }));
import { showToast } from '../../../components/Toast';
import { copyToClipboard } from '../clipboard';

const mockShowToast = vi.mocked(showToast);

// The jsdom runtime does not implement document.execCommand, so spyOn cannot hook it and the stub has to be injected by hand.
function stubExecCommand(result: boolean) {
  const fn = vi.fn(() => result);
  Object.defineProperty(document, 'execCommand', { value: fn, configurable: true, writable: true });
  return fn;
}

describe('copyToClipboard', () => {
  beforeEach(() => {
    mockShowToast.mockClear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    Reflect.deleteProperty(document, 'execCommand');
  });

  it('navigator.clipboard succeeds -> returns true and writes the text', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal('navigator', { clipboard: { writeText } });

    const ok = await copyToClipboard('hello');

    expect(ok).toBe(true);
    expect(writeText).toHaveBeenCalledWith('hello');
  });

  it('shows successToast on success', async () => {
    vi.stubGlobal('navigator', { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } });

    await copyToClipboard('x', { successToast: ' ' });

    expect(mockShowToast).toHaveBeenCalledWith(' ');
  });

  it('navigator.clipboard unavailable -> falls back to execCommand and returns true', async () => {
    vi.stubGlobal('navigator', {});
    const execCommand = stubExecCommand(true);

    const ok = await copyToClipboard('fallback');

    expect(ok).toBe(true);
    expect(execCommand).toHaveBeenCalledWith('copy');
  });

  it('navigator.clipboard.writeText rejects -> falls back to execCommand', async () => {
    vi.stubGlobal('navigator', {
      clipboard: { writeText: vi.fn().mockRejectedValue(new Error('denied')) },
    });
    const execCommand = stubExecCommand(true);

    const ok = await copyToClipboard('y');

    expect(ok).toBe(true);
    expect(execCommand).toHaveBeenCalled();
  });

  it('both paths fail -> returns false and shows failureToast', async () => {
    vi.stubGlobal('navigator', {});
    stubExecCommand(false);

    const ok = await copyToClipboard('z', { failureToast: ' ' });

    expect(ok).toBe(false);
    expect(mockShowToast).toHaveBeenCalledWith(' ');
  });

  it('failure with no failureToast passed -> shows no toast', async () => {
    vi.stubGlobal('navigator', {});
    stubExecCommand(false);

    const ok = await copyToClipboard('z');

    expect(ok).toBe(false);
    expect(mockShowToast).not.toHaveBeenCalled();
  });
});
