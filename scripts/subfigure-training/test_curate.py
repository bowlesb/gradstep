"""Known coordinates and identity cases for admitting PDF-derived research data."""
import unittest
import hashlib
from pathlib import Path
import tempfile
from curate_mathpix import annotation_boxes, author_key, near, verify_native_review


class CurateTests(unittest.TestCase):
    def test_native_admission_binds_review_to_exact_parent_render(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);page=root/'page.png';page.write_bytes(b'reviewed page')
            digest=hashlib.sha256(page.read_bytes()).hexdigest()
            c={'source_pdf_kind':'native_single_figure_asset','parent_page_review_image':'page.png',
               'parent_page_review_sha256':digest}
            with self.assertRaises(ValueError):verify_native_review({},c,root)
            spec={'parent_page_visual_match_sha256':digest}
            verify_native_review(spec,c,root)
            page.write_bytes(b'different page')
            with self.assertRaises(ValueError):verify_native_review(spec,c,root)

    def test_crop_translates_panels_and_shared_context_without_clipping(self):
        spec={'crop':[10,20,110,100],
              'panels':[{'box':[12,23,80,80],'required':['key']}],
              'contexts':[{'id':'key','class':0,'box':[90,25,108,85]}]}
        boxes=annotation_boxes(spec,150,120)
        self.assertEqual(boxes[0]['box'],[80,5,98,65])
        self.assertEqual(boxes[1]['box'],[2,3,70,60])
        self.assertEqual(boxes[1]['required_context_ids'],['key'])
        self.assertEqual(spec['contexts'][0]['box'],[90,25,108,85])

    def test_rejects_crop_that_removes_a_required_title(self):
        spec={'crop':[0,0,100,100],
              'panels':[{'box':[0,0,80,100],'required':['title']}],
              'contexts':[{'id':'title','class':1,'box':[0,0,120,20]}]}
        with self.assertRaises(ValueError):annotation_boxes(spec,120,100)
        spec['contexts']=[]
        with self.assertRaises(ValueError):annotation_boxes(spec,120,100)

    def test_split_duplicate_guard_is_scale_tolerant_but_aspect_sensitive(self):
        a={'sha256':'a','phash':'000000000000000f','width':200,'height':100}
        b={'sha256':'b','phash':'0000000000000000','width':400,'height':200}
        self.assertTrue(near(a,b))
        self.assertFalse(near(a,{**b,'height':400}))
        self.assertFalse(near(a,{**b,'phash':'ffffffffffffffff'}))

    def test_author_identity_handles_comma_order_without_matching_initials(self):
        self.assertEqual(author_key('Jane Marie Smith'),author_key('Smith, Jane Marie'))
        self.assertNotEqual(author_key('Smith, J.'),author_key('Jane Marie Smith'))


if __name__=='__main__':unittest.main()
