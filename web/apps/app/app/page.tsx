import { buildAppPageMetadata } from '../lib/seo/public-metadata';
import { RootRedirect } from './RootRedirect';

export const metadata = buildAppPageMetadata({
  title: 'Open App',
  description:
    'Open the Oriveo web app for BYOK multi-model AI chat, sync, and cost tracking.',
  path: '/',
  index: false,
  canonicalPath: '/chat',
});

export default function RootPage() {
  return <RootRedirect />;
}
