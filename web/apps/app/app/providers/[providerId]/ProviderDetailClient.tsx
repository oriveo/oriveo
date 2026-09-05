'use client';

import { useParams } from 'next/navigation';
import { ProviderDetailRouter } from './ProviderDetailRouter';

export function ProviderDetailClient() {
  const { providerId } = useParams<{ providerId: string }>();
  return <ProviderDetailRouter providerId={providerId} />;
}
