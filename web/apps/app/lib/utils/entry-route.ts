interface ResolveEntryRouteInput {
  hasCompletedOnboarding: boolean;
  providerCount: number;
  returnTo?: string | null;
}

/**
 * Reject open redirects. Only same-origin relative paths starting with `/`
 * (and not `//` or `/\`) are allowed; everything else falls back to `/chat`.
 */
export function sanitizeReturnTo(raw: string | null | undefined): string {
  const trimmed = raw?.trim();
  if (!trimmed) return '/chat';
  if (!trimmed.startsWith('/') || trimmed.startsWith('//') || trimmed.startsWith('/\\')) {
    return '/chat';
  }
  return trimmed;
}

/**
 * First-run with no providers goes to Welcome (add API key).
 * Returning users with onboarding complete or existing providers go to chat.
 */
export function resolveEntryRoute({
  hasCompletedOnboarding,
  providerCount,
  returnTo,
}: ResolveEntryRouteInput): string {
  const normalizedReturnTo = returnTo?.trim();
  if (normalizedReturnTo) return sanitizeReturnTo(normalizedReturnTo);

  if (!hasCompletedOnboarding && providerCount === 0) {
    return '/welcome';
  }

  return '/chat';
}
