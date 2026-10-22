// An explainer's JSON reply read as it is written (FIGURE_VIEW.md "Speed", EQUATION_VIEW.md "Streamed explanation"): one
// object `{"<count>": N, "<summary>": "…", "<list>": [{…}, …]}` (keys in any order). The figure walkthrough
// (`parts` / `summary` / `sections`) and the equation's symbols (`count` / `summary` / `symbols`) share this reader.
//
// A character scanner keeps only the open containers, each object's current key and where the values of interest
// started; a completed value is parsed with JSON.parse from its own slice and checked by the caller's own check (the
// same one the final answer uses), so malformed or cut-off input yields nothing for that value and the items a device is
// shown are exactly the final answer's. Only the first top-level object is read: a code fence or words around it are
// ignored. O(n) over the reply, which the provider adapter bounds.

export type ListStreamItem<T> = { kind: 'count'; count: number } | { kind: 'summary'; summary: string } | { kind: 'item'; index: number; item: T };

export interface ListStreamShape<T> {
  /** The announced number of items (asked for first: a progress bar's denominator, never a promise). */
  countKey: string;
  summaryKey: string;
  listKey: string;
  /** An announced count outside 1…maxCount is not one. */
  maxCount: number;
  /** Items kept at most (later ones are counted as completed, not kept). */
  maxItems: number;
  /** The summary, checked (may be empty: then it is not relayed). */
  summary(value: unknown): string;
  /** One item, checked against those kept before it; null leaves it out. */
  item(raw: unknown, kept: readonly T[]): T | null;
}

type Frame = { kind: '{' | '['; key: string | null; expectKey: boolean; start: number; role: 'list' | 'item' | null };

export class JsonListStream<T> {
  private text = '';
  private at = 0;
  private inString = false;
  private escaped = false;
  private stringStart = -1;
  private stringIsKey = false;
  private readonly stack: Frame[] = [];
  private summarySent = false;
  private closed = false;
  private objectStart = -1;
  private objectEnd = -1;
  private digits = '';
  /** The announced count: null until read, 0 when it was not a usable number. */
  private announced: number | null = null;
  protected summaryText = '';
  protected readonly kept: T[] = [];
  private seen = 0;
  private readonly shape: ListStreamShape<T>;
  constructor(shape: ListStreamShape<T>) { this.shape = shape; }

  /** Characters of the object written so far (0 until it starts). */
  get length(): number { return this.objectStart < 0 ? 0 : (this.closed ? this.objectEnd : this.text.length) - this.objectStart; }
  /** Item objects the model has closed so far (usable or not). */
  get completed(): number { return this.seen; }
  /** The items streamed so far (checked, in order). */
  get items(): readonly T[] { return this.kept; }
  /** The summary streamed (empty until its string closed). */
  get summary(): string { return this.summaryText; }
  /** The count the model announced, when it did. */
  get count(): number | null { return this.announced || null; }
  /** Whether the top-level object has closed (written to its end). */
  get complete(): boolean { return this.closed; }

  read(chunk: string): ListStreamItem<T>[] {
    const out: ListStreamItem<T>[] = [];
    this.text += chunk;
    for (; this.at < this.text.length; this.at++) {
      const c = this.text[this.at];
      if (!this.stack.length && !this.inString) {
        if (c === '{' && !this.closed) { this.stack.push({ kind: '{', key: null, expectKey: true, start: this.at, role: null }); this.objectStart = this.at; }
        continue;
      }
      if (this.inString) {
        if (this.escaped) this.escaped = false;
        else if (c === '\\') this.escaped = true;
        else if (c === '"') { this.inString = false; this.endString(out); }
        continue;
      }
      const top = this.stack.at(-1);
      // The announced count (asked for first): read as its digits end.
      if (this.stack.length === 1 && top?.key === this.shape.countKey && !top.expectKey && this.announced === null) {
        if (c >= '0' && c <= '9' && this.digits.length < 3) { this.digits += c; continue; }
        if (this.digits) {
          const n = Number(this.digits);
          this.announced = n >= 1 && n <= this.shape.maxCount ? n : 0;
          if (this.announced) out.push({ kind: 'count', count: n });
        }
      }
      if (c === '"') {
        this.inString = true; this.stringStart = this.at;
        this.stringIsKey = !!top && top.kind === '{' && top.expectKey;
      } else if (c === '{' || c === '[') {
        const role = c === '[' && this.stack.length === 1 && top?.key === this.shape.listKey ? 'list'
          : c === '{' && top?.role === 'list' ? 'item' : null;
        this.stack.push({ kind: c, key: null, expectKey: c === '{', start: this.at, role });
      } else if (c === '}' || c === ']') {
        // A bracket that closes the wrong kind (`[0, 0.1}`) closes up to its own kind, so one malformed item does not
        // swallow the rest; that item fails to parse and is left out.
        const kind = c === '}' ? '{' : '[';
        let closed = this.stack.pop();
        while (closed && closed.kind !== kind && this.stack.length) {
          if (closed.role === 'item') this.endItem(closed.start, out);
          closed = this.stack.pop();
        }
        if (closed?.role === 'item') this.endItem(closed.start, out);
        if (!this.stack.length) { this.closed = true; this.objectEnd = this.at + 1; }
      } else if (c === ',' && top?.kind === '{') top.expectKey = true;
    }
    return out;
  }

  private endString(out: ListStreamItem<T>[]) {
    const top = this.stack.at(-1);
    if (!top || top.kind !== '{') return;
    let value: unknown;
    try { value = JSON.parse(this.text.slice(this.stringStart, this.at + 1)); } catch { return; }
    if (this.stringIsKey) { top.key = typeof value === 'string' ? value : null; top.expectKey = false; return; }
    if (this.stack.length === 1 && top.key === this.shape.summaryKey && !this.summarySent) {
      this.summarySent = true;
      const summary = this.shape.summary(value);
      this.summaryText = summary;
      if (summary) out.push({ kind: 'summary', summary });
    }
  }

  private endItem(start: number, out: ListStreamItem<T>[]) {
    this.seen++;
    if (this.kept.length >= this.shape.maxItems) return;
    let raw: unknown;
    try { raw = JSON.parse(this.text.slice(start, this.at + 1)); } catch { return; }
    const item = this.shape.item(raw, this.kept);
    if (item === null) return;
    this.kept.push(item);
    out.push({ kind: 'item', index: this.kept.length - 1, item });
  }
}
