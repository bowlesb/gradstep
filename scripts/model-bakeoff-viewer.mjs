// Build the in-conversation answer comparison from local, already-paid evidence. No network or credentials.
import {readFileSync,writeFileSync,readdirSync,existsSync,mkdirSync} from 'node:fs';
const base='.artifacts/bakeoff';
const archiveFile=['docs/reviews/model-comparison-finalists-20261016/evidence.json','docs/reviews/model-comparison-20261016/evidence.json'].find(existsSync);
const archive=!existsSync(`${base}/report.json`)&&existsSync(archiveFile)?JSON.parse(readFileSync(archiveFile)):null;
const report=archive?.report??JSON.parse(readFileSync(`${base}/report.json`));
const sourceReview=archive?.continuation_review??(existsSync(`${base}/continuation/source-review.json`)?JSON.parse(readFileSync(`${base}/continuation/source-review.json`)):null);
const selected=report.questions;
const questions=readdirSync('tests/model-bakeoff').filter(f=>f.endsWith('.json')&&!f.startsWith('_'))
  .flatMap(f=>JSON.parse(readFileSync('tests/model-bakeoff/'+f))).filter(q=>selected.includes(q.id))
  .map(q=>({id:q.id,label:q.id.replaceAll('-',' ').replaceAll('_',' '),question:q.question,reference:q.reference}));
const answers={};
const modelNames={'sonnet-medium':'Sonnet medium','haiku-medium':'Haiku medium','haiku-high':'Haiku high','luna-high':'Luna high','sol-low':'Sol low','sol-medium':'Sol medium','gemini-flash-medium':'Gemini Flash medium','argon-medium':'Argon medium','mimo-pro':'MiMo Pro','mimo-flash':'MiMo Flash','glm-flash':'GLM Flash','qwen-flash':'Qwen Flash','deepseek-flash':'DeepSeek — original endpoint','deepseek-deepinfra':'DeepSeek — DeepInfra FP8'};
const models=Object.entries(modelNames).filter(([id])=>archive?archive.runs.some(r=>r.model===id):existsSync(`${base}/runs/${id}`)).map(([id,label])=>({id,label}));
for(const model of models){answers[model.id]={};for(const q of questions){const file=`${base}/runs/${model.id}/${q.id}.json`;const r=archive?archive.runs.find(r=>r.model===model.id&&r.question===q.id):existsSync(file)?JSON.parse(readFileSync(file)):null;if(!r)continue;const grades=Object.entries(report.grades[model.id]?.[q.id]??{});
  answers[model.id][q.id]={text:r.text??'',error:r.error?.startsWith('HTTP 404')?'Endpoint refused by account data-use policy':r.error??null,cost:r.cost,firstText:r.first_text_s??null,
    score:report.grades[model.id]?.[q.id]?.[report.primary_judge??'argon']?.overall??null,
    judgeScores:grades.map(([judge,g])=>({judge:judge.replace('-claims-v2',' · claim review'),score:g.overall})),
    tools:(r.tool_calls??[]).map(c=>c.name==='create_diagram'?`${c.name}: ${c.input?.title??''}\n${c.input?.mermaid??''}`:`${c.name}: ${c.input?.figure??c.input?.title??''}`),
    comments:grades.map(([judge,g])=>`${judge.replace('-claims-v2',' · claim review')}: ${g.comment}${typeof g.material_error==='boolean'?'\n\nMaterial error flagged: '+(g.material_error?'yes':'no'):''}${g.errors?.length?'\n\n'+g.errors.map(e=>'- '+e).join('\n'):''}${g.required_omissions?.length?'\n\nRequired omissions: '+g.required_omissions.join('; '):''}${g.optional_omissions?.length?'\n\nOptional background omitted: '+g.optional_omissions.join('; '):''}`),
    sourceNotes:sourceReview?.checks.filter(c=>c.question===q.id&&(!c.model||c.model===model.id)).map(c=>[c.finding,...(c.errors??[])].join('\n\n'))??[]};
}}
const json=JSON.stringify({models,questions,answers}).replaceAll('<','\\u003c');
const template=readFileSync('scripts/templates/model-comparison.html','utf8');
const fragment=template.replace('__DATA_JSON__',json);
if(Buffer.byteLength(fragment)>1_000_000)throw new Error('Viewer exceeds the inline size limit');
mkdirSync(base,{recursive:true});writeFileSync(`${base}/model-comparison.html`,fragment);
console.log(`Answer comparison: ${Buffer.byteLength(fragment)} bytes, ${models.length} settings, ${questions.length} questions`);
