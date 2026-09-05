import { useState, useCallback } from 'react';
import type { AIModel } from '@oriveo/shared';
import { evaluateExpensiveModelMultiplier } from '../../../lib/utils/format-utils';

interface ExpensiveModelHint {
  newModel: string;
  oldModel: string;
  multiplier: number;
}

/**
 * Expensive-model switch hint: shows a banner when the user switches to a noticeably pricier model.
 * evaluate computes the price ratio between the old and new model on model selection, and clear
 * resets it when a message is sent or the banner is dismissed.
 */
export function useExpensiveModelHint() {
  const [expensiveModelHint, setExpensiveModelHint] = useState<ExpensiveModelHint | null>(null);

  const evaluateExpensiveHint = useCallback((oldModel: AIModel | undefined, newModel: AIModel) => {
    const multiplier = evaluateExpensiveModelMultiplier(oldModel?.promptPrice, newModel.promptPrice);
    if (multiplier !== null && oldModel) {
      setExpensiveModelHint({ newModel: newModel.name, oldModel: oldModel.name, multiplier });
    } else {
      setExpensiveModelHint(null);
    }
  }, []);

  const clearExpensiveHint = useCallback(() => setExpensiveModelHint(null), []);

  return { expensiveModelHint, evaluateExpensiveHint, clearExpensiveHint };
}
