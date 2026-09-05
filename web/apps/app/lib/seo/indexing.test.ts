import { describe, expect, it } from 'vitest';
import { resolveRobotsHeader } from './indexing';

describe('app indexing policy', () => {
  it('keeps the welcome landing page indexable', () => {
    expect(resolveRobotsHeader('/welcome')).toBeNull();
  });

  it('marks private and thin app routes as noindex', () => {
    expect(resolveRobotsHeader('/')).toBe('noindex, nofollow');
    expect(resolveRobotsHeader('/chat/thread-1')).toBe('noindex, nofollow');
    expect(resolveRobotsHeader('/providers')).toBe('noindex, nofollow');
    expect(resolveRobotsHeader('/settings/memory')).toBe('noindex, nofollow');
  });

  it('skips api, framework assets, and machine-readable files', () => {
    expect(resolveRobotsHeader('/api/chat/stream')).toBeNull();
    expect(resolveRobotsHeader('/_next/static/chunk.js')).toBeNull();
    expect(resolveRobotsHeader('/manifest.json')).toBeNull();
    expect(resolveRobotsHeader('/robots.txt')).toBeNull();
    expect(resolveRobotsHeader('/sitemap.xml')).toBeNull();
    expect(resolveRobotsHeader('/icons/icon-192.png')).toBeNull();
  });
});
