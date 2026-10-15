import { expect, it } from 'vitest';
import { dateLines, formatDateTime } from '../src/ui/common';

// The library's narrow date column (PaperTableDate, LibraryFormat.tableDateLines): the day over the time.
it('dates in a narrow column: the day, then the time; an earlier year has no time', () => {
  const now = new Date(2026, 9, 15, 15, 0);
  const at = (d: number, h = 9, m = 14, y = 2026, month = 9) => new Date(y, month, d, h, m).getTime();
  const time = (ms: number) => new Date(ms).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  expect(dateLines(at(15), now)).toEqual({ day: 'Today', time: time(at(15)) });
  expect(dateLines(at(14), now)).toEqual({ day: 'Yest.', time: time(at(14)) });
  expect(dateLines(at(12), now).day).toBe(new Date(at(12)).toLocaleDateString(undefined, { weekday: 'short' }));
  expect(dateLines(at(28, 9, 14, 2026, 8), now)).toEqual({ day: new Date(at(28, 9, 14, 2026, 8)).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }), time: time(at(28, 9, 14, 2026, 8)) });
  expect(dateLines(at(28, 9, 14, 2025, 8), now)).toEqual({ day: new Date(at(28, 9, 14, 2025, 8)).toLocaleDateString(undefined, { month: 'short', year: 'numeric' }), time: null });
  // The wide column keeps its one line.
  expect(formatDateTime(at(14), now)).toBe(`Yest. ${time(at(14))}`);
});
