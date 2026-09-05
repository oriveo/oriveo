'use client';

import { Settings } from './Settings';

export default function SettingsPage() {
  // The shell is kept mounted by PersistentShellLayout in the root layout, so the sidebar is not remounted on navigation
  return <Settings />;
}
