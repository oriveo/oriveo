import { ProviderDetailClient } from './ProviderDetailClient';

// Next 16: the web build must not export generateStaticParams, not even returning [], or the dynamic
// route is treated as statically generated and the root layout's cookies() call during on-demand
// rendering raises DYNAMIC_SERVER_USAGE and a 500.
// It is therefore exported conditionally: the desktop export builds a placeholder shell, while web
// gets undefined, which is equivalent to not exporting it and leaves a purely dynamic route.
export const generateStaticParams =
  process.env.ORIVEO_DESKTOP === '1'
    ? (): { providerId: string }[] => [{ providerId: 'shell' }]
    : undefined;

export default function ProviderDetailPage() {
  return <ProviderDetailClient />;
}
