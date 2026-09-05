import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const { addBreadcrumb } = vi.hoisted(() => ({ addBreadcrumb: vi.fn() }));
vi.mock('@sentry/nextjs', () => ({ addBreadcrumb }));

import { reportSilentError, withErrorReporting } from '../report-silent';

describe('report-silent', () => {
  let warnSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    vi.clearAllMocks();
    warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => warnSpy.mockRestore());

  it('reportSilentError logs a console.warn and adds a Sentry breadcrumb carrying the context and error message', () => {
    reportSilentError('usage.enqueue', new Error('boom'));
    expect(warnSpy).toHaveBeenCalledWith('[usage.enqueue]', expect.any(Error));
    expect(addBreadcrumb).toHaveBeenCalledTimes(1);
    expect(addBreadcrumb.mock.calls[0][0]).toMatchObject({
      category: 'fire-and-forget',
      level: 'warning',
      message: 'usage.enqueue',
      data: { error: 'boom' },
    });
  });

  it('reports non-Error values too, falling back to String', () => {
    reportSilentError('attachments.cleanup', 'plain string');
    expect(addBreadcrumb.mock.calls[0][0].data.error).toBe('plain string');
  });

  it('withErrorReporting returns a handler that can be passed to .catch and never throws', async () => {
    const handler = withErrorReporting('sync.cost');
    expect(typeof handler).toBe('function');
    // As a .catch handler: swallow the rejection, report it, and do not rethrow
    await expect(Promise.reject(new Error('net')).catch(handler)).resolves.toBeUndefined();
    expect(warnSpy).toHaveBeenCalledWith('[sync.cost]', expect.any(Error));
    expect(addBreadcrumb.mock.calls[0][0].message).toBe('sync.cost');
  });
});
