"""Independent hand-computed cases to prevent misleading crop qualification."""
import unittest
from PIL import Image
from train import letterbox, metrics, retained, average_precision
from train import containment_loss, summarize
import torch
from crop_policy import complete_text, deduplicate, crop_metrics, detection_gate
from compound_classifier import classification_metrics


class MetricTests(unittest.TestCase):
    def setUp(self):
        self.row={'id':'two-panels','group':'paper-a','width':200,'height':100,'boxes':[
            {'class':4,'box':[0,0,95,100]}, {'class':4,'box':[105,0,200,100]}]}

    def test_whole_figure_does_not_count_as_two_successful_crops(self):
        result=metrics([self.row],[[{'class':4,'box':[0,0,200,100],'score':.99}]])
        self.assertEqual((result['tp'],result['fp'],result['fn']),(0,1,2))

    def test_duplicate_crops_are_false_positives(self):
        predictions=[{'class':4,'box':b['box'],'score':.9} for b in self.row['boxes']]
        result=metrics([self.row],[predictions+[predictions[0]]])
        self.assertEqual((result['tp'],result['fp'],result['fn']),(2,1,0))
        self.assertAlmostEqual(result['false_crop_fraction'],1/3)

    def test_perfect_compound_detection_cannot_hide_false_splits_of_single_figures(self):
        single={'id':'single','group':'paper-b','width':200,'height':100,
                'boxes':[{'class':4,'box':[0,0,200,100]}]}
        predictions=[[{'class':4,'score':.99,'box':b['box']} for b in self.row['boxes']],
                     [{'class':4,'score':.99,'box':[0,0,200,100]},
                      {'class':4,'score':.9,'box':[0,0,50,50]}]]
        rows=[self.row,single]
        compound=metrics(rows,predictions,compounds_only=True)
        full=metrics(rows,predictions)
        self.assertEqual((compound['tp'],compound['fp'],compound['fn']),(2,0,0))
        self.assertEqual((full['tp'],full['fp'],full['fn']),(3,1,0))
        self.assertFalse(detection_gate(full,compound))
        report=summarize(rows,predictions,.35)
        self.assertTrue(all(s['all_figures']['precision']==.75 for s in report['threshold_sweep']))

    def test_class_and_confidence_cannot_hide_missed_panels(self):
        predictions=[{'class':0,'box':[0,0,95,100],'score':.99},
                     {'class':4,'box':[105,0,200,100],'score':.1}]
        result=metrics([self.row],[predictions])
        self.assertEqual((result['tp'],result['fn']),(0,2))

    def test_missing_label_area_is_measured(self):
        self.assertAlmostEqual(retained([0,0,100,100],[10,0,100,100]),.9)
        self.assertEqual(retained([0,0,100,100],[0,0,200,200]),1)

    def test_compound_classifier_counts_false_splits_and_misses(self):
        result=classification_metrics([1,1,0,0],[.9,.3,.7,.1],.5)
        self.assertEqual((result['tp'],result['fn'],result['fp'],result['tn']),(1,1,1,1))
        self.assertEqual(result['auc'],.75)
        self.assertEqual(result['compound_recall'],.5)
        self.assertEqual(result['single_specificity'],.5)
        self.assertEqual(classification_metrics([1,0],[.5,.5],.5)['auc'],.5)

    def test_classifier_rejects_nonfinite_or_misaligned_scores(self):
        with self.assertRaises(ValueError):classification_metrics([1,0],[.5],.5)
        with self.assertRaises(ValueError):classification_metrics([1,0],[.5,float('nan')],.5)

    def test_perfect_predictions_have_perfect_ap_and_retention(self):
        predictions=[{'class':4,'box':b['box'],'score':.9} for b in self.row['boxes']]
        self.assertEqual(average_precision([self.row],[predictions],4),1)
        result=metrics([self.row],[predictions])
        self.assertEqual(result['matched_boxes_at_least_99pct_retained'],2)
        self.assertEqual(result['all_correct_images'],1)

    def test_rounded_letterbox_uses_exact_scale_on_each_axis(self):
        image=Image.new('RGB',(2137,743),'black')
        boxed,(sx,sy,left,top)=letterbox(image)
        self.assertEqual(boxed.size,(640,640))
        self.assertAlmostEqual(2137*sx,640)
        self.assertAlmostEqual(743*sy,223)
        self.assertEqual(top,208)
        self.assertNotEqual(sx,sy)

    def test_final_test_summary_never_selects_threshold(self):
        result=summarize([self.row],[[]],.65,select_threshold=False)
        self.assertNotIn('threshold_sweep',result)
        self.assertNotIn('selected_validation_threshold',result)
        self.assertEqual(result['compound_panel']['threshold'],.65)

    def test_spatial_augmentation_preserves_every_edge_and_its_transform(self):
        image=Image.new('RGB',(100,50),'black')
        boxed,(sx,sy,left,top)=letterbox(image,640,zoom=.75,position=(0,1))
        self.assertEqual((sx,sy,left,top),(4.8,4.8,0,400))
        self.assertEqual(boxed.getpixel((0,400)),(0,0,0))
        self.assertEqual(boxed.getpixel((479,639)),(0,0,0))
        self.assertEqual(boxed.getpixel((480,639)),(255,255,255))
        self.assertEqual(boxed.getpixel((0,399)),(255,255,255))

    def test_clipped_footer_has_outward_gradient(self):
        # Target is y=[.1,.9]; prediction y=[.1,.8], losing 1/8 of its height.
        prediction=torch.tensor([[.5,.45,.8,.7]],requires_grad=True)
        target=torch.tensor([[.5,.5,.8,.8]])
        loss=containment_loss(prediction,target)
        self.assertAlmostEqual(float(loss),.125,places=6)
        loss.backward()
        self.assertTrue(torch.isfinite(prediction.grad).all())
        self.assertLess(float(prediction.grad[0,3]),0.)

    def test_containment_loss_does_not_reward_more_outward_expansion(self):
        target=torch.tensor([[.5,.5,.6,.6]])
        for width in (.6,.8,1.):
            predicted=torch.tensor([[.5,.5,width,width]],requires_grad=True)
            self.assertEqual(float(containment_loss(predicted,target)),0.)

    def test_ocr_expansion_retains_raw_geometry_and_complete_text(self):
        predicted=[{'class':4,'box':[20,20,80,70],'score':.9}]
        text=[{'text':'(a)','confidence':.9,'box':[40,72,60,78]}]
        result=complete_text(predicted,text,100,100,.5)
        self.assertEqual(result[0]['box'],predicted[0]['box'])
        self.assertEqual(result[0]['crop'],[18,18,82,80])
        self.assertNotIn('crop',predicted[0])

    def test_shared_ocr_stays_common_context_not_giant_panel(self):
        predicted=[{'class':4,'box':[0,0,45,80],'score':.9},
                   {'class':4,'box':[55,0,100,80],'score':.9}]
        text=[{'text':'shared title','confidence':.9,'box':[25,81,75,85]}]
        result=complete_text(predicted,text,100,100,.5)
        for p in result:self.assertEqual(p['shared_text_boxes'],[[25,81,75,85]])
        self.assertEqual(result[0]['crop'],[0,0,47,82])

    def test_panel_letter_across_white_photo_margin_is_retained(self):
        predicted=[{'class':4,'box':[35,10,60,95],'score':.9}]
        tag={'text':'(a)','confidence':.99,'box':[13,3,18,9]}
        result=complete_text(predicted,[tag],100,100,.5)
        self.assertEqual(result[0]['crop'][0],11)
        prose={**tag,'text':'random prose'}
        result=complete_text(predicted,[prose],100,100,.5)
        self.assertEqual(result[0]['crop'][0],33)

    def test_duplicate_filter_preserves_distinct_inset_and_context(self):
        predictions=[{'class':4,'box':[0,0,100,100],'score':.99},
                     {'class':4,'box':[0,0,100,100],'score':.9},
                     {'class':4,'box':[10,10,30,30],'score':.95},
                     {'class':0,'box':[0,0,100,100],'score':.8}]
        result=deduplicate(predictions)
        self.assertEqual(len(result),3)
        self.assertIn(predictions[2],result)
        self.assertIn(predictions[3],result)

    def test_missing_shared_legend_is_failure_despite_perfect_panel(self):
        row={'id':'shared','group':'a','width':100,'height':100,'boxes':[
            {'id':'panel','class':4,'box':[0,0,60,80],'required_context_ids':['legend']},
            {'id':'legend','class':0,'box':[70,20,90,60]}]}
        result=crop_metrics([row],[[{'class':4,'score':.9,'box':[0,0,60,80]}]],.5)
        self.assertEqual(result['annotated_panel_area_retention_mean'],1.)
        self.assertEqual(result['context_links_missing_or_clipped'],1)

    def test_context_inside_panel_is_retained_even_if_separate_detection_is_clipped(self):
        row={'id':'inside','group':'a','width':100,'height':100,'boxes':[
            {'id':'panel','class':4,'box':[0,0,100,100],'required_context_ids':['legend']},
            {'id':'legend','class':0,'box':[20,20,60,60]}]}
        predictions=[{'class':4,'score':.9,'box':[0,0,100,100]},
                     {'class':0,'score':.8,'box':[25,25,55,55]}]
        result=crop_metrics([row],[predictions],.5)
        self.assertEqual(result['context_links_missing_or_clipped'],0)

    def test_common_text_cannot_substitute_for_a_color_legend(self):
        row={'id':'shared','group':'a','width':100,'height':100,'boxes':[
            {'id':'panel','class':4,'box':[0,0,60,80],'required_context_ids':['legend']},
            {'id':'legend','class':0,'box':[70,20,90,60]}]}
        predictions=[{'class':4,'score':.9,'box':[0,0,60,80],'shared_text_boxes':[[70,20,90,60]]}]
        result=crop_metrics([row],[predictions],.5)
        self.assertEqual(result['context_links_missing_or_clipped'],1)


if __name__=='__main__':unittest.main()
