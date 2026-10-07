<script>
import {onMount} from 'svelte';
let text = $state('');
onMount(() => { window.stream = {append:(chunk)=>text+=chunk, reset:()=>text=''}; });
</script>
<aside><h2>Paper chat</h2><p>Completed answers stay unchanged while the new answer streams.</p><p id="answer">{text}</p></aside>
