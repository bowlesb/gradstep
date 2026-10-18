# Local figure regions

Status, 2026-10-18: investigated with a working Mac PyTorch/Core ML experiment. No detector is bundled with the app. No physical iPhone measurements. See [measured results](../reviews/LOCAL_FIGURE_REGIONS_20261018.md). This is the design for the next prototype, not a released capability.

The owner asked for a purpose-built local model to extract subfigures and plots, shared by Figure AI Explainer and ordinary chat, regardless of the chosen cloud/local answering model. Geometry belongs on the device; explanation belongs to the chosen chat model. A small detector can locate panels without an LLM generating coordinates or receiving a whole PDF. PDFs, figure acquisition and cropping remain device-only, as in [HTML_FIRST_READER](HTML_FIRST_READER.md).

## One figure context for every conversation

The existing verified figure image, caption, numbered surrounding paragraphs and structured equations remain authoritative inputs. The proposed `FigureRegionSet` adds candidate regions to that exact image. It contains the image SHA-256, decoded pixel dimensions/orientation, detector identity and weight hash, preprocessing revision, and normalized top-left `x/y/width/height` coordinates. A stable region ID derives from those inputs and the accepted geometry, never from a model-generated title. Multiple image assets use the exact same compositing transform as the displayed figure; boxes cannot silently move to a different composite or revision.

Keep detector boxes separate from explanation claims. A candidate is a geometric region, not proof that it is panel (b), a legend, or the evidence for a particular claim. Caption labels and local OCR can help associate candidates, but unresolved associations keep the whole figure. Nested insets, shared legends and table/diagram structures need explicit representation rather than forced nonoverlapping panels. A retained region may require additional context boxes, especially a legend shared with another panel.

For a prototype, opening a figure may prepare candidates locally in a cancellable background task. Selecting a region gives the same context to the existing figure conversation or main chat: crop, a small whole-figure overview, caption, relevant numbered paragraphs, and exact LaTeX when relevant. The small overview preserves shared context without sending every PDF page. Cloud transmission still requires the existing consent and an explicit question; local detection itself uses no AI credits. A selected local text-only model cannot interpret the pixels and must say so.

The explainer and Chat retain one composer, selected model and conversation. Fullscreen offers Whole figure / Selected part. Returning from a citation reopens the saved explanation without another request. Region extraction should improve that shared context, not create a second conversation or separate credit-consuming feature. An unsure detector leaves the whole figure visible; a future manual region adjustment can be proposed with a concrete interaction before implementation.

## Storage and admission

Do not modify a verified reader bundle. Cache accepted geometry as an account-isolated encrypted sidecar using the existing local encrypted-storage conventions. Cache key includes image hash, detector hash and preprocessing revision. Derived image crops need not be persisted: reproduce them from the original image. Clear sidecars and in-memory regions with paper-content removal and account removal. No server schema, uploaded PDFs or plaintext persistent search index is needed.

Before admitting a region, validate finite coordinates, positive extent, bounds, minimum rendered detail, image identity and transform. Detect duplicate/near-identical and crossing boxes; preserve legitimate insets separately. Check that axes, tick labels, panel labels and legends needed to interpret the plot are included. OCR/text-block containment is useful here, but is not yet implemented or proven. A confidence threshold is insufficient: the tested heatmap lost labels at 0.92 confidence. When checks disagree, retain the whole figure and permit answering from it.

Bound image dimensions, concurrent work (one detector run), result count and cache size. Run inference outside the UI thread, cancel on paper/account change, and allow memory pressure to discard model/results. Model installation must use a pinned manifest/hash and verified license. Reuse the app's Local models download/error conventions if a separate download is needed. Never download another chat model merely to crop a figure.

## Verification before inclusion in a build

Build a human-reviewed corpus across ML plots, scientific diagrams, microscopy, tables, insets, shared legends, vector-rendered figures and scans. Include the owner's failed FDE-Gym crops. Split papers/authors between tuning and evaluation. Record panel recall, incorrect extra crops, IoU, exact panel association, and preservation of axes/labels/legends. A whole-figure fallback counts as a missed extraction rather than a successful split. Evaluate downstream answers with the same caption/paragraph context using both cloud and local chat, including unsupported questions.

Test the complete preprocessing/export pipeline, not just the source weights. Pin resize/letterbox rules, orientation, output decoding, NMS and original-image coordinate conversion. Replay fixtures offline on each change. Measure first use separately from steady-state, peak app memory, thermal behavior and cancellation on the intended phone once physical-device testing resumes. Mac speed is not iPhone evidence.

Distribution remains gated on a suitable license and quality. The current figpanel weights and inference tooling carry AGPL terms; they are research inputs only. Next candidates are a permissively licensed/trainable small detector and the Florence-2 plot adapter, with both base and adapter licenses checked. The research does not justify shipping the current detector as an automatic cropper.
