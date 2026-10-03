import { SaxesParser } from 'saxes';

export class SourceError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; }
}

export interface XMLNode {
  local: string;
  uri: string;
  attributes: Record<string, string>;
  children: XMLNode[];
  text: string;
}

// External XML is bounded before parsing. Do not resolve DTDs/entities or treat
// namespace prefixes as identity. Errors contain codes, never source payloads.
export function sourceXML(bytes: Uint8Array): XMLNode {
  if (!bytes.length || bytes.length > 1_048_576) throw new SourceError('metadata_size_limit');
  try {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    const parser = new SaxesParser({ xmlns: true, defaultXMLVersion: '1.0', forceXMLVersion: true });
    const stack: XMLNode[] = [];
    let root: XMLNode | undefined, count = 0;
    parser.on('error', () => { throw new SourceError('invalid_source_xml'); });
    parser.on('doctype', () => { throw new SourceError('invalid_source_xml'); });
    parser.on('opentag', tag => {
      if (++count > 20_000 || stack.length >= 32 || Object.keys(tag.attributes).length > 64) throw new SourceError('metadata_size_limit');
      const attributes: Record<string, string> = Object.create(null);
      for (const value of Object.values(tag.attributes)) {
        if (value.value.length > 4096) throw new SourceError('metadata_size_limit');
        attributes[`{${value.uri}}${value.local}`] = value.value;
      }
      const node: XMLNode = { local: tag.local, uri: tag.uri, attributes, children: [], text: '' };
      if (stack.length) stack[stack.length - 1].children.push(node);
      else {
        if (root) throw new SourceError('invalid_source_xml');
        root = node;
      }
      stack.push(node);
    });
    const append = (value: string) => {
      const node = stack[stack.length - 1];
      if (node) node.text += value;
    };
    parser.on('text', append);
    parser.on('cdata', append);
    parser.on('closetag', () => { stack.pop(); });
    parser.write(text).close();
    if (!root || stack.length) throw new SourceError('invalid_source_xml');
    return root;
  } catch (error) {
    if (error instanceof SourceError) throw error;
    throw new SourceError('invalid_source_xml');
  }
}

export function children(node: XMLNode, uri: string, local: string): XMLNode[] {
  return node.children.filter(child => child.uri === uri && child.local === local);
}

export function one(node: XMLNode, uri: string, local: string, required = true): XMLNode | undefined {
  const matches = children(node, uri, local);
  if (matches.length > 1 || (required && matches.length !== 1)) throw new SourceError('invalid_source_metadata');
  return matches[0];
}

export function plain(node: XMLNode | undefined, maximumBytes: number, required = true): string | null {
  if (!node) {
    if (required) throw new SourceError('invalid_source_metadata');
    return null;
  }
  const value = node.text.replace(/\s+/gu, ' ').trim();
  if (node.children.length || new TextEncoder().encode(value).length > maximumBytes || (required && !value)) throw new SourceError('invalid_source_metadata');
  return value || null;
}
