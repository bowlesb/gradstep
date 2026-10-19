"""Identity and ambiguity regressions for source-assisted annotation candidates."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest

from PIL import Image, ImageDraw
from source_html import Figures, source_path
from source_figures import archive_assets, select_group, subcaption_bounds
from source_sample import candidate_ids
from source_native import native_assets, caption_pages


class SourceTests(unittest.TestCase):
    def test_native_asset_requires_unique_pdf_and_explicit_tex_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'source.tar'
            with tarfile.open(path, 'w') as archive:
                for name, raw in [('figs/a.pdf', b'%PDF-test'), ('figs/b.pdf', b'%PDF-test'),
                                  ('one/c.pdf', b'%PDF-test'), ('two/c.pdf', b'%PDF-test'),
                                  ('../escape.pdf', b'%PDF-test'),
                                  ('main.tex', b'\\includegraphics[width=.5\\linewidth]{figs/a.pdf}\n'
                                               b'\\includegraphics{c}\n\\includegraphics{../escape.pdf}')]:
                    entry = tarfile.TarInfo(name); entry.size = len(raw)
                    archive.addfile(entry, io.BytesIO(raw))
                link = tarfile.TarInfo('figs/linked.pdf'); link.type = tarfile.SYMTYPE; link.linkname = '/tmp/elsewhere'
                archive.addfile(link)
            assets = native_assets(path, {'a', 'b', 'c', 'escape', 'linked'})
            self.assertEqual(set(assets), {'a'})
            self.assertEqual(assets['a']['references'][0]['line'], 1)

    def test_native_caption_page_uses_content_and_does_not_guess_between_duplicates(self):
        caption = 'Figure 3: Linear CKA between layers of the base and adapted model.'
        pages = ['Figure 3: Unrelated graph', caption, 'Different paper text']
        self.assertEqual(caption_pages(caption, pages), [1])
        self.assertEqual(caption_pages(caption, pages+[caption]), [1, 3])
        self.assertEqual(caption_pages('Figure 3', pages), [])

    def test_targeted_queue_can_admit_single_asset_heatmap_without_inventing_panels(self):
        parser = Figures('2601.01234v2')
        parser.feed('<figure id="F1"><img src="heat.png"><figcaption>Figure 1: Two heatmaps</figcaption></figure>'
                    '<figure id="F2"><img src="plain.png"><figcaption>Figure 2: Test accuracy</figcaption></figure>'
                    '<figure id="F3"><img src="vector.svg"><figcaption>Figure 3: Overview</figcaption></figure>'
                    '<figure id="F4"><img src="https://example.com/a.png"><figcaption>Pipeline</figcaption></figure>')
        self.assertEqual(candidate_ids(parser), ([], None))
        self.assertEqual(candidate_ids(parser, targeted=True), ([], ['F1']))
        self.assertEqual(candidate_ids(parser, targeted=True, topics=['diagram']), ([], []))
        self.assertEqual(parser.roots[0]['children'], [])

    def test_targeted_group_uses_child_caption_and_caps_review_queue(self):
        parser = Figures('2601.01234v2')
        parser.feed(''.join('<figure id="F%d"><figure><img src="a.png"><figcaption>(a) Heatmap</figcaption>'
                           '</figure><figure><img src="b.png"></figure></figure>' % i for i in range(6)))
        self.assertEqual(candidate_ids(parser, targeted=True), (['F0', 'F1', 'F2', 'F3'], []))

    def test_source_path_is_exact_relative_paper_identity(self):
        self.assertEqual(source_path('2601.01234v2/figs/a.png', '2601.01234v2'), 'figs/a.png')
        for path in ('https://example.com/a.png', '//example.com/a.png', '../a.png',
                     'figs/%2e%2e/a.png', '/tmp/a.png', 'a.png?token=secret', 'a\\b.png',
                     '2601.01234v1/a.png', 'figs/%00a.png', ''):
            with self.subTest(path=path), self.assertRaises(ValueError):
                source_path(path, '2601.01234v2')

    def test_html_requires_explicit_complete_children(self):
        p = Figures('2601.01234v2')
        p.feed('<figure id="F1"><figure id="a"><img src="a.png"><figcaption>(a) Test</figcaption>'
               '</figure><figure id="b"><img src="b.png"></figure><figcaption>Figure 1</figcaption>'
               '</figure><figure id="F2"><img src="c.png"><img src="d.png"></figure>')
        groups = list(p.groups())
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['children'][0]['caption'], '(a) Test')
        self.assertEqual(groups[0]['caption'], 'Figure 1')

    def test_archive_does_not_follow_links_or_choose_duplicate_suffix(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'source.tar'
            encoded = io.BytesIO()
            Image.new('RGB', (10, 12), '#1257ab').save(encoded, format='PNG')
            raw = encoded.getvalue()
            with tarfile.open(path, 'w') as archive:
                for name in ('paper/figs/a.png', 'x/figs/duplicate.png', 'y/figs/duplicate.png', '../escape.png'):
                    info = tarfile.TarInfo(name)
                    info.size = len(raw)
                    archive.addfile(info, io.BytesIO(raw))
                link = tarfile.TarInfo('figs/link.png')
                link.type, link.linkname = tarfile.SYMTYPE, '/etc/passwd'
                archive.addfile(link)
            assets = archive_assets(path, {'figs/a.png', 'figs/duplicate.png', 'figs/link.png', 'escape.png'})
            self.assertEqual(set(assets), {'figs/a.png'})
            expected = hashlib.sha256(Image.new('RGB', (10, 12), '#1257ab').tobytes()).hexdigest()
            self.assertEqual(assets['figs/a.png']['rgb_sha256'], expected)

    def test_exact_pixel_identity_not_file_encoding(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'source.tar'
            im = Image.new('RGB', (11, 9), '#a125b9')
            with tarfile.open(path, 'w') as archive:
                for name, level in (('a.png', 0), ('b.png', 9)):
                    data = io.BytesIO()
                    im.save(data, format='PNG', compress_level=level)
                    raw = data.getvalue()
                    entry = tarfile.TarInfo(name)
                    entry.size = len(raw)
                    archive.addfile(entry, io.BytesIO(raw))
            assets = archive_assets(path, {'a.png', 'b.png'})
            self.assertNotEqual(assets['a.png']['sha256'], assets['b.png']['sha256'])
            self.assertEqual(assets['a.png']['rgb_sha256'], assets['b.png']['rgb_sha256'])

    def test_group_requires_unique_shared_page_and_nonoverlap(self):
        assets = [{'rgb_sha256': 'a'}, {'rgb_sha256': 'b'}]
        a = {'page_zero_based': 2, 'box_points': [0, 0, 20, 20]}
        b = {'page_zero_based': 2, 'box_points': [30, 0, 50, 20]}
        self.assertEqual(select_group(assets, {'a': [a], 'b': [b]}), [a, b])
        invalid = [
            {'a': [a], 'b': []},
            {'a': [a, a], 'b': [b]},
            {'a': [a], 'b': [{**b, 'page_zero_based': 3}]},
            {'a': [a], 'b': [{**b, 'box_points': [10, 0, 30, 20]}]},
            {'a': [a, {**a, 'page_zero_based': 3}], 'b': [b, {**b, 'page_zero_based': 3}]},
        ]
        for mapping in invalid:
            with self.subTest(mapping=mapping), self.assertRaises(ValueError):
                select_group(assets, mapping)

    def test_subcaption_keeps_second_line_and_stops_before_figure_caption(self):
        words = [(10, 55, 20, 63, '(a)'), (23, 55, 60, 63, 'First'),
                 (10, 66, 65, 74, 'second'), (68, 66, 90, 74, 'line'),
                 (10, 85, 45, 93, 'Figure'), (48, 85, 55, 93, '1:')]
        page = SimpleNamespace(rect=SimpleNamespace(height=200), get_text=lambda _: words)
        image = Image.new('RGB', (200, 200), 'white')
        draw = ImageDraw.Draw(image)
        for w in words:
            draw.rectangle([w[0]+1, w[1]+1, w[2]-1, w[3]+1], fill='black')
        result, _ = subcaption_bounds('(a) First second line', [10, 10, 95, 50],
                                     [[10, 10, 95, 50]], page, image, 1)
        self.assertEqual([line['text'] for line in result['lines']], ['(a) First', 'second line'])
        self.assertGreaterEqual(result['ink_points'][3], 75)
        self.assertLess(result['ink_points'][3], 85)
        unrelated, _ = subcaption_bounds('(b) Unrelated', [10, 10, 95, 50], [], page, image, 1)
        self.assertIsNone(unrelated)

    def test_full_width_caption_cannot_contaminate_right_panel(self):
        words = [(110, 55, 125, 63, '(b)', 0, 0), (128, 55, 180, 63, 'Results', 0, 0),
                 (10, 70, 45, 78, 'Figure', 1, 0), (48, 70, 55, 78, '1:', 1, 0),
                 (100, 70, 180, 78, 'unrelated-caption', 1, 0)]
        page = SimpleNamespace(rect=SimpleNamespace(height=200), get_text=lambda _: words)
        image = Image.new('RGB', (220, 200), 'white')
        draw = ImageDraw.Draw(image)
        for w in words:
            draw.rectangle([w[0]+1, w[1]+1, w[2]-1, w[3]+1], fill='black')
        result, _ = subcaption_bounds('(b) Results', [100, 10, 195, 50], [], page, image, 1)
        self.assertEqual([line['text'] for line in result['lines']], ['(b) Results'])


if __name__ == '__main__':
    unittest.main()
