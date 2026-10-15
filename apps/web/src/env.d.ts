/// <reference types="vite/client" />
declare module 'virtual:reader-frame' {
  const frame: { script: string; hash: string };
  export default frame;
}

declare module 'virtual:diagram-frame' { const frame: { script: string; hash: string }; export default frame; }

declare module 'virtual:arxiv-compiler' { const compiler: {script:string;hash:string}; export default compiler; }

declare module 'virtual:equation-frame' { const frame: { script: string; hash: string }; export default frame; }

/** The build's time, YYYYMMDDHHMM UTC (vite.config.ts `define`), named in support reports. */
declare const __WEB_BUILD__: string;
