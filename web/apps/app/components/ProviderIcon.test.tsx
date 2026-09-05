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

  it('renders relay providers with the closest brand logo from name and model hints', () => {
    render(
      <ProviderIcon
        kind="relay"
        size={40}
        bare
        providerName="Kimi-cn"
        modelHints={['kimi-k2-0905-preview']}
      />,
    );

    const image = screen.getByTestId('provider-icon-image');
    expect(image.getAttribute('src')).toBe('/plogos/light/kimi.png');
    expect(image.getAttribute('width')).toBe('40');
    expect(image.getAttribute('height')).toBe('40');
  });

  it('uses relayKind when relay brand hints do not identify a provider', () => {
    render(<ProviderIcon kind="relay" size={36} bare relayKind="anthropic_compatible" providerName="Work Relay" />);

    const image = screen.getByTestId('provider-icon-image');
    expect(image.getAttribute('src')).toBe('/plogos/light/anthropic.png');
  });

  it('uses the official dark artwork when a dark provider surface requests it', () => {
    render(<ProviderIcon kind="openAI" size={36} bare forceDark />);

    expect(screen.getByTestId('provider-icon-image').getAttribute('src')).toBe('/plogos/dark/openai.png');
  });
});
