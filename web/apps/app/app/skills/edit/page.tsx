'use client';

import { Suspense } from 'react';
import { SkillEditPage } from './SkillEditPage';

export default function SkillEditRoute() {
  return (
    <Suspense>
      <SkillEditPage />
    </Suspense>
  );
}
