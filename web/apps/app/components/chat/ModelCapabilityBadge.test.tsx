/**
 * Presentation contract tests for capability badges.
 *
 * Covers where the badge visuals come from:
 *   - a known capability renders from the lookup table
 *   - an unknown capability falls back to a grey dot plus the literal name, capitalized
 *   - `badgeOrder` controls visibility: a capability absent from badgeOrder is not rendered
 *   - the `text` capability is never rendered as a badge
 */

import React from 'react';
import { render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  ModelCapabilityBadge,
  ModelCapabilityBadges,
  __resetUnknownReportedForTest,
} from './ModelCapabilityBadge';

// next-intl mock: return the key unchanged.
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

// Sentry mock: used to assert that an unknown capability is reported.
const { mockCaptureMessage } = vi.hoisted(() => ({ mockCaptureMessage: vi.fn() }));
vi.mock('@sentry/nextjs', () => ({
  captureMessage: (...args: unknown[]) => mockCaptureMessage(...args),
}));

// The module-level unknownReported Set is a per-process singleton and has to be cleared before
// each test, or a capability reported by an earlier test invalidates the console.warn expectation
// of the next one.
beforeEach(() => {
  __resetUnknownReportedForTest();
  mockCaptureMessage.mockReset();
});

describe('ModelCapabilityBadge (Presentation Contract)', () => {
  it('renders known capability with translated label', () => {
    render(<ModelCapabilityBadge capability="reasoning" />);
    expect(screen.getByText('reasoning')).toBeTruthy();
  });

  it('renders the UI-only toolCall projection as a known localized badge', () => {
    render(<ModelCapabilityBadge capability="toolCall" />);
    expect(screen.getByText('toolCall')).toBeTruthy();
    expect(mockCaptureMessage).not.toHaveBeenCalled();
  });

  it('does not render the "text" capability as a badge', () => {
    const { container } = render(<ModelCapabilityBadge capability="text" />);
    expect(container.firstChild).toBeNull();
  });

  it('renders unknown capability with uppercase first letter fallback', () => {
    render(<ModelCapabilityBadge capability="fooBarBaz" />);
    // Fallback capitalization of the literal name.
    expect(screen.getByText('FooBarBaz')).toBeTruthy();
  });

  it('marks unknown capability with data-cap="unknown" for styling', () => {
    const { container } = render(<ModelCapabilityBadge capability="anUnknownCap" />);
    const badge = container.querySelector('[data-cap="unknown"]');
    expect(badge).toBeTruthy();
  });

  describe('unknown capability dedup', () => {
    let warnSpy: ReturnType<typeof vi.spyOn>;

    beforeEach(() => {
      warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    });

    afterEach(() => {
      warnSpy.mockRestore();
    });

    it('warns only once for the same unknown capability across renders', () => {
      render(<ModelCapabilityBadge capability="dedupCap" />);
      render(<ModelCapabilityBadge capability="dedupCap" />);
      render(<ModelCapabilityBadge capability="dedupCap" />);

      expect(warnSpy).toHaveBeenCalledTimes(1);
      expect(warnSpy).toHaveBeenCalledWith(
        '[metadata] unknown capability',
        expect.objectContaining({ capability: 'dedupCap' }),
      );
    });

    it('warns again after __resetUnknownReportedForTest clears the dedup set', () => {
      render(<ModelCapabilityBadge capability="resetCap" />);
      expect(warnSpy).toHaveBeenCalledTimes(1);

      __resetUnknownReportedForTest();
      render(<ModelCapabilityBadge capability="resetCap" />);
      expect(warnSpy).toHaveBeenCalledTimes(2);
    });

    it('reports unknown capability to Sentry once (metadata.unknown_capability tag)', () => {
      render(<ModelCapabilityBadge capability="sentryCap" providerId="prov-1" />);
      render(<ModelCapabilityBadge capability="sentryCap" providerId="prov-1" />);

      expect(mockCaptureMessage).toHaveBeenCalledTimes(1);
      expect(mockCaptureMessage).toHaveBeenCalledWith(
        'metadata: unknown model capability',
        expect.objectContaining({
          level: 'warning',
          tags: { module: 'metadata.unknown_capability' },
          extra: { capability: 'sentryCap', providerId: 'prov-1' },
        }),
      );
    });
  });
});

describe('ModelCapabilityBadges (Presentation Contract)', () => {
  it('filters capabilities by badgeOrder when provided', () => {
    render(
      <ModelCapabilityBadges
        capabilities={['text', 'reasoning', 'image', 'web']}
        badgeOrder={['reasoning', 'image']}
      />,
    );

    expect(screen.getByText('reasoning')).toBeTruthy();
    expect(screen.getByText('image')).toBeTruthy();
    // web is not in badgeOrder, so it is not rendered.
    expect(screen.queryByText('web')).toBeNull();
  });

  it('appends the evidence-only tool badge even when Server badgeOrder predates it', () => {
    const { container } = render(
      <ModelCapabilityBadges
        capabilities={['text', 'web', 'toolCall', 'image']}
        badgeOrder={['image']}
      />,
    );

    const caps = Array.from(container.querySelectorAll('[data-cap]'))
      .map((element) => element.getAttribute('data-cap'));
    expect(caps).toEqual(['image', 'toolCall']);
    expect(screen.queryByText('web')).toBeNull();
  });

  it('orders rendered badges strictly by badgeOrder index (not by input order)', () => {
    // capabilities is in the reverse order of badgeOrder, verifying that rendering follows badgeOrder.
    const { container } = render(
      <ModelCapabilityBadges
        capabilities={['imageGeneration', 'web', 'reasoning', 'image']}
        badgeOrder={['reasoning', 'image', 'web', 'imageGeneration']}
      />,
    );

    const badges = Array.from(container.querySelectorAll('[data-cap]'));
    const caps = badges.map((el) => el.getAttribute('data-cap'));
    expect(caps).toEqual(['reasoning', 'image', 'web', 'imageGeneration']);
  });

  it('renders unknown capability listed in badgeOrder via fallback (not skipped)', () => {
    // mysteryCap is an unknown capability newly added by the backend; the client should use the
    // fallback rendering (grey dot). Only capabilities absent from badgeOrder disappear entirely.
    render(
      <ModelCapabilityBadges
        capabilities={['reasoning', 'mysteryCap', 'web']}
        badgeOrder={['reasoning', 'mysteryCap']}
      />,
    );

    expect(screen.getByText('reasoning')).toBeTruthy();
    expect(screen.getByText('MysteryCap')).toBeTruthy();
    // web is not in badgeOrder, so it is not shown.
    expect(screen.queryByText('web')).toBeNull();
  });

  it('shows all non-text capabilities when badgeOrder is not provided', () => {
    render(<ModelCapabilityBadges capabilities={['text', 'reasoning', 'image']} />);

    expect(screen.getByText('reasoning')).toBeTruthy();
    expect(screen.getByText('image')).toBeTruthy();
  });

  it('returns null when no capabilities are visible after filtering', () => {
    const { container } = render(
      <ModelCapabilityBadges capabilities={['text']} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it('unknown capabilities inside an arbitrary capabilities array still render with fallback', () => {
    render(<ModelCapabilityBadges capabilities={['reasoning', 'mystery']} />);
    expect(screen.getByText('reasoning')).toBeTruthy();
    expect(screen.getByText('Mystery')).toBeTruthy();
  });
});
