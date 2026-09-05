import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    environmentOptions: { jsdom: { url: 'http://localhost/' } },
    setupFiles: ['./lib/__tests__/setup.ts'],
    globals: true,
    css: { modules: { classNameStrategy: 'non-scoped' } },
    // The Library orchestration ships behind NEXT_PUBLIC_LIBRARY_ENABLED, which is off unless a
    // build wires up a document source. The suite covers that orchestration, so it runs with the
    // flag on; the cases that are about the flag itself stub it per test.
    env: { NEXT_PUBLIC_LIBRARY_ENABLED: 'true' },
  },
  resolve: {
    alias: {
      '@oriveo/shared': resolve(import.meta.dirname, '../../packages/shared/src'),
      '@oriveo/config': resolve(import.meta.dirname, '../../packages/config/src'),
      '@oriveo/ui': resolve(import.meta.dirname, '../../packages/ui/src'),
    },
  },
});
