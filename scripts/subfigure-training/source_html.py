"""Read official HTML figure identity without executing it or fetching anything."""
from html.parser import HTMLParser
from pathlib import PurePosixPath
import re
from urllib.parse import unquote, urlsplit


def source_path(src, revision):
    """Only a relative path belonging to this exact paper; never an external URL."""
    url = urlsplit(src)
    if url.scheme or url.netloc or url.query or url.fragment:
        raise ValueError('External or decorated image path')
    path = unquote(url.path)
    if path.startswith(revision + '/'):
        path = path[len(revision) + 1:]
    elif re.match(r'^\d{4}\.\d{4,5}v\d+/', path):
        raise ValueError('Image belongs to another paper revision')
    parts = PurePosixPath(path).parts
    if not parts or path.startswith('/') or '\\' in path or '\0' in path or '..' in parts:
        raise ValueError('Unsafe source image path')
    return str(PurePosixPath(*parts))


class Figures(HTMLParser):
    def __init__(self, revision):
        super().__init__(convert_charrefs=True)
        self.revision = revision
        self.roots, self.stack, self.captions = [], [], []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'figure':
            node = {'id': attrs.get('id'), 'images': [], 'children': [], 'caption': ''}
            if self.stack:
                self.stack[-1]['children'].append(node)
            else:
                self.roots.append(node)
            self.stack.append(node)
        elif tag == 'img' and self.stack:
            try:
                path = source_path(attrs.get('src', ''), self.revision)
            except ValueError:
                path = None
            self.stack[-1]['images'].append({'path': path, 'src': attrs.get('src')})
        elif tag == 'figcaption' and self.stack:
            self.captions.append(self.stack[-1])

    def handle_endtag(self, tag):
        if tag == 'figure' and self.stack:
            self.stack.pop()
        elif tag == 'figcaption' and self.captions:
            self.captions.pop()

    def handle_data(self, data):
        if self.captions:
            self.captions[-1]['caption'] += data

    def groups(self):
        for root in self.roots:
            if not root['id'] or root['images'] or not 2 <= len(root['children']) <= 32:
                continue
            children = root['children']
            if any(c['children'] or len(c['images']) != 1 or not c['images'][0]['path'] for c in children):
                continue
            # Explicit source identity is a candidate, not a claim of semantic panels.
            yield root
