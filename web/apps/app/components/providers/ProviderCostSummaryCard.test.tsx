import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { MonthlyCostSummary } from '../../lib/core/cost/cost-summary';
import { ProviderCostSummaryCard } from './ProviderCostSummaryCard';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) => {
    switch (key) {
      case 'byProvider':
        return 'By Provider';
      case 'title':
        return 'This month\'s estimated usage';
      case 'localSubtitle':
        return 'Based on usage on this device';
      case 'moreProviders':
        return `+${values?.count ?? 0} more`;
      default:
        return key;
    }
  },
}));

const multiProviderSummary: MonthlyCostSummary = {
  // totalCost includes the cost of hidden entries - visible 4.4 < total 5.0, so the rest track is shown.
  totalCost: 5.0,
  providers: [
    { providerKind: 'openAI', providerID: 'openai-1', displayName: 'OpenAI', cost: 3.5 },
    {
      providerKind: 'anthropic',
      providerID: 'anthropic-1',
      displayName: 'Anthropic',
      baseURLText: 'https://api.anthropic.com',
      modelHints: ['claude-sonnet-4.5'],
      cost: 0.9,
    },
  ],
  hiddenProviderCount: 1,
  isVisible: true,
  source: 'local_device',
};

const singleProviderSummary: MonthlyCostSummary = {
  totalCost: 1.0,
  providers: [
    { providerKind: 'openAI', providerID: 'openai-1', displayName: 'OpenAI', cost: 1.0 },
  ],
  hiddenProviderCount: 0,
  isVisible: true,
  source: 'local_device',
};

describe('ProviderCostSummaryCard', () => {
  it('renders the iOS-aligned cost card with By Provider eyebrow, segmented bar, and Capsule chip legend', () => {
    const onOpenDetails = vi.fn();

    render(
      <ProviderCostSummaryCard
        summary={multiProviderSummary}
        onOpenDetails={onOpenDetails}
      />,
    );

    // Eyebrow copy (the English mock returns "By Provider").
    expect(screen.getByText('By Provider')).toBeTruthy();
    expect(screen.getByText('Based on usage on this device')).toBeTruthy();
    // The hero "$" is rendered separately from the number itself, "5.00".
    expect(screen.getByText('$')).toBeTruthy();
    expect(screen.getByText('5.00')).toBeTruthy();
    // Legend rows - share% is cost/total: 3.5/5 = 70%, 0.9/5 = 18%.
    expect(screen.getByText('OpenAI')).toBeTruthy();
    expect(screen.getByText('$3.50')).toBeTruthy();
    expect(screen.getByText('Anthropic')).toBeTruthy();
    expect(screen.getByText('$0.90')).toBeTruthy();
    expect(screen.getByText('+1 more')).toBeTruthy();
    expect(screen.getByText('70%')).toBeTruthy();
    expect(screen.getByText('18%')).toBeTruthy();
    expect(screen.getByTestId('provider-breakdown-row-openAI|openai-1')).toBeTruthy();
    expect(screen.getByTestId('provider-breakdown-row-anthropic|anthropic-1')).toBeTruthy();
    // Segmented bar segments (providers + hidden >= 2 shows the bar; each segment testid uses a composite key).
    expect(screen.getByTestId('segment-openAI|openai-1')).toBeTruthy();
    expect(screen.getByTestId('segment-anthropic|anthropic-1')).toBeTruthy();
    // Hidden providers exist, so segment-rest (the remaining track) is rendered.
    expect(screen.getByTestId('segment-rest')).toBeTruthy();

    fireEvent.click(screen.getByRole('button'));
    expect(onOpenDetails).toHaveBeenCalledTimes(1);
  });

  it('renders a static local-device card when no details action is provided', () => {
    render(
      <ProviderCostSummaryCard
        summary={{
          ...multiProviderSummary,
          hiddenProviderCount: 0,
          source: 'local_device',
        }}
      />,
    );

    expect(screen.getByText('Based on usage on this device')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
    // hiddenCount = 0 plus providers = 2, so the bar still renders - a comparison only means something with at least 2 providers.
    expect(screen.getByTestId('segment-openAI|openai-1')).toBeTruthy();
  });

  it('hides the segmented bar when there is only a single provider with no hidden', () => {
    render(<ProviderCostSummaryCard summary={singleProviderSummary} />);

    // A single provider with nothing hidden hides the bar; one 100% segment is pure decoration.
    expect(screen.queryByTestId('segment-openAI|openai-1')).toBeNull();
    // The legend row still renders, as an information layer.
    expect(screen.getByText('OpenAI')).toBeTruthy();
    expect(screen.getByText('$1.00')).toBeTruthy();
  });
});
