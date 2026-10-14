'use client';

import type { CSSProperties } from 'react';
import { PROVIDER_BRAND_COLORS } from '../../../../lib/constants/provider-brand-colors';
import styles from './RelaySetup.module.css';
import type { SetupProtocol } from './setup-board';

/** Protocol colors reuse existing brand colors: Chat=OpenAI, Responses=same color at 60%, Messages=Anthropic, Gemini=Gemini. */
function protocolColorStyle(protocol: SetupProtocol): CSSProperties {
  const brand = protocol === 'Messages'
    ? PROVIDER_BRAND_COLORS.anthropic!
    : protocol === 'Gemini'
      ? PROVIDER_BRAND_COLORS.gemini!
      : PROVIDER_BRAND_COLORS.openAI!;
  return {
    '--protocol-light': brand.light,
    '--protocol-dark': brand.dark,
    '--protocol-opacity': protocol === 'Responses' ? 0.6 : 1,
  } as CSSProperties;
}

export function ProtocolDot({ protocol }: { protocol: SetupProtocol }) {
  return <span className={styles.protocolDot} style={protocolColorStyle(protocol)} aria-hidden="true" />;
}

/** Address slot prefix chip: shows the scheme of the current address; when no scheme is written, uses the send-boundary default (https). */
export function endpointSchemeChip(raw: string): 'http' | 'https' {
  return /^\s*http:\/\//i.test(raw) ? 'http' : 'https';
}

const WRITTEN_SCHEME = /^\s*(https?):\/\//i;

/** The address slot placeholder carries no scheme (the chip already shows it). */
export const ENDPOINT_SLOT_PLACEHOLDER = 'api.example.com';
export const EDIT_ENDPOINT_SLOT_PLACEHOLDER = 'api.example.com/v1';

/** The slot shows only the part after the scheme (the scheme is shown by the chip). */
export function endpointSlotText(raw: string): string {
  return raw.replace(WRITTEN_SCHEME, '');
}

/** Write slot input back to the stored value: clearing empties the whole string; input containing "://" replaces the whole string; otherwise keeps the scheme already written (none is added if none was written). */
export function endpointFromSlotInput(previous: string, typed: string): string {
  if (typed === '' || typed.includes('://')) return typed;
  const scheme = WRITTEN_SCHEME.exec(previous)?.[1];
  return scheme ? `${scheme}://${typed}` : typed;
}
