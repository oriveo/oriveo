import { Suspense } from 'react';
import { brand } from '@oriveo/config';
import { SUPPORTED_LOCALES } from '../../lib/i18n/locale-utils';
import { buildAppPageMetadata } from '../../lib/seo/public-metadata';
import { Welcome } from './Welcome';

export const metadata = buildAppPageMetadata({
  title: 'BYOK AI Client for OpenAI, Claude, Gemini, and OpenRouter',
  description:
    'Start using Oriveo on the web with your own AI keys. BYOK multi-model chat, local-first data, and real-time cost tracking in one app.',
  path: '/welcome',
});

/**
 * The landing page is the only indexable route, so it is the only place structured data belongs.
 *
 * Every claim below is one the app actually meets: the client is free and its source is AGPL, it
 * runs in a browser with no account, and it ships the sixteen interface languages listed. Nothing
 * that would need evidence we do not have — a rating, a review count, a download total — is
 * asserted.
 */
const softwareApplicationJsonLd = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: brand.name,
  applicationCategory: 'ProductivityApplication',
  operatingSystem: 'Any (web browser)',
  description: brand.description,
  url: `${brand.appUrl}/welcome`,
  inLanguage: [...SUPPORTED_LOCALES],
  isAccessibleForFree: true,
  license: 'https://www.gnu.org/licenses/agpl-3.0.html',
  codeRepository: brand.repoUrl,
  offers: {
    '@type': 'Offer',
    price: '0',
    priceCurrency: 'USD',
  },
};

export default function WelcomePage() {
  return (
    <>
      <script
        type="application/ld+json"
        // Serialized from a literal above, so there is no user input to escape.
        dangerouslySetInnerHTML={{ __html: JSON.stringify(softwareApplicationJsonLd) }}
      />
      <Suspense>
        <Welcome />
      </Suspense>
    </>
  );
}
