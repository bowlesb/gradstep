"""Training contract checks; run in the recorded desktop PyTorch environment, without PDFs or a GPU."""
import math
import unittest
import torch
from papers_statistics_labels import propose
from papers_train_tagger import complete_expression_loss


class CompleteExpressionTests(unittest.TestCase):
    def row(self,text):
        return {'text':text,'glyphs':[{'text':c} for c in text if not c.isspace()]}

    def test_supervision_keeps_complete_numeric_relations_and_masks_unreviewed_math(self):
        for text,expected in [
            ('reported MSE = 0.006 and softmax(z)', 'MSE=0.006'),
            ('at p < 10−4 corrected', 'p<10−4'),
            ('when P < 2.7 × 10−4 corrected', 'P<2.7×10−4'),
            ('correlation r = 0.35 ± 0.03 here', 'r=0.35±0.03'),
            ('with 0.01 < p < 0.05 reported', '0.01<p<0.05'),
            ('after F(1.9, 64.6) = 3.38 reported', 'F(1.9,64.6)=3.38'),
        ]:
            row=propose(self.row(text),complete=True)
            self.assertEqual(len(row['proposed_spans']),1,text)
            span=row['proposed_spans'][0]
            self.assertEqual(''.join(g['text'] for g in row['glyphs'][span['from']:span['to']]),expected)
            self.assertTrue(all(v==-1 for i,v in enumerate(row['mask']) if not span['from']<=i<span['to']))

    def test_plural_or_word_suffix_is_not_a_scalar_variable(self):
        for text in ["all F’s < 1 reported", "all F's < 1 reported", 'context=5']:
            self.assertIsNone(propose(self.row(text),complete=True))

    def test_worst_glyph_loss_balances_expressions_and_ignores_unknown_context(self):
        logits=torch.tensor([[2.,-2.,-100.,1.],[-100.,3.,3.,-100.]],requires_grad=True)
        target=torch.tensor([[1.,1.,-1.,1.],[-1.,1.,1.,0.]])
        loss=complete_expression_loss(logits,target)
        expected=(math.log1p(math.exp(2))+math.log1p(math.exp(-1))+math.log1p(math.exp(-3)))/3
        self.assertAlmostEqual(float(loss.detach()),expected,places=6)
        loss.backward()
        self.assertEqual(float(logits.grad[0,2]),0)
        self.assertEqual(float(logits.grad[1,0]),0)
        self.assertEqual(float(logits.grad[1,3]),0)
        self.assertLess(float(logits.grad[0,1]),0)
        self.assertEqual(float(logits.grad[0,0]),0)

    def test_no_positive_span_has_zero_finite_loss_and_gradient(self):
        logits=torch.tensor([[10.,-10.]],requires_grad=True)
        loss=complete_expression_loss(logits,torch.tensor([[-1.,0.]]))
        self.assertEqual(float(loss.detach()),0);loss.backward()
        self.assertTrue(torch.equal(logits.grad,torch.zeros_like(logits)))


if __name__=='__main__':unittest.main()
