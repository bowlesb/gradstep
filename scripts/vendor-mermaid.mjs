#!/usr/bin/env node
// Copies the pinned Mermaid browser build into the app for on-device diagram
// rendering. The IIFE build declares its module namespace with a top-level
// `var`; binding it to globalThis explicitly makes it independent of how the
// script is evaluated. The input is pinned by hash; nothing else changes.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const INPUT = new URL('../node_modules/mermaid/dist/mermaid.min.js', import.meta.url);
const OUTPUT = new URL('../apps/apple/ScienceReader/Resources/mermaid.min.js', import.meta.url);
const EXPECTED = '6484afc32872a3aa16cac9a76ba1816a1ed4cc870a6593cc2e17757750f518b2'; // mermaid@12.1.0
const PREFIX = '"use strict";var __esbuild_esm_mermaid_nm;';

const original = readFileSync(INPUT, 'utf8');
const digest = createHash('sha256').update(original).digest('hex');
if (digest !== EXPECTED) throw new Error(`mermaid.min.js is ${digest}, expected the pinned ${EXPECTED}`);
if (!original.startsWith(PREFIX)) throw new Error('unexpected Mermaid bundle prefix');
const vendored = '"use strict";var __esbuild_esm_mermaid_nm=globalThis.__esbuild_esm_mermaid_nm={};' + original.slice(PREFIX.length);
writeFileSync(OUTPUT, vendored);
console.log('mermaid', JSON.parse(readFileSync(new URL('../node_modules/mermaid/package.json', import.meta.url), 'utf8')).version,
  'vendored sha256', createHash('sha256').update(vendored).digest('hex'));
