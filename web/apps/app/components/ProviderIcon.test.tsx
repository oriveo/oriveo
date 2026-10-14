import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { ProviderIcon } from './ProviderIcon';

vi.mock('next/image', () => ({
  default: ({ src, alt, width, height, className, style }: {
    src: string;
    alt: string;
    width: number;
    height: number;
    className?: string;
    style?: Record<string, string | number>;
  }) => (
    <img
      src={src}
      alt={alt}
      width={width}
      height={height}
      className={className}
      style={style}
      data-testid="provider-icon-image"
    />
  ),
}));

describe('ProviderIcon', () => {
  it('renders DeepSeek with the vendor logo asset in bare mode', () => {
    render(<ProviderIcon kind="deepseek" size={32} bare />);

    const image = screen.getByTestId('provider-icon-image');
    expect(image.getAttribute('src')).toBe('/plogos/light/deepseek.png');
    expect(image.getAttribute('width')).toBe('32');
    expect(image.getAttribute('height')).toBe('32');
    expect(image.getAttribute('style')).toBeNull();
  });

  it('renders Kimi with the Moonshot vendor logo asset in bare mode', () => {
    render(<ProviderIcon kind="moonshot" size={32} bare />);

    const image = screen.getByTestId('provider-icon-image');
    expect(image.getAttribute('src')).toBe('/plogos/light/kimi.png');
    expect(image.getAttribute('width')).toBe('32');
    expect(image.getAttribute('height')).toBe('32');
  });

  // Relay connections resolve only the unified avatar from name / address (relay-avatar.v1.json), no longer inferring a brand
  // from model ids or relayKind; the old "Kimi-cn + kimi model -> Kimi logo" and "anthropic_compatible -> Anthropic logo"
  // inferences are kept only for local-engine connections.
  it('relay connections ignore model hints and relayKind: no brand -> initial without a plate', () => {
    const { container } = render(
      <ProviderIcon
        kind="relay"
        size={40}
        bare
        relayKind="anthropic_compatible"
        providerName="Kimi-cn"
        modelHints={['kimi-k2-0905-preview']}
      />,
    );

    expect(screen.queryByTestId('provider-icon-image')).toBeNull();
    const avatar = container.querySelector('[data-relay-avatar]')!;
    expect(avatar.getAttribute('data-relay-avatar')).toBe('initial:K');
    expect(avatar.textContent).toBe('K');
  });

  it('relay connections match aggregator brands by name or host and reuse the official artwork', () => {
    render(<ProviderIcon kind="relay" size={36} bare providerName="Work Relay" baseURLText="https://openrouter.ai/api/v1" />);

    expect(screen.getByTestId('provider-icon-image').getAttribute('src')).toBe('/plogos/light/openrouter.png');
  });

  it('does not borrow brand logos for a relay that mentions the app name', () => {
    const { container } = render(
      <ProviderIcon
        kind="relay"
        size={36}
        bare
        relayKind="anthropic_compatible"
        providerName="Oriveo OpenRouter Home Relay"
        baseURLText="https://oriveo-relay.example.com/v1"
      />,
    );

    expect(screen.queryByTestId('provider-icon-image')).toBeNull();
    expect(container.querySelector('[data-relay-avatar]')?.getAttribute('data-relay-avatar')).toBe('initial:O');
  });

  it('local engine connections keep the name / model hint and relayKind inference', () => {
    const { rerender } = render(
      <ProviderIcon kind="relay" size={40} bare localEngine providerName="Kimi-cn" modelHints={['kimi-k2-0905-preview']} />,
    );
    expect(screen.getByTestId('provider-icon-image').getAttribute('src')).toBe('/plogos/light/kimi.png');

    rerender(<ProviderIcon kind="relay" size={36} bare localEngine relayKind="anthropic_compatible" providerName="Mac mini" />);
    expect(screen.getByTestId('provider-icon-image').getAttribute('src')).toBe('/plogos/light/anthropic.png');
  });

  it('uses the official dark artwork when a dark provider surface requests it', () => {
    render(<ProviderIcon kind="openAI" size={36} bare forceDark />);

    expect(screen.getByTestId('provider-icon-image').getAttribute('src')).toBe('/plogos/dark/openai.png');
  });
});
