import { ManualModelClient } from './ManualModelClient';

// Next 16: the web build must not export generateStaticParams, even one returning [], or the
// dynamic route is treated as statically generated and the root layout's cookies() call during
// on-demand rendering triggers DYNAMIC_SERVER_USAGE and a 500. Hence the conditional export:
// the desktop export produces a placeholder shell, while web gets undefined, which is equivalent
// to not exporting it and leaves a purely dynamic route.
export const generateStaticParams =
  process.env.ORIVEO_DESKTOP === '1'
    ? (): { providerId: string }[] => [{ providerId: 'shell' }]
    : undefined;

export default function ManualModelPage() {
  return <ManualModelClient />;
}
