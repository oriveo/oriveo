import { describe, expect, it } from 'vitest';
import { isBackgroundedIdleTransaction, shouldCreateSpanForBrowserRequest } from '../idle-span-hygiene';

describe('shouldCreateSpanForBrowserRequest', () => {
  it('creates no span for long-lived or streaming requests that keep idle transactions open', () => {
    for (const url of [
      'https://firestore.googleapis.com/google.firestore.v1.Firestore/Listen/channel?gsessionid=x&VER=8',
      'https://firestore.googleapis.com/google.firestore.v1.Firestore/Write/channel?VER=8',
      '/api/chat/stream',
      'https://app.oriveoai.com/api/chat/stream?x=1',
      '/api/relay/forward',
      '/cdn-cgi/rum',
      'https://oriveoai.com/cdn-cgi/rum?',
    ]) {
      expect(shouldCreateSpanForBrowserRequest(url), url).toBe(false);
    }
  });

  it('keeps spans for ordinary requests, which really block the first screen', () => {
    for (const url of [
      'https://api.oriveoai.com/api/metadata',
      'https://api.oriveoai.com/api/metadata?view=index',
      'https://securetoken.googleapis.com/v1/token',
      'https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents/users/u',
      '/api/mcp/forward',
      '/api/search/forward',
      '/api/chat/streams-history',
    ]) {
      expect(shouldCreateSpanForBrowserRequest(url), url).toBe(true);
    }
  });
});

describe('isBackgroundedIdleTransaction', () => {
  it('drops only pageload / navigation the SDK marked cancelled in a background tab', () => {
    expect(isBackgroundedIdleTransaction({ contexts: { trace: { op: 'pageload', status: 'cancelled' } } })).toBe(true);
    expect(isBackgroundedIdleTransaction({ contexts: { trace: { op: 'navigation', status: 'cancelled' } } })).toBe(true);
  });

  it('keeps foreground, timed-out and other transactions', () => {
    expect(isBackgroundedIdleTransaction({ contexts: { trace: { op: 'pageload', status: 'ok' } } })).toBe(false);
    expect(isBackgroundedIdleTransaction({ contexts: { trace: { op: 'navigation', status: 'deadline_exceeded' } } })).toBe(false);
    expect(isBackgroundedIdleTransaction({ contexts: { trace: { op: 'http.server', status: 'cancelled' } } })).toBe(false);
    expect(isBackgroundedIdleTransaction({})).toBe(false);
  });
});
