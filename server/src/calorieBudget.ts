// Integer percentages are the public plan contract. Legacy kcal values are only
// accepted/returned during the installed-app transition, never used for budgets.
export const deficitPercentages = [0, 10, 15, 20] as const;
export type DeficitPercent = typeof deficitPercentages[number];

export function percentFromLegacyKcal(kcal: number): DeficitPercent {
  if (kcal === 0) return 0;
  if (kcal < 375) return 10;
  if (kcal < 525) return 15;
  return 20;
}

export function legacyKcalFromPercent(percent: number): number {
  return ({ 0: 0, 10: 300, 15: 450, 20: 600 } as Record<number, number>)[percent];
}

export function calorieBudget(restingKcal: number, activeKcal: number, deficitPercent: number) {
  const tdeeKcal = restingKcal + activeKcal;
  const allowanceKcal = Math.round(tdeeKcal * (1 - deficitPercent / 100));
  return { tdeeKcal, deficitPercent, allowanceKcal, gapKcal: tdeeKcal - allowanceKcal };
}
