import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import ExcelJS from "exceljs";
import JSZip from "jszip";

import { AnalysisError, createSession, documentKind } from "../file-analysis.mjs";

async function withWorkspace(body) {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "desktop-pet-file-analysis-"));
  try {
    await body(workspace);
  } finally {
    await fs.rm(workspace, { recursive: true, force: true });
  }
}

function makeTextPDF(text) {
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  const stream = `BT /F1 12 Tf 72 720 Td (${text}) Tj ET`;
  objects.push(`<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`);
  let document = "%PDF-1.4\n";
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(document));
    document += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(document);
  document += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) document += `${String(offset).padStart(10, "0")} 00000 n \n`;
  document += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(document, "ascii");
}

test("recognizes the Windows format allowlist and rejects legacy XLS", () => {
  assert.equal(documentKind("report.xlsx"), "spreadsheet");
  assert.equal(documentKind("macro.XLSM"), "spreadsheet");
  assert.equal(documentKind("notes.md"), "text");
  assert.equal(documentKind("Dockerfile"), "text");
  assert.equal(documentKind("legacy.xls"), null);
});

test("creates an Excel session with sheets, dates, booleans, formulas, and cached results", async () => {
  await withWorkspace(async (workspace) => {
    const workbook = new ExcelJS.Workbook();
    const first = workbook.addWorksheet("中文工作表");
    first.getCell("A1").value = "软件平台";
    first.getCell("C3").value = true;
    first.getCell("D4").value = new Date("2026-08-19T00:00:00.000Z");
    first.getCell("E5").value = { formula: "1+2", result: 3 };
    const second = workbook.addWorksheet("对比");
    second.getCell("B2").value = "修补";
    const source = path.join(workspace, "软件平台修补重构对比.xlsm");
    await workbook.xlsx.writeFile(source);

    const result = await createSession({
      workspace,
      sessionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      agentSessionId: "desktop-pet-file-test",
      maximumFileSizeMB: 10,
      files: [{ path: source }],
    });
    const normalized = await fs.readFile(path.join(result.sessionPath, result.metadata.files[0].normalizedRelativePath), "utf8");
    assert.match(normalized, /工作表：中文工作表/);
    assert.match(normalized, /A1\tstring\t软件平台/);
    assert.match(normalized, /C3\tboolean\tTRUE/);
    assert.match(normalized, /D4\tdate\t2026-08-19T00:00:00\.000Z/);
    assert.match(normalized, /E5\tnumber\t3\t1\+2/);
    assert.match(normalized, /工作表：对比/);
    assert.equal(result.metadata.files[0].sheetCount, 2);
    assert.equal(result.relativePath, "DesktopPet-FileAnalysis/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
  });
});

test("extracts DOCX text and creates searchable chunks", async () => {
  await withWorkspace(async (workspace) => {
    const archive = new JSZip();
    archive.file("[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>`);
    archive.file("_rels/.rels", `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>`);
    archive.file("word/document.xml", `<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>哈妮丝 Windows 文件分析</w:t></w:r></w:p></w:body></w:document>`);
    archive.file("word/_rels/document.xml.rels", `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>`);
    const source = path.join(workspace, "说明.docx");
    await fs.writeFile(source, await archive.generateAsync({ type: "nodebuffer" }));
    const result = await createSession({ workspace, files: [{ path: source }] });
    const normalized = await fs.readFile(path.join(result.sessionPath, result.metadata.files[0].normalizedRelativePath), "utf8");
    assert.match(normalized, /哈妮丝 Windows 文件分析/);
    assert.equal(result.metadata.files[0].chunkCount, 1);
  });
});

test("extracts PDF text with page coordinates", async () => {
  await withWorkspace(async (workspace) => {
    const source = path.join(workspace, "sample.pdf");
    await fs.writeFile(source, makeTextPDF("Hello PDF"));
    const result = await createSession({ workspace, files: [{ path: source }] });
    const normalized = await fs.readFile(path.join(result.sessionPath, result.metadata.files[0].normalizedRelativePath), "utf8");
    assert.match(normalized, /PDF 第 1 页/);
    assert.match(normalized, /Hello PDF/);
    assert.equal(result.metadata.files[0].pageCount, 1);
  });
});

test("rejects corrupt spreadsheets without committing a session", async () => {
  await withWorkspace(async (workspace) => {
    const source = path.join(workspace, "损坏.xlsx");
    await fs.writeFile(source, "not a zip", "utf8");
    await assert.rejects(
      createSession({
        workspace,
        sessionId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        files: [{ path: source }],
      }),
      (error) => error instanceof AnalysisError && error.code === "invalid_spreadsheet",
    );
    await assert.rejects(fs.stat(path.join(workspace, "DesktopPet-FileAnalysis", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")));
  });
});
