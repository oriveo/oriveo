import { ManualModelClient } from './ManualModelClient';

// Next 16: this dynamic route must not export generateStaticParams, not even one returning [].
// Exporting it makes Next treat the route as statically generated, and on-demand rendering then
// trips DYNAMIC_SERVER_USAGE when the root layout reads cookies(), so a direct SSR hit (a pasted
// URL or a hard refresh) returns 500.

export default function ManualModelPage() {
  return <ManualModelClient />;
}
