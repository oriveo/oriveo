'use client';

import { lazy, Suspense } from 'react';
import type { ComponentProps } from 'react';

const ModelSwitcher = lazy(async () => {
  const mod = await import('./ModelSwitcher');
  return { default: mod.ModelSwitcher };
});

const ExportMenu = lazy(async () => {
  const mod = await import('./ExportMenu');
  return { default: mod.ExportMenu };
});

export function LazyModelSwitcher(props: ComponentProps<typeof ModelSwitcher>) {
  return (
    <Suspense fallback={null}>
      <ModelSwitcher {...props} />
    </Suspense>
  );
}

export function LazyExportMenu(props: ComponentProps<typeof ExportMenu>) {
  return (
    <Suspense fallback={null}>
      <ExportMenu {...props} />
    </Suspense>
  );
}
