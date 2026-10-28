"""Extract evaluation references from locally downloaded, version-pinned publisher JATS XML.

This is not a production reader or a PDF acquisition service. Keep paragraph, caption, table and heading references
separate: comparing a publisher's PDF with an unrelated arXiv revision must not masquerade as a conversion error.
Usage: python3 scripts/device-pdf-models/publisher_reference.py CORPUS_DIR
"""
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def text(node):
    return ' '.join(''.join(node.itertext()).split()) if node is not None else ''


def reference(path):
    raw = path.read_bytes()
    root = ET.fromstring(raw)
    paragraphs, headings, figures, tables = [], [], [], []

    def visit(node, depth=1):
        tag = node.tag.rsplit('}', 1)[-1]
        if tag == 'sec':
            title = node.find('title')
            if title is not None:
                headings.append({'id': node.get('id'), 'text': text(title), 'level': depth + 1})
            for child in node:
                if child.tag != 'title':
                    visit(child, depth + 1)
        elif tag == 'p':
            paragraphs.append({'id': node.get('id') or f'p-{len(paragraphs)}', 'text': text(node)})
        elif tag == 'fig':
            figures.append({'id': node.get('id'), 'label': text(node.find('label')), 'caption': text(node.find('caption'))})
            # Supplements can exist only online; keep them identifiable instead of silently counting them as PDF loss.
            for child in node:
                if child.tag in ['fig', 'fig-group']:
                    visit(child, depth)
        elif tag == 'table-wrap':
            tables.append({'id': node.get('id'), 'label': text(node.find('label')), 'caption': text(node.find('caption')),
                           'rows': [[{'text': text(c), 'rowspan': int(c.get('rowspan', '1')), 'colspan': int(c.get('colspan', '1'))}
                                     for c in row if c.tag in ['td', 'th']] for row in node.findall('.//tr')]})
        elif tag not in ['ref-list', 'title', 'label', 'caption', 'disp-formula', 'supplementary-material']:
            for child in node:
                visit(child, depth)

    body = root.find('body')
    if body is not None:
        visit(body)
    return {'source_sha256': hashlib.sha256(raw).hexdigest(), 'paragraphs': paragraphs, 'headings': headings,
            'figures': figures, 'tables': tables, 'display_equations': len(root.findall('.//disp-formula'))}


if __name__ == '__main__':
    for path in sorted(Path(sys.argv[1]).glob('*/source.xml')):
        result = reference(path)
        (path.parent / 'reference.json').write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n')
        print(path.parent.name, {k: len(result[k]) for k in ['paragraphs', 'headings', 'figures', 'tables']})
