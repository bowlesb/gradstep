import { expect, it } from 'vitest';
import { defaultLibraryColumns, parseLibraryColumns } from '../src/lib/library-columns';

it('keeps finite column choices, including title only, in the table’s fixed order', () => {
  expect(parseLibraryColumns('{"version":1,"columns":["progress","authors","year"]}')).toEqual(['authors', 'year', 'progress']);
  expect(parseLibraryColumns('{"version":1,"columns":[]}')).toEqual([]);
  expect(defaultLibraryColumns(true)).toEqual(['year', 'progress']);
  expect(defaultLibraryColumns(false)).toEqual(['authors', 'year', 'tags', 'added', 'opened', 'progress']);
});

it('ignores malformed, oversized, unknown or duplicate preferences as a whole', () => {
  for (const raw of [null, '', 'null', '[]', '{', ' '.repeat(257),
    '{"version":2,"columns":["year"]}', '{"version":1,"columns":["title"]}',
    '{"version":1,"columns":["year","year"]}', '{"version":1,"columns":[1]}',
    '{"version":1,"columns":["secret"]}', '{"version":1,"columns":["year"],"account":"x"}',
    '{"version":1,"columns":["authors","year","tags","added","opened","progress","year"]}']) {
    expect(parseLibraryColumns(raw)).toBeNull();
  }
});
