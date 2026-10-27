// Build exact tagWindows inputs from the native glyph/layout audit; no recogniser or invented model answers.
import {readFileSync,writeFileSync,readdirSync} from 'node:fs';
import {join,basename} from 'node:path';
import {assign,growLines,linesOf,byX,visible,useLineBands,union,lineText,useLigatures,composeAccents} from '../../supabase/functions/_shared/reader/device-pdf/geometry.ts';
import {aliasFont,aliasText,tagWindows} from '../../supabase/functions/_shared/reader/device-pdf/tagger.ts';
const [folder,vocabPath,out]=process.argv.slice(2);
const vocab=JSON.parse(readFileSync(vocabPath));
useLineBands(true,true);useLigatures(true);
const rows=[]; const inputs=[];
for (const file of readdirSync(folder).filter(f=>f.endsWith('.json')).sort()) {
 const page=JSON.parse(readFileSync(join(folder,file))),a=page.glyphs;
 const glyphs=a.text.map((text,i)=>({text:aliasText(text,a.font[i]),font:aliasFont(a.font[i],vocab),x0:a.x0[i],top:a.top[i],x1:a.x1[i],bottom:a.bottom[i],size:a.size[i],upright:a.upright[i]})).filter(visible);
 composeAccents(glyphs);
 const regions=page.detections.map(d=>({...d,pt:d.box.map(x=>x/page.scale/(150/72))}));
 const owners=growLines(glyphs,assign(glyphs,regions));
 for(let r=0;r<regions.length;r++) {
  if(!['paragraph','abstract','caption','footnote'].includes(regions[r].cls))continue;
  const lines=linesOf(glyphs.filter((_,i)=>owners[i]===regions[r])).map(byX);
  for(let l=0;l<lines.length;l++) {
   const glyph=lines[l]; if(glyph.length<2)continue;
   const windows=tagWindows(glyph,vocab,lines[l-1],lines[l+1]);
   const slots=windows.map(w=>{const index=inputs.length;inputs.push(w.input);return {index,from:w.from,to:w.to,own:w.own};});
   rows.push({id:basename(file,'.json')+`-r${r}-l${l}`,paper:basename(file).split('-p')[0],page:page.page,source:page.pdf,
      region:r,cls:regions[r].cls,line:l,text:lineText(glyph,[])[0],compact:glyph.map(g=>g.text).join(''),box:union(glyph),glyphs:glyph,windows:slots});
  }
 }
}
writeFileSync(out+'.lines.jsonl',rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
writeFileSync(out+'.inputs.json',JSON.stringify(inputs));
console.log(JSON.stringify({lines:rows.length,inputs:inputs.length,glyphs:rows.reduce((s,r)=>s+r.glyphs.length,0)}));
