"""Term layer for step 2: corpus phrases, a "concept" filter and three term rankings.

- Candidates are 1-3-grams seen in >= 3 corpus papers (a phrase that crosses a boundary, "axes llm", rarely repeats).
- Conceptness: how much closer a phrase's own embedding is to the papers that use it than to the corpus as a whole.
  Terms of art ("speculative decoding" +0.058, "kv cache" +0.037) sit near their papers; filler ("natively" -0.002,
  "typically evaluated" +0.006, "comparable quality" -0.054) is as close to everything.
- paper_terms: TF-IDF (IDF from the public corpus) re-ranked by closeness to the paper (KeyBERT-style).
- library_terms: weighted log-odds with an informative Dirichlet prior (Monroe et al. 2008), library vs corpus.
- topic_terms: the same log-odds for one topic's papers, re-ranked by closeness to the topic centroid.
Near-duplicates are dropped by substring and by embedding (cos > 0.88).
"""
import os

import numpy as np
from sklearn.feature_extraction.text import CountVectorizer

from common import OUT
from topic_map import STOP

TOKEN = r"(?u)\b[a-zA-Z][a-zA-Z0-9\-]+\b"
MIN_CONCEPT = 0.02   # closeness to its own papers minus closeness to the whole corpus (gte-small)
DUP_COS = 0.88


def text_of(p):
    return f"{p['title']}. {p['title']}. {p['abstract']}"  # the title counts twice


class Terms:
    def __init__(self, corpus, E):
        self.corpus, self.E = corpus, E
        cv = CountVectorizer(ngram_range=(1, 3), stop_words=STOP, min_df=3, max_df=0.10, token_pattern=TOKEN)
        C = cv.fit_transform([text_of(p) for p in corpus]).tocsr()
        self.vocab = np.array(cv.get_feature_names_out())
        self.B = (C > 0).astype(np.float32).tocsr()                        # papers x terms, binary
        df = np.asarray(self.B.sum(0)).ravel()
        self.df = df
        tf = C.astype(np.float32)
        tf.data = 1 + np.log(tf.data)
        self.T = tf.multiply(np.log((1 + len(corpus)) / (1 + df)) + 1).tocsr()  # sublinear TF-IDF
        self.ngram = np.array([t.count(" ") + 1 for t in self.vocab])
        self._emb, self._model = {}, None
        cache = os.path.join(OUT, "emb", "terms-gte-small.npz")
        if os.path.exists(cache):
            z = np.load(cache, allow_pickle=True)
            self._emb = dict(zip(z["terms"].tolist(), z["emb"]))
        self._cache = cache
        g = E.mean(0)
        self.g = g / np.linalg.norm(g)

    def embed(self, idx):
        need = [self.vocab[j] for j in idx if self.vocab[j] not in self._emb]
        if need:
            if self._model is None:
                from sentence_transformers import SentenceTransformer
                self._model = SentenceTransformer("thenlper/gte-small", device="cpu")
            for t, e in zip(need, self._model.encode(need, batch_size=256, normalize_embeddings=True)):
                self._emb[t] = e
        return np.array([self._emb[self.vocab[j]] for j in idx])

    def save(self):
        np.savez(self._cache, terms=np.array(list(self._emb)), emb=np.array(list(self._emb.values())))

    def conceptness(self, idx):
        V = self.embed(idx)
        out = np.empty(len(idx))
        for k, j in enumerate(idx):
            docs = self.B[:, j].nonzero()[0]
            c = self.E[docs].mean(0)
            out[k] = float(V[k] @ (c / np.linalg.norm(c))) - float(V[k] @ self.g)
        return out

    def _pick(self, idx, score, k, min_concept=MIN_CONCEPT):
        """Best-first with the concept filter and duplicate removal."""
        order = [idx[i] for i in np.argsort(-score)]
        concept = dict(zip(order[:200], self.conceptness(order[:200])))
        V = dict(zip(order[:200], self.embed(order[:200])))
        picked = []
        for j in order[:200]:
            if concept[j] < min_concept:
                continue
            t = self.vocab[j]
            if any(t in self.vocab[p] or self.vocab[p] in t for p in picked):
                continue
            if any(float(V[j] @ V[p]) > DUP_COS for p in picked):
                continue
            picked.append(j)
            if len(picked) == k:
                break
        return picked

    def paper_terms(self, r, k=5):
        row = self.T[r]
        idx = row.indices
        if not len(idx):
            return []
        tfidf = row.data * np.where(self.ngram[idx] > 1, 1.25, 1.0)
        top = idx[np.argsort(-tfidf)[:40]]
        tfidf = np.sort(tfidf)[::-1][:40]
        closeness = self.embed(top) @ self.E[r]
        score = tfidf / tfidf.max() + 2.0 * (closeness - closeness.mean())
        return [self.vocab[j] for j in self._pick(list(top), score, k)]

    def log_odds(self, rows, weights):
        user = np.zeros(len(self.corpus), dtype=np.float32)
        user[rows] = weights
        is_user = user > 0
        yu = np.asarray(self.B.T @ user).ravel()
        cnt_u = np.asarray(self.B[is_user].sum(0)).ravel()
        yb = self.df - cnt_u
        nu, nb = yu.sum(), yb.sum()
        a0 = 1000.0
        a = a0 * (yu + yb) / (nu + nb)
        delta = np.log((yu + a) / (nu + a0 - yu - a)) - np.log((yb + a) / (nb + a0 - yb - a))
        z = delta / np.sqrt(1 / (yu + a) + 1 / (yb + a))
        return z, cnt_u, yb

    def library_terms(self, rows, weights, k=25, min_user=2):
        z, cnt_u, yb = self.log_odds(rows, weights)
        idx = np.where(cnt_u >= min_user)[0]
        picked = self._pick(list(idx), z[idx], k)
        n_u, n_b = len(rows), len(self.corpus) - len(rows)
        return [{"term": self.vocab[j], "z": round(float(z[j]), 2), "user_papers": int(cnt_u[j]),
                 "background_papers": int(yb[j]),
                 "lift": round(float((cnt_u[j] / n_u) / max(yb[j] / n_b, 0.5 / n_b)), 1)} for j in picked]

    def topic_terms(self, rows, weights, k=3):
        z, cnt_u, _ = self.log_odds(rows, weights)
        need = 2 if len(rows) <= 4 else max(2, round(0.4 * len(rows)))
        idx = np.where(cnt_u >= need)[0]
        if not len(idx):
            idx = np.where(cnt_u >= 1)[0]
        c = (self.E[rows] * np.array(weights)[:, None]).sum(0)
        c /= np.linalg.norm(c)
        top = idx[np.argsort(-z[idx])[:60]]
        closeness = self.embed(top) @ c
        zt = z[top]
        score = zt / max(zt.max(), 1e-6) + 2.0 * (closeness - closeness.mean())
        return [self.vocab[j] for j in self._pick(list(top), score, k)]
