/**
 * Identity of the person using the app.
 *
 * There is no sign-in, so every session is the same local user and these all answer "nobody".
 * The functions exist so that code which is account-aware, such as storage partitioning, has one
 * place to ask rather than assuming.
 */

export function hasAuthenticatedUser(): boolean {
  return false;
}

export function getCurrentUserUID(): string | null {
  return null;
}

export async function getCurrentUserIDToken(): Promise<string | null> {
  return null;
}

export function initAuthObserver(
  _callback: (user: null) => void | Promise<void>,
): () => void {
  return () => {};
}
