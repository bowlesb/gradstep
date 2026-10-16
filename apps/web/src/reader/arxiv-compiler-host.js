// An opaque-origin, network-disabled compiler frame. Only the parent supplies
// bytes. No fetch, source scripts, filesystem or credentials are available.
// Only finite reason codes cross the frame boundary. Exception messages may
// contain source text or browser details and must never be forwarded or logged.
function compilerFailure(error) {
 const code = error?.message;
 if (code === 'arxiv_conversion_error') return 'source-incomplete';
 if (['arxiv_article','arxiv_identity'].includes(code)) return 'source-unavailable';
 if (['source_limit','bundle_limit','manifest_limit','html_limit','block_limit','heading_limit',
  'image_limit','image_total_limit','image_dimensions','image_dimensions_exceeded','svg_dimensions','base64_limit'].includes(code)) return 'limit';
 if (['arxiv_math_attribute','arxiv_math_element','arxiv_math_style','arxiv_math_semantics',
  'arxiv_math_source','arxiv_math_mismatch','arxiv_math_empty','arxiv_math_coverage','arxiv_math_duplicate','arxiv_equation'].includes(code)) return 'math';
 if (['arxiv_asset_url','arxiv_asset_type','arxiv_inline_svg','arxiv_asset','arxiv_asset_set',
  'arxiv_asset_missing','arxiv_asset_coverage','image_decode','image_timeout','svg_attribute',
  'svg_doctype','svg_element','svg_fragment','svg_id','svg_invalid','svg_resource','svg_style','invalid_image'].includes(code)
  || ['EncodingError','SecurityError'].includes(error?.name)) return 'figure';
 if (['arxiv_duplicate_id','arxiv_unresolved_fragment','arxiv_fragment'].includes(code)) return 'reference';
 if (['arxiv_nested_content','arxiv_list','arxiv_table_span','arxiv_caption','arxiv_figure',
  'arxiv_node','arxiv_title','arxiv_block_text','arxiv_alt'].includes(code)) return 'formatting';
 return 'unknown';
}
// The listed code itself, for the reader's ⓘ: only a code compilerFailure names crosses (never another message); a
// browser decode error is named by its kind.
function compilerCode(error) {
 if (compilerFailure(error) === 'unknown') return null;
 const code = error?.message;
 if (typeof code === 'string' && /^[a-z][a-z0-9_]{2,63}$/.test(code) && compilerFailure({ message: code }) !== 'unknown') return code;
 return error?.name === 'EncodingError' ? 'image_encoding' : error?.name === 'SecurityError' ? 'image_security' : null;
}
addEventListener('message', async event => {
 if (event.source !== parent || event.ports.length !== 1) return;
 const port = event.ports[0], p = event.data;
 try {
  if (!p || !['assets','prepare'].includes(p.method)) throw Error('invalid');
  const result = p.method === 'assets' ? GradstepArxivReader.assets(p.source,p.sourceID,p.revision,p.options)
   : await GradstepArxivReader.prepare(p.source,p.sourceID,p.revision,p.inputs,p.options);
  port.postMessage({ok:true,result});
 } catch (error) { port.postMessage({ok:false,failure:compilerFailure(error),code:compilerCode(error)}); }
 finally { port.close(); }
});
