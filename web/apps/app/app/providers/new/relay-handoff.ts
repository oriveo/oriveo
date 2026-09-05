/**
 * Analytics handoff marker for ProviderSetup to relay/new, carried across routes in sessionStorage.
 *
 * Set when the parent page navigates to relay after "custom relay" is picked: the relay page now
 * owns the outcome of this setup, so the parent does not report abandoned on unmount and the
 * relay page does not emit a second started. Without it one relay setup records two started and
 * two abandoned events and skews the funnel.
 *
 * Opening `/providers/relay/new` directly finds no marker, so the relay page emits started itself
 * and the flow stays complete.
 */
const RELAY_HANDOFF_KEY = 'oriveo.provider_setup.relay_handoff';

export interface RelayHandoffContext {
  entryPoint: 'onboarding' | 'providers' | 'model_picker' | 'skill_edit' | 'direct_link';
  isFirstProvider?: boolean;
}

/** Called by the parent page before navigating to relay. */
export function markRelayHandoff(context: RelayHandoffContext): void {
  try {
    window.sessionStorage.setItem(RELAY_HANDOFF_KEY, JSON.stringify(context));
  } catch {
    // Private mode or storage disabled: fall back to each page reporting on its own, with no loss of function.
  }
}

/** Called when the relay page mounts; reads and clears the marker (single use). */
export function consumeRelayHandoff(): RelayHandoffContext | null {
  try {
    const raw = window.sessionStorage.getItem(RELAY_HANDOFF_KEY);
    if (!raw) return null;
    window.sessionStorage.removeItem(RELAY_HANDOFF_KEY);
    // Accept the older boolean marker left in the same browser session by a previous version.
    if (raw === '1') return { entryPoint: 'direct_link' };
    const parsed = JSON.parse(raw) as Partial<RelayHandoffContext>;
    if (typeof parsed.entryPoint !== 'string') return { entryPoint: 'direct_link' };
    return {
      entryPoint: parsed.entryPoint as RelayHandoffContext['entryPoint'],
      ...(typeof parsed.isFirstProvider === 'boolean'
        ? { isFirstProvider: parsed.isFirstProvider }
        : {}),
    };
  } catch {
    return null;
  }
}
