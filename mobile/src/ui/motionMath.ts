// The pure arithmetic of `motion.tsx` (kept apart so that it can be tested without the animation runtime).

/** Rows past this index enter without a delay, so long lists never wait. */
export const STAGGER_CAP = 8;
export const STAGGER_STEP = 40;

/** Delay of the `index`-th row of a staggered entrance (0 past the cap). */
export function staggerDelay(index: number): number {
  return index < STAGGER_CAP ? Math.max(index, 0) * STAGGER_STEP : 0;
}

/** The count at `t` ∈ [0, 1] of a count from `from` to `to`, eased out (an integer; `to` at t = 1). */
export function countUpValue(from: number, to: number, t: number): number {
  const clamped = Math.max(0, Math.min(1, t));
  const eased = 1 - Math.pow(1 - clamped, 3);
  return clamped >= 1 ? to : Math.round(from + (to - from) * eased);
}

/**
 * The drawn part of a progress bar `width` wide and `height` tall: 0 when empty, else at least 3 % and at least a
 * round cap (the bar's height), never more than the whole.
 */
export function progressFill(fraction: number, width: number, height: number): number {
  const clamped = Math.max(0, Math.min(1, Number.isFinite(fraction) ? fraction : 0));
  if (clamped === 0 || width <= 0) return clamped;
  return Math.min(1, Math.max(clamped, 0.03, height / width));
}
