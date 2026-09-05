import { Suspense } from 'react';
import { buildAppPageMetadata } from '../../lib/seo/public-metadata';
import { Welcome } from './Welcome';

export const metadata = buildAppPageMetadata({
  title: 'BYOK AI Client for OpenAI, Claude, Gemini, and OpenRouter',
  description:
    'Start using Oriveo on the web with your own AI keys. BYOK multi-model chat, local-first data, and real-time cost tracking in one app.',
  path: '/welcome',
});

export default function WelcomePage() {
  return (
    <Suspense>
      <Welcome />
    </Suspense>
  );
}
