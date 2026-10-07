<script>
let {paper} = $props();
</script>
<tr class="row" data-paper={paper.id}><td><a class="title" href={'#paper-' + paper.id}>{paper.title}</a><span class="author">{paper.author}</span></td><td class="year">{paper.year}</td><td class="tag tag-col">{paper.tag}</td><td class="progress">{paper.progress}%</td></tr>
