import React from 'react';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import {
  ProviderCategoryChips,
  CustomRelayEntry,
  LocalComputeEntry,
  ProviderShowcaseCard,
  ProviderShowcaseSection,
} from './ProviderCard';

// t(key) returns the key as is; arguments are appended so interpolation can be asserted
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, vars?: Record<string, unknown>) =>
    vars ? `${key}:${Object.values(vars).join(',')}` : key,
}));

vi.mock('../../../components/ProviderIcon', () => ({
  ProviderIcon: ({ kind }: { kind: string }) => <span data-testid={`icon-${kind}`} />,
}));

vi.mock('../../../lib/hooks/useIsDarkTheme', () => ({
  useIsDarkTheme: () => false,
}));

describe('ProviderCategoryChips', () => {
  it('renders all four categories and marks the selected one active', () => {
    render(<ProviderCategoryChips selected="all" onSelect={() => {}} />);

    const all = screen.getByText('categoryAll').closest('button')!;
    const direct = screen.getByText('categoryDirect').closest('button')!;
    expect(all.getAttribute('data-active')).toBe('true');
    expect(direct.getAttribute('data-active')).toBe('false');
    expect(screen.getByText('categoryAggregators')).toBeTruthy();
    expect(screen.getByText('categoryCustom')).toBeTruthy();
  });

  it('calls onSelect with the tapped category', () => {
    const onSelect = vi.fn();
    render(<ProviderCategoryChips selected="all" onSelect={onSelect} />);

    fireEvent.click(screen.getByText('categoryCustom'));
    expect(onSelect).toHaveBeenCalledWith('custom');
  });
});

describe('ProviderShowcaseCard', () => {
  it('renders the display name + localized tagline and reflects selection', () => {
    render(
      <ProviderShowcaseCard
        kind="openAI"
        displayName="OpenAI"
        selected
        isDark={false}
        onSelect={() => {}}
      />,
    );

    expect(screen.getByText('OpenAI')).toBeTruthy();
    // The tagline goes through t('taglines.openai')
    expect(screen.getByText('taglines.openai')).toBeTruthy();
    const card = screen.getByText('OpenAI').closest('button')!;
    expect(card.getAttribute('data-selected')).toBe('true');
  });

  it('invokes onSelect when clicked', () => {
    const onSelect = vi.fn();
    render(
      <ProviderShowcaseCard
        kind="anthropic"
        displayName="Anthropic"
        selected={false}
        isDark={false}
        onSelect={onSelect}
      />,
    );

    fireEvent.click(screen.getByText('Anthropic'));
    expect(onSelect).toHaveBeenCalledTimes(1);
  });
});

describe('ProviderShowcaseSection', () => {
  const PROVIDERS = [
    { kind: 'openAI', displayName: 'OpenAI' },
    { kind: 'anthropic', displayName: 'Anthropic' },
  ];

  it('renders the eyebrow label and one card per provider, marking the selected card', () => {
    render(
      <ProviderShowcaseSection
        label="Direct AI Providers"
        providers={PROVIDERS}
        selectedKind="anthropic"
        onSelect={() => {}}
      />,
    );

    expect(screen.getByText('Direct AI Providers')).toBeTruthy();
    expect(screen.getByText('OpenAI').closest('button')!.getAttribute('data-selected')).toBe('false');
    expect(screen.getByText('Anthropic').closest('button')!.getAttribute('data-selected')).toBe('true');
  });

  it('renders nothing when there are no providers', () => {
    const { container } = render(
      <ProviderShowcaseSection label="Direct" providers={[]} selectedKind={null} onSelect={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });
});

describe('custom provider entries', () => {
  it('renders local compute and custom relay as separate actions', () => {
    const onTap = vi.fn();
    render(
      <>
        <LocalComputeEntry onTap={onTap} />
        <CustomRelayEntry onTap={onTap} />
      </>,
    );

    expect(screen.getByText('localCompute')).toBeTruthy();
    expect(screen.getByText('localComputeSubtitle')).toBeTruthy();
    expect(screen.getByText('customEndpoint')).toBeTruthy();
    expect(screen.getByText('relaySubtitle')).toBeTruthy();
    expect(screen.getByText('localCompute').closest('button')!.className).toBe(
      screen.getByText('customEndpoint').closest('button')!.className,
    );
    fireEvent.click(screen.getByText('localCompute'));
    fireEvent.click(screen.getByText('customEndpoint'));
    expect(onTap).toHaveBeenCalledTimes(2);
  });

  it('pins the shared custom entry geometry to the cross-platform 70px contract', () => {
    const css = readFileSync(resolve(process.cwd(), 'app/providers/new/ProviderCard.module.css'), 'utf8');
    const sharedEntryRule = css.match(/\.customEntry\s*\{([^}]*)\}/s)?.[1] ?? '';

    expect(sharedEntryRule).toContain('min-height: 70px');
    expect(sharedEntryRule).toContain('padding: 14px');
    expect(sharedEntryRule).toContain('gap: 12px');
    expect(css.match(/\.customEntryIconLocal\s*\{([^}]*)\}/s)?.[1]).not.toContain('background');
    expect(css.match(/\.customEntryIconEndpoint\s*\{([^}]*)\}/s)?.[1]).not.toContain('background');
  });
});
