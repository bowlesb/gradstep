import { expect, it } from 'vitest';
import { authorLine, compactAuthors, familyName, firstAuthorLine } from '../src/lib/authors';

const attention = ['Ashish Vaswani', 'Noam Shazeer', 'Niki Parmar', 'Jakob Uszkoreit', 'Llion Jones', 'Aidan N. Gomez', 'Łukasz Kaiser', 'Illia Polosukhin'];

it('family names follow the native rules', () => {
  expect(familyName('Vaswani, Ashish')).toBe('Vaswani');
  expect(familyName('Ludwig van Beethoven')).toBe('van Beethoven');
  expect(familyName('Martin Luther King, Jr.')).toBe('King');
  expect(familyName('Prince')).toBe('Prince');
});

it('rows show up to three family names and how many more', () => {
  expect(compactAuthors([])).toBe('');
  expect(compactAuthors(['  ', ''])).toBe('');
  expect(compactAuthors(['Ashish Vaswani'])).toBe('Ashish Vaswani');
  expect(compactAuthors(['Diederik P. Kingma', 'Jimmy Ba'])).toBe('Kingma, Ba');
  expect(compactAuthors(['A B', 'C D', 'E F'])).toBe('B, D, F');
  expect(compactAuthors(attention)).toBe('Vaswani, Shazeer, Parmar +5');
});

it('cards show full names up to a limit, and bylines the first author', () => {
  expect(authorLine(attention)).toBe('Ashish Vaswani, Noam Shazeer, Niki Parmar, Jakob Uszkoreit, Llion Jones, Aidan N. Gomez +2');
  expect(authorLine(attention.slice(0, 2))).toBe('Ashish Vaswani, Noam Shazeer');
  expect(firstAuthorLine(attention)).toBe('Vaswani et al.');
  expect(firstAuthorLine(['Ashish Vaswani'])).toBe('Ashish Vaswani');
  expect(firstAuthorLine([])).toBe('');
});
