import React, {memo, useCallback, useLayoutEffect, useMemo, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {prepare, papers, filterSort, windowRange, changed} from './shared.js';
const Row = memo(function Row({paper}) {
  return <tr className="row" data-paper={paper.id}><td><a className="title" href={'#paper-' + paper.id}>{paper.title}</a><span className="author">{paper.author}</span></td><td className="year">{paper.year}</td><td className="tag tag-col">{paper.tag}</td><td className="progress">{paper.progress}%</td></tr>;
});
const Stream = memo(function Stream() {
  const [text, setText] = useState('');
  useLayoutEffect(() => { window.stream = {append:(chunk) => setText(t => t+chunk), reset:() => setText('')}; }, []);
  return <aside><h2>Paper chat</h2><p>Completed answers stay unchanged while the new answer streams.</p><p id="answer">{text}</p></aside>;
});
function App() {
  const [rows, setRows] = useState([]), [query, setQuery] = useState(''), [descending, setDescending] = useState(false);
  const [virtual, setVirtual] = useState(false), [scrollTop, setScrollTop] = useState(0);
  const filtered = useMemo(() => filterSort(rows,query,descending),[rows,query,descending]);
  const range = windowRange(filtered.length,scrollTop,virtual);
  const shown = useMemo(() => filtered.slice(range.start,range.end),[filtered,range.start,range.end]);
  const onScroll = useCallback(event => setScrollTop(event.currentTarget.scrollTop),[]);
  const onQuery = useCallback(event => {setQuery(event.target.value);setScrollTop(0);document.querySelector('.viewport').scrollTop=0;},[]);
  useLayoutEffect(() => {
    window.bench = {prepare, load:(count,windowed) => {setRows(papers(count));setQuery('');setDescending(false);setScrollTop(0);setVirtual(windowed);},
      update:()=>setRows(changed), sort:()=>setDescending(v=>!v), filter:(q)=>{setQuery(q);setScrollTop(0);},
      info:()=>({count:filtered.length,dom:document.querySelectorAll('tr.row').length})};
  },[filtered]);
  return <main><h1>Library</h1><header><input aria-label="Search library" value={query} onChange={onQuery}/><button onClick={()=>setDescending(v=>!v)}>Sort title</button><button onClick={()=>setRows(changed)}>Update progress</button><span className="count">{filtered.length} papers</span></header><div className="layout"><div className="viewport" onScroll={onScroll} role="region" aria-label="Library papers"><table><thead><tr><th>Title</th><th className="year">Year</th><th className="tag-col">Tags</th><th className="progress">Read</th></tr></thead><tbody>{range.before>0&&<tr className="spacer" aria-hidden="true"><td colSpan={4} style={{height:range.before}}/></tr>}{shown.map(paper=><Row key={paper.id} paper={paper}/>)}{range.after>0&&<tr className="spacer" aria-hidden="true"><td colSpan={4} style={{height:range.after}}/></tr>}</tbody></table></div><Stream/></div></main>;
}
createRoot(document.getElementById('app')).render(<App/>);
