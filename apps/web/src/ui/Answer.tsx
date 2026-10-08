import { memo, useMemo } from 'react';
import 'temml/dist/Temml-Local.css';
import { renderMarkdown } from '../lib/markdown';
// Loaded only when an answer is displayed; sign-in/library do not load Markdown or the math typesetter.
export default memo(function Answer({ text, streaming = false }: { text: string; streaming?: boolean }) {
  const html = useMemo(() => renderMarkdown(text, streaming), [text, streaming]);
  return <div className="answer-markdown" dangerouslySetInnerHTML={{ __html: html }} />;
});
