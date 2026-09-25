import { countUpValue, progressFill, STAGGER_CAP, STAGGER_STEP, staggerDelay } from '../motionMath';

describe('staggerDelay', () => {
  it('steps the first rows and stops at the cap', () => {
    expect(staggerDelay(0)).toBe(0);
    expect(staggerDelay(1)).toBe(STAGGER_STEP);
    expect(staggerDelay(STAGGER_CAP - 1)).toBe((STAGGER_CAP - 1) * STAGGER_STEP);
    expect(staggerDelay(STAGGER_CAP)).toBe(0);
    expect(staggerDelay(40)).toBe(0);
    expect(staggerDelay(-2)).toBe(0);
  });
});

describe('countUpValue', () => {
  it('starts at from, ends exactly at to, and never overshoots', () => {
    expect(countUpValue(0, 14, 0)).toBe(0);
    expect(countUpValue(0, 14, 1)).toBe(14);
    expect(countUpValue(0, 14, 2)).toBe(14);
    const mid = countUpValue(0, 14, 0.5);
    expect(mid).toBeGreaterThan(7);
    expect(mid).toBeLessThanOrEqual(14);
    expect(countUpValue(10, 4, 1)).toBe(4);
    expect(Number.isInteger(countUpValue(0, 3, 0.37))).toBe(true);
  });
});

describe('progressFill', () => {
  it('draws nothing at 0 and a visible minimum above it', () => {
    expect(progressFill(0, 300, 8)).toBe(0);
    expect(progressFill(-1, 300, 8)).toBe(0);
    expect(progressFill(Number.NaN, 300, 8)).toBe(0);
    expect(progressFill(0.001, 300, 8)).toBeCloseTo(8 / 300);
    expect(progressFill(0.001, 1000, 8)).toBeCloseTo(0.03);
    expect(progressFill(0.5, 300, 8)).toBe(0.5);
    expect(progressFill(3, 300, 8)).toBe(1);
  });
});
