export async function loadSkillOps(): Promise<typeof import('./ops')> {
  return import('./ops');
}
