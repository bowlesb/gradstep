// Crop or redact a support screenshot (B5): what the edited image takes from the original and where its covers go.
import { expect, it } from 'vitest';
import { screenshotPlan } from '../src/lib/support';

it('crops to the box and moves covers into it, clipped; covers outside the crop go', () => {
  const plan = screenshotPlan(1000, 500, { crop: { x: 0.1, y: 0.2, w: 0.5, h: 0.5 }, covers: [{ x: 0.2, y: 0.3, w: 0.1, h: 0.1 }, { x: 0.55, y: 0.6, w: 0.2, h: 0.3 }, { x: 0.8, y: 0, w: 0.1, h: 0.1 }] });
  expect(plan.source).toEqual({ x: 100, y: 100, w: 500, h: 250 });
  expect(plan.covers).toEqual([{ x: 100, y: 50, w: 100, h: 50 }, { x: 450, y: 200, w: 50, h: 50 }]);
});
it('covers only: the whole image, each box in pixels', () => {
  expect(screenshotPlan(800, 600, { crop: null, covers: [{ x: 0, y: 0, w: 0.5, h: 0.25 }] })).toEqual({ source: { x: 0, y: 0, w: 800, h: 600 }, covers: [{ x: 0, y: 0, w: 400, h: 150 }] });
});
it('refuses a crop of 1% or less of a side', () => {
  expect(() => screenshotPlan(800, 600, { crop: { x: 0, y: 0, w: 0.01, h: 0.5 }, covers: [] })).toThrow('crop_too_small');
});
