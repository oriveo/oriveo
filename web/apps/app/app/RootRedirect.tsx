'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { Skeleton } from '../components/Skeleton';
import { useAppStore } from '../providers/StoreProvider';
import { resolveEntryRoute } from '../lib/utils/entry-route';

export function RootRedirect() {
  const router = useRouter();
  const hasCompletedOnboarding = useAppStore((s) => s.hasCompletedOnboarding);
  const providers = useAppStore((s) => s.providers);

  useEffect(() => {
    router.replace(resolveEntryRoute({
      hasCompletedOnboarding,
      providerCount: providers.length,
    }));
  }, [hasCompletedOnboarding, providers.length, router]);

  return <Skeleton />;
}
