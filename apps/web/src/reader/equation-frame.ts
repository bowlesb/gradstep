// The equation view's picture of one equation (docs/architecture/EQUATION_VIEW.md): the bundle's own element (its
// MathML, or a formula image) with the paper's styles, in a sandboxed frame like the reader's, in the app's colours.
// Its one script (equation-shim.js, allowed by hash here and in the app's CSP) applies the chosen size, fits the width unless scrolling sideways, and reports the
// height so the panel can hold it.
import frame from 'virtual:equation-frame';
import type { VerifiedBundle } from '../lib/bundle';
import { equationElement } from '../lib/equation';
import { bundleStyles, scrub } from './frame';

export interface EquationFrameOptions { parentOrigin: string; theme: 'light' | 'dark'; size: number; scroll: boolean }


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
  config.textContent = JSON.stringify({ origin: options.parentOrigin, size: options.size, scroll: options.scroll }).replace(/</g, '\\u003c');
  const script = doc.createElement('script'); script.textContent = frame.script;
  doc.body.append(box, config, script);
  return '<!doctype html>\n' + doc.documentElement.outerHTML;
}
