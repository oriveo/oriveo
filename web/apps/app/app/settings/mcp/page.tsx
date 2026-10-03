import { Suspense } from 'react';
import { McpServersPage } from './McpServersPage';

export default function McpServersRoute() {
  // useSearchParams needs a Suspense boundary (for static export / prerendering).
  return (
    <Suspense fallback={null}>
      <McpServersPage />
    </Suspense>
  );
}
