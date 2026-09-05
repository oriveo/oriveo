import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

function readAppFile(relativePath: string): string {
  return readFileSync(join(process.cwd(), relativePath), 'utf8');
}

function cssClassBlock(source: string, selector: string): string {
  const marker = `${selector} {`;
  const start = source.indexOf(marker);
  expect(start).toBeGreaterThanOrEqual(0);
  const bodyStart = start + marker.length;
  const end = source.indexOf('\n}', bodyStart);
  expect(end).toBeGreaterThan(bodyStart);
  return source.slice(bodyStart, end);
}

describe('provider logo visual contract', () => {
  it('keeps known provider and vendor artwork free of trays and clipping', () => {
    const providerSource = readAppFile('components/ProviderIcon.tsx');
    const vendorCSS = readAppFile('components/VendorIdentity.module.css');
    const knownVendor = cssClassBlock(vendorCSS, ".vendorIdentity[data-has-logo='true']");

    expect(providerSource).not.toContain('roundedStyle');
    expect(knownVendor).toContain('background: transparent;');
    expect(knownVendor).toContain('border-radius: 0;');
    expect(knownVendor).not.toContain('border:');
  });

  it('keeps Relay brand marks and provider cards free of decorative frames', () => {
    const pickerCSS = readAppFile('components/providers/RelayKindPicker.module.css');
    const relayHeroCSS = readAppFile('app/providers/[providerId]/components/RelayEditorHeroCard.module.css');
    const providerCardSource = readAppFile('app/providers/new/ProviderCard.tsx');
    const providerCardCSS = readAppFile('app/providers/new/ProviderCard.module.css');
    const logoBrand = cssClassBlock(pickerCSS, '.logoBrand');
    const relayBadge = cssClassBlock(relayHeroCSS, '.badge');
    const selectedCard = cssClassBlock(providerCardCSS, ".showcaseCard[data-selected='true']");

    expect(logoBrand).not.toMatch(/background|border|box-shadow/);
    expect(relayBadge).not.toMatch(/background|border|box-shadow/);
    expect(providerCardSource).not.toContain('cardLogoGlow');
    expect(providerCardCSS).not.toContain('.cardLogoGlow');
    expect(selectedCard).not.toContain('inset');
  });

  it('keeps shared provider-logo wrappers transparent and unclipped', () => {
    const topBarCSS = readAppFile('components/chat/TopBar.module.css');
    const switcherCSS = readAppFile('components/chat/ModelSwitcher.module.css');
    const conversationCSS = readAppFile('components/sidebar/ConversationItem.module.css');
    const topBarBadge = cssClassBlock(topBarCSS, '.modelTriggerBadge');
    const switcherMark = cssClassBlock(switcherCSS, '.providerMark');
    const conversationAvatar = cssClassBlock(conversationCSS, '.avatar');

    expect(topBarBadge).not.toMatch(/background|border|box-shadow|overflow/);
    expect(switcherMark).not.toMatch(/background|border|box-shadow|overflow/);
    expect(conversationAvatar).toContain('overflow: visible;');
    expect(conversationAvatar).not.toMatch(/border|box-shadow/);
  });
});
