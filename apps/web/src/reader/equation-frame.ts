// The equation view's picture of one equation (docs/architecture/EQUATION_VIEW.md): the bundle's own element (its
// MathML, or a formula image) with the paper's styles, in a sandboxed frame like the reader's, in the app's colours.
// Its one script (equation-shim.js, allowed by hash here and in the app's CSP) applies the chosen size, fits the width unless scrolling sideways, and reports the
// height so the panel can hold it. In a tiles document (Contents › Equations › View as tiles) it fits each equation to its
// tile and posts a chosen tile's id instead.
import frame from 'virtual:equation-frame';
import type { VerifiedBundle } from '../lib/bundle';
import { equationElement } from '../lib/equation';
import { bundleStyles, scrub } from './frame';

export interface EquationFrameOptions { parentOrigin: string; theme: 'light' | 'dark'; size: number; scroll?: boolean; scale?: number }


const SCHEME = /\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)/gi;
/** The paper's colour rules for the app's appearance, whatever the system's (as the reader frame's shim does). */
export const forScheme = (css: string, theme: 'light' | 'dark') => css.replace(SCHEME, (_, value: string) => value.toLowerCase() === theme ? '(min-width: 0px)' : '(max-width: 0.01px)');

/** The frame document, or null when the bundle has no such equation. */
export function equationDocument(bundle: VerifiedBundle, equationID: string, options: EquationFrameOptions): string | null {
  const source = equationElement(bundle, equationID);
  if (!source) return null;
  const doc = document.implementation.createHTMLDocument('Equation');
  const element = doc.importNode(source, true) as Element;
  scrub(element, bundle);
  const csp = doc.createElement('meta');
  csp.setAttribute('http-equiv', 'Content-Security-Policy');
  csp.setAttribute('content', `default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src '${frame.hash}'; base-uri 'none'; form-action 'none'; connect-src 'none'; frame-src 'none'; font-src 'none'`);
  doc.head.prepend(csp);
  for (const text of [...bundleStyles(bundle), `:root:root{color-scheme:${options.theme}}html,body{margin:0;padding:0;overflow:hidden}
#eq-box{padding:14px 18px;overflow:hidden}#eq-box.scroll{overflow-x:auto}
#eq{display:inline-block;white-space:nowrap;max-width:none}
#eq .reader-equation{margin:0;max-width:none;overflow:visible}#eq .reader-display{display:inline-block;padding:4px 0}
#eq .reader-display.reader-tagged{display:inline-flex}#eq img{max-width:none}`]) {
    const style = doc.createElement('style');
    style.textContent = forScheme(text, options.theme);
    doc.head.append(style);
  }
  const box = doc.createElement('div'); box.id = 'eq-box';
  const eq = doc.createElement('div'); eq.id = 'eq'; eq.append(element); box.append(eq);
  const config = doc.createElement('script');
  config.setAttribute('type', 'application/json'); config.id = 'eq-config';
  config.textContent = JSON.stringify({ origin: options.parentOrigin, size: options.size, scale: options.scale ?? 1 }).replace(/</g, '\\u003c');
  const script = doc.createElement('script'); script.textContent = frame.script;
  doc.body.append(box, config, script);
  return '<!doctype html>\n' + doc.documentElement.outerHTML;
}

export interface EquationTile { id: string; label: string }
/** Contents › Equations › View as tiles (owner, build 62: "a tile view similar to figures"): every listed equation in
 * one frame document, not a frame per tile — each the bundle's own element with the paper's styles in a labelled tile
 * (a button). The shim scales each equation down to its tile and posts `{gradstep: 'equation-tile', id}` for the one
 * chosen. Equations the page doesn't have are left out. */
export function equationTilesDocument(bundle: VerifiedBundle, tiles: readonly EquationTile[], options: Omit<EquationFrameOptions, 'scroll'>): string {
  const doc = document.implementation.createHTMLDocument('Equations');
  const csp = doc.createElement('meta');
  csp.setAttribute('http-equiv', 'Content-Security-Policy');
  csp.setAttribute('content', `default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src '${frame.hash}'; base-uri 'none'; form-action 'none'; connect-src 'none'; frame-src 'none'; font-src 'none'`);
  doc.head.prepend(csp);
  const dark = options.theme === 'dark';
  for (const text of [...bundleStyles(bundle), `:root:root{color-scheme:${options.theme}}html,body{margin:0;padding:0;background:transparent}
#eq-tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;padding:4px 2px 16px}
.eq-tile{all:unset;box-sizing:border-box;display:flex;flex-direction:column;gap:6px;min-width:0;padding:10px 12px 12px;border-radius:12px;cursor:pointer;
  border:1px solid ${dark ? 'rgba(255,255,255,.14)' : 'rgba(0,0,0,.12)'};background:${dark ? 'rgba(255,255,255,.04)' : '#fff'}}
.eq-tile:hover{border-color:${dark ? 'rgba(255,255,255,.3)' : 'rgba(0,0,0,.28)'}}
.eq-tile:focus-visible{outline:2px solid ${dark ? '#8ab4ff' : '#2458d6'};outline-offset:2px}
.eq-tile-label{font:600 13px/1.3 system-ui,-apple-system,sans-serif;color:${dark ? 'rgba(255,255,255,.72)' : 'rgba(0,0,0,.62)'};white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.eq-tile-math{display:flex;align-items:center;justify-content:center;height:92px;overflow:hidden}
.eq-tile-math > *{flex:none;white-space:nowrap}
.eq-tile-math .reader-equation{margin:0;max-width:none;overflow:visible}.eq-tile-math .reader-display{display:inline-block;padding:0}
.eq-tile-math .reader-display.reader-tagged{display:inline-flex}.eq-tile-math img{max-width:none}`]) {
    const style = doc.createElement('style');
    style.textContent = forScheme(text, options.theme);
    doc.head.append(style);
  }
  const grid = doc.createElement('div'); grid.id = 'eq-tiles';
  for (const tile of tiles) {
    const source = equationElement(bundle, tile.id);
    if (!source) continue;
    const element = doc.importNode(source, true) as Element;
    scrub(element, bundle);
    const button = doc.createElement('button');
    button.type = 'button'; button.className = 'eq-tile'; button.setAttribute('data-tile', tile.id);
    const label = doc.createElement('span'); label.className = 'eq-tile-label'; label.textContent = tile.label;
    const math = doc.createElement('span'); math.className = 'eq-tile-math'; math.setAttribute('aria-hidden', 'true');
    const holder = doc.createElement('span'); holder.append(element); math.append(holder);
    button.append(label, math);
    grid.append(button);
  }
  const config = doc.createElement('script');
  config.setAttribute('type', 'application/json'); config.id = 'eq-config';
  config.textContent = JSON.stringify({ origin: options.parentOrigin, size: options.size }).replace(/</g, '\\u003c');
  const script = doc.createElement('script'); script.textContent = frame.script;
  doc.body.append(grid, config, script);
  return '<!doctype html>\n' + doc.documentElement.outerHTML;
}
