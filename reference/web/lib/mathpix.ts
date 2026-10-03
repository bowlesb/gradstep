import { reportApiError } from "./api-health";

const MATHPIX_API = "https://api.mathpix.com/v3/pdf";

function mathpixHeaders() {
  return {
    app_id: process.env.MATHPIX_APP_ID!,
    app_key: process.env.MATHPIX_APP_KEY!,
  };
}

export async function submitPdf(file: File | Blob, filename?: string): Promise<string> {
  const formData = new FormData();
  if (file instanceof File) {
    formData.append("file", file);
  } else {
    formData.append("file", file, filename || "document.pdf");
  }
  formData.append(
    "options_json",
    JSON.stringify({
      conversion_formats: { md: true },
      math_inline_delimiters: ["$", "$"],
      math_display_delimiters: ["$$", "$$"],
      rm_spaces: false,
      enable_tables_fallback: true,
    })
  );

  const res = await fetch(MATHPIX_API, {
    method: "POST",
    headers: mathpixHeaders(),
    body: formData,
  });

  if (!res.ok) {
    const text = await res.text();
    reportApiError("mathpix", `Mathpix submit failed (${res.status}): ${text.slice(0, 200)}`);
    throw new Error(`Mathpix submit failed (${res.status}): ${text}`);
  }
  return (await res.json()).pdf_id;
}

export async function pollUntilDone(pdfId: string): Promise<void> {
  for (let i = 0; i < 120; i++) {
    const res = await fetch(`${MATHPIX_API}/${pdfId}`, {
      headers: mathpixHeaders(),
    });
    const data = await res.json();
    if (data.status === "completed") return;
    if (data.status === "error") {
      reportApiError("mathpix", `Mathpix processing error for PDF`);
      throw new Error(`Mathpix error for ${pdfId}`);
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error("Mathpix polling timed out");
}

export async function getHtml(pdfId: string): Promise<string> {
  const res = await fetch(`${MATHPIX_API}/${pdfId}.html`, {
    headers: mathpixHeaders(),
  });
  if (!res.ok) throw new Error(`Failed to get HTML: ${res.status}`);
  return res.text();
}

export async function getMarkdown(pdfId: string): Promise<string> {
  const res = await fetch(`${MATHPIX_API}/${pdfId}.md`, {
    headers: mathpixHeaders(),
  });
  if (!res.ok) throw new Error(`Failed to get markdown: ${res.status}`);
  return res.text();
}
