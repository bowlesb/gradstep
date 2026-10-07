<script>
import {onMount} from 'svelte';
import Row from './Row.svelte';
import Stream from './Stream.svelte';
import {prepare,papers,filterSort,windowRange,changed} from './shared.js';
let rows = $state.raw([]), query = $state(''), descending = $state(false);
let virtual = $state(false), scrollTop = $state(0);
let filtered = $derived(filterSort(rows,query,descending));
let range = $derived(windowRange(filtered.length,scrollTop,virtual));
let shown = $derived(filtered.slice(range.start,range.end));
function onQuery(event) {query=event.target.value;scrollTop=0;document.querySelector('.viewport').scrollTop=0;}
onMount(() => {
  window.bench = {prepare,load:(count,windowed)=>{rows=papers(count);query='';descending=false;scrollTop=0;virtual=windowed;},
    update:()=>{rows=changed(rows);},sort:()=>{descending=!descending;},filter:(q)=>{query=q;scrollTop=0;},
    info:()=>({count:filtered.length,dom:document.querySelectorAll('tr.row').length})};
});
</script>
<main><h1>Library</h1><header><input aria-label="Search library" value={query} oninput={onQuery}/><button onclick={()=>descending=!descending}>Sort title</button><button onclick={()=>rows=changed(rows)}>Update progress</button><span class="count">{filtered.length} papers</span></header><div class="layout"><div class="viewport" onscroll={event=>scrollTop=event.currentTarget.scrollTop} role="region" aria-label="Library papers"><table><thead><tr><th>Title</th><th class="year">Year</th><th class="tag-col">Tags</th><th class="progress">Read</th></tr></thead><tbody>{#if range.before>0}<tr class="spacer" aria-hidden="true"><td colspan="4" style:height={range.before+'px'}></td></tr>{/if}{#each shown as paper (paper.id)}<Row {paper}/>{/each}{#if range.after>0}<tr class="spacer" aria-hidden="true"><td colspan="4" style:height={range.after+'px'}></td></tr>{/if}</tbody></table></div><Stream/></div></main>
