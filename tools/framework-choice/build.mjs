import {build} from 'vite';
import {svelte} from '@sveltejs/vite-plugin-svelte';
import {transformAsync} from '@babel/core';
import compiler from 'babel-plugin-react-compiler';
import {resolve} from 'node:path';
import {readdirSync,readFileSync,writeFileSync} from 'node:fs';
import {gzipSync,brotliCompressSync} from 'node:zlib';
const results={};
for(const variant of ['react','react-compiler','svelte']){
 const plugins=variant==='svelte'?[svelte()]:variant==='react-compiler'?[{
  name:'react-compiler',enforce:'pre',async transform(code,id){
   if(!id.endsWith('/react.jsx'))return;
   const result=await transformAsync(code,{filename:id,babelrc:false,configFile:false,plugins:[[compiler,{target:'19'}]],parserOpts:{plugins:['jsx']}});
   return {code:result.code,map:null};
  }
 }]:[];
 await build({configFile:false,base:'./',root:process.cwd(),plugins,resolve:{alias:{'./implementation':resolve(variant==='svelte'?'svelte.js':'react.jsx')}},
   build:{outDir:'dist/'+variant,emptyOutDir:true,target:'es2022',sourcemap:false,assetsInlineLimit:0}});
 let js=0,gzip=0,brotli=0;
 for(const name of readdirSync('dist/'+variant+'/assets'))if(name.endsWith('.js')){
  const content=readFileSync('dist/'+variant+'/assets/'+name);js+=content.length;gzip+=gzipSync(content).length;brotli+=brotliCompressSync(content).length;
 }
 results[variant]={js_bytes:js,gzip_bytes:gzip,brotli_bytes:brotli};
}
writeFileSync('bundle-sizes.json',JSON.stringify(results,null,2)+'\n');
console.log(results);
