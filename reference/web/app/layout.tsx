import type { Metadata, Viewport } from "next";
import "./globals.css";

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  viewportFit: "cover",
};

export const metadata: Metadata = {
  title: "Paper Reader",
  description: "AI-powered research paper reader",
  other: {
    "mobile-web-app-capable": "yes",
    "apple-mobile-web-app-capable": "yes",
    "apple-mobile-web-app-status-bar-style": "black-translucent",
    "apple-mobile-web-app-title": "Papers",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta name="theme-color" content="#0f0f0f" />
        <link rel="manifest" href="/manifest.json" />
        <link rel="icon" href="/icon.svg" type="image/svg+xml" />
        <link rel="apple-touch-icon" href="/icon.svg" />
        <link
          rel="stylesheet"
          href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css"
          crossOrigin="anonymous"
        />
      </head>
      <body>
        <script
          dangerouslySetInnerHTML={{
            __html: `try{if(localStorage.getItem("darkMode")==="true"){document.documentElement.classList.add("dark");var m=document.querySelector('meta[name="theme-color"]');if(m)m.setAttribute("content","#0f0f0f")}}catch(e){}try{if(navigator.standalone||window.matchMedia("(display-mode: standalone)").matches){document.documentElement.style.setProperty("--app-height",screen.height+"px")}}catch(e){}`,
          }}
        />
        {children}
        <script
          dangerouslySetInnerHTML={{
            __html: `if("serviceWorker"in navigator)navigator.serviceWorker.register("/sw.js").catch(function(){});window.addEventListener("error",function(e){document.body.innerHTML='<pre style="color:red;padding:20px;white-space:pre-wrap">JS Error: '+e.message+'\\n'+e.filename+':'+e.lineno+'</pre>'});window.addEventListener("unhandledrejection",function(e){document.body.innerHTML='<pre style="color:red;padding:20px;white-space:pre-wrap">Promise Error: '+e.reason+'</pre>'});if("ontouchstart"in window){document.addEventListener("contextmenu",function(e){if(!e.target.closest("input,textarea,[contenteditable]"))e.preventDefault()},false)}`,
          }}
        />
      </body>
    </html>
  );
}
