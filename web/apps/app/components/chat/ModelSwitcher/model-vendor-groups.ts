import type { AIModel } from "@oriveo/shared";

export interface ModelVendorGroup {
  key: string;
  name: string;
  models: AIModel[];
}

// Group by the groupKey sent by the server, preserving first-appearance order, for the home page and the crosscheck selector.
export function groupModelsByVendor(models: AIModel[]): ModelVendorGroup[] {
  const order: string[] = [];
  const map = new Map<string, ModelVendorGroup>();
  for (const model of models) {
    const key = model.groupKey ?? "__ungrouped__";
    let group = map.get(key);
    if (!group) {
      group = { key, name: model.groupName ?? "", models: [] };
      map.set(key, group);
      order.push(key);
    }
    group.models.push(model);
  }
  return order.map((key) => map.get(key)!);
}
