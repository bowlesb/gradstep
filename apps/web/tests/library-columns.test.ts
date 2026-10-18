import { expect, it } from 'vitest';
import { defaultLibraryColumns, parseLibraryColumns } from '../src/lib/library-columns';

it('keeps explicit current column choices, including title only, in fixed order', () => {
  expect(parseLibraryColumns('{"version":2,"columns":["progress","authors","year"]}')).toEqual(['authors', 'year', 'progress']);
  expect(parseLibraryColumns('{"version":2,"columns":[]}')).toEqual([]);
  expect(defaultLibraryColumns(true)).toEqual(['device', 'authors', 'year', 'progress']);
  expect(defaultLibraryColumns(false)).toEqual(['device', 'authors', 'year', 'tags', 'added', 'opened', 'progress']);
});
it('adds separate metadata once to older saved columns', () => {
  expect(parseLibraryColumns('{"version":1,"columns":["year","progress"]}')).toEqual(['device', 'authors', 'year', 'progress']);
  expect(parseLibraryColumns('{"version":2,"columns":["year","progress"]}')).toEqual(['year', 'progress']);
});
it('ignores malformed, oversized, unknown or duplicate preferences as a whole', () => {
  for (const raw of [null, '', 'null', '[]', '{', ' '.repeat(257),
    '{"version":3,"columns":["year"]}', '{"version":2,"columns":["title"]}',
    '{"version":2,"columns":["year","year"]}', '{"version":2,"columns":[1]}',
    '{"version":2,"columns":["secret"]}', '{"version":2,"columns":["year"],"account":"x"}']) {
    expect(parseLibraryColumns(raw)).toBeNull();
  }
});
