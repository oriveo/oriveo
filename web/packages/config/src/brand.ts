export const brand = {
  name: 'Oriveo',
  tagline: 'Every model, one app',
  description:
    'BYOK multi-model AI client. Use your own API keys for OpenAI, Claude, Gemini, and more — one chat, one place.',
  /**
   * Origin the app is served from. Used for canonical URLs, the sitemap, and
   * `metadataBase`. Override it when deploying somewhere other than the dev port.
   */
  appUrl: process.env.NEXT_PUBLIC_APP_URL || 'http://localhost:3001',
  repoUrl: 'https://github.com/oriveo/oriveo',
} as const;
