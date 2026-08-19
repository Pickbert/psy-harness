import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import ExcelJS from "exceljs";
import mammoth from "mammoth";
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";

export const LIMITS = Object.freeze({
  maximumFileCount: 5,
  maximumBatchBytes: 100 * 1_048_576,
  maximumExtractedBytes: 100 * 1_048_576,
  chunkCharacterCount: 8_000,
  chunkOverlapCharacterCount: 500,
  retentionMilliseconds: 7 * 24 * 60 * 60 * 1_000,
});

const TEXT_EXTENSIONS = new Set([
  "txt", "md", "markdown", "csv", "json", "jsonl", "yaml", "yml", "xml", "html", "htm",
  "log", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts",
  "py", "pyi", "js", "jsx", "ts", "tsx", "vue", "svelte", "go", "rs", "rb", "php",
  "sh", "bash", "zsh", "fish", "sql", "css", "scss", "less", "toml", "ini", "conf",
  "properties", "gradle", "cmake", "dockerfile",
]);

const EXTENSIONLESS_TEXT_NAMES = new Set([
  "makefile", "dockerfile", "readme", "license", "gemfile", "podfile",
]);

export class AnalysisError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "AnalysisError";
    this.code = code;
  }
}

class TextAccumulator {
  #parts = [];
  #bytes = 0;
  #maximumBytes;

  constructor(maximumBytes = LIMITS.maximumExtractedBytes) {
    this.#maximumBytes = maximumBytes;
  }

  append(value) {
    const text = String(value);
    this.#bytes += Buffer.byteLength(text, "utf8");
    if (this.#bytes > this.#maximumBytes) {
      throw new AnalysisError("extracted_text_too_large", "这一批文件解析后的文字超过 100 MB，未创建不完整会话。");
    }
    this.#parts.push(text);
  }

  get byteCount() {
    return this.#bytes;
  }

  toString() {
    return this.#parts.join("");
  }
}

function emit(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function normalizeNewlines(value) {
  return value.replace(/\r\n?/g, "\n");
}

function escapeTSV(value) {
  return normalizeNewlines(String(value))
    .replaceAll("\\", "\\\\")
    .replaceAll("\t", "\\t")
    .replaceAll("\n", "\\n")
    .replaceAll("`", "\\`");
}

function escapeMarkdownHeading(value) {
  return normalizeNewlines(String(value)).replaceAll("\n", " ");
}

function safeStem(filename) {
  const base = path.parse(filename).name;
  const value = base
    .normalize("NFKD")
    .replace(/[^\p{L}\p{N}_-]+/gu, "-")
    .replace(/^-+|-+$/g, "");
  return value || "file";
}

function uniqueFilename(filename, usedNames) {
  const sanitized = filename.replaceAll(":", "-");
  const parsed = path.parse(sanitized);
  let candidate = sanitized;
  let suffix = 2;
  while (usedNames.has(candidate.toLocaleLowerCase("en-US"))) {
    candidate = `${parsed.name}-${suffix}${parsed.ext}`;
    suffix += 1;
  }
  usedNames.add(candidate.toLocaleLowerCase("en-US"));
  return candidate;
}

export function documentKind(filename) {
  const basename = path.basename(filename).toLocaleLowerCase("en-US");
  const extension = path.extname(basename).slice(1);
  if (extension === "pdf") return "pdf";
  if (extension === "docx") return "docx";
  if (extension === "xlsx" || extension === "xlsm") return "spreadsheet";
  if (TEXT_EXTENSIONS.has(extension) || EXTENSIONLESS_TEXT_NAMES.has(basename)) return "text";
  return null;
}

function displayKind(kind) {
  return { pdf: "PDF", docx: "DOCX", spreadsheet: "Excel", text: "文本" }[kind];
}

function decodeText(buffer, displayName) {
  const candidates = [];
  if (buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe) {
    candidates.push(["utf-16le", buffer.subarray(2)]);
  } else if (buffer.length >= 2 && buffer[0] === 0xfe && buffer[1] === 0xff) {
    candidates.push(["utf-16be", buffer.subarray(2)]);
  } else {
    candidates.push(["utf-8", buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf ? buffer.subarray(3) : buffer]);
    candidates.push(["utf-16le", buffer]);
    candidates.push(["utf-16be", buffer]);
  }
  for (const [encoding, bytes] of candidates) {
    try {
      const decoded = new TextDecoder(encoding, { fatal: true }).decode(bytes);
      const nulCount = [...decoded].reduce((count, character) => count + (character === "\0" ? 1 : 0), 0);
      if (decoded.length === 0 || nulCount / decoded.length < 0.01) return decoded;
    } catch (error) {
      if (!(error instanceof TypeError)) throw error;
    }
  }
  throw new AnalysisError("unreadable", `无法读取“${displayName}”。`);
}

async function extractText(sourcePath, displayName, maximumBytes) {
  const raw = decodeText(await fs.readFile(sourcePath), displayName);
  const text = normalizeNewlines(raw).trim();
  if (!text) throw new AnalysisError("empty_document", `“${displayName}”没有可分析的文字内容。`);
  const accumulator = new TextAccumulator(maximumBytes);
  accumulator.append(`# ${displayName}\n\n${text}`);
  return { text: accumulator.toString(), extractedBytes: accumulator.byteCount };
}

async function extractDOCX(sourcePath, displayName, maximumBytes) {
  try {
    const result = await mammoth.extractRawText({ buffer: await fs.readFile(sourcePath) });
    const text = normalizeNewlines(result.value).trim();
    if (!text) throw new AnalysisError("empty_document", `“${displayName}”没有可分析的文字内容。`);
    const accumulator = new TextAccumulator(maximumBytes);
    accumulator.append(`# ${displayName}\n\n${text}`);
    return { text: accumulator.toString(), extractedBytes: accumulator.byteCount };
  } catch (error) {
    if (error instanceof AnalysisError) throw error;
    throw new AnalysisError("unreadable", `无法读取“${displayName}”。`);
  }
}

async function extractPDF(sourcePath, displayName, maximumBytes, progress) {
  let document;
  let loadingTask;
  try {
    const data = new Uint8Array(await fs.readFile(sourcePath));
    loadingTask = getDocument({
      data,
      disableFontFace: true,
      isEvalSupported: false,
      useWorkerFetch: false,
      standardFontDataUrl: fileURLToPath(new URL("./node_modules/pdfjs-dist/standard_fonts/", import.meta.url)) + path.sep,
      wasmUrl: fileURLToPath(new URL("./node_modules/pdfjs-dist/wasm/", import.meta.url)) + path.sep,
    });
    document = await loadingTask.promise;
  } catch (error) {
    if (error?.name === "PasswordException") {
      throw new AnalysisError("locked_pdf", `“${displayName}”已加密或被密码保护，无法解析。`);
    }
    throw new AnalysisError("unreadable", `无法读取“${displayName}”。`);
  }

  const accumulator = new TextAccumulator(maximumBytes);
  accumulator.append(`# ${displayName}\n\n`);
  const pageCount = document.numPages;
  let hasText = false;
  try {
    for (let index = 1; index <= document.numPages; index += 1) {
      progress({ stage: "pdf_page", current: index, total: document.numPages });
      const page = await document.getPage(index);
      const content = await page.getTextContent();
      let pageText = "";
      for (const item of content.items) {
        if (!("str" in item)) continue;
        pageText += item.str;
        pageText += item.hasEOL ? "\n" : " ";
      }
      pageText = normalizeNewlines(pageText).replace(/[ \t]+\n/g, "\n").trim();
      if (pageText) hasText = true;
      if (index > 1) accumulator.append("\n\n---\n\n");
      accumulator.append(`## PDF 第 ${index} 页\n\n${pageText}`);
      page.cleanup();
    }
  } finally {
    await loadingTask.destroy();
  }
  if (!hasText) {
    throw new AnalysisError("scanned_pdf", `“${displayName}”没有可提取文字，扫描版 PDF 暂不支持 OCR。`);
  }
  return {
    text: accumulator.toString(),
    extractedBytes: accumulator.byteCount,
    pageCount,
  };
}

function excelValue(cell) {
  const value = cell.value;
  if (value === null || value === undefined) return { type: "empty", value: "", formula: "" };
  if (value instanceof Date) return { type: "date", value: value.toISOString(), formula: "" };
  if (typeof value === "boolean") return { type: "boolean", value: value ? "TRUE" : "FALSE", formula: "" };
  if (typeof value === "number") return { type: "number", value: String(value), formula: "" };
  if (typeof value === "string") return { type: "string", value, formula: "" };
  if (Array.isArray(value?.richText)) {
    return { type: "string", value: value.richText.map((item) => item.text ?? "").join(""), formula: "" };
  }
  if (typeof value?.formula === "string" || typeof value?.sharedFormula === "string") {
    const formula = value.formula ?? value.sharedFormula;
    const result = value.result;
    if (result instanceof Date) return { type: "date", value: result.toISOString(), formula };
    if (typeof result === "boolean") return { type: "boolean", value: result ? "TRUE" : "FALSE", formula };
    if (result && typeof result === "object" && "error" in result) {
      return { type: "error", value: String(result.error), formula };
    }
    return { type: typeof result === "number" ? "number" : "formula", value: result == null ? "" : String(result), formula };
  }
  if (typeof value?.error === "string") return { type: "error", value: value.error, formula: "" };
  if (typeof value?.text === "string") return { type: "string", value: value.text, formula: "" };
  return { type: "value", value: String(value), formula: "" };
}

async function extractSpreadsheet(sourcePath, displayName, maximumBytes, progress) {
  const bytes = await fs.readFile(sourcePath);
  if (bytes.subarray(0, 8).equals(Buffer.from([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]))) {
    throw new AnalysisError("protected_spreadsheet", `“${displayName}”已加密或被密码保护，无法解析。`);
  }
  const workbook = new ExcelJS.Workbook();
  try {
    await workbook.xlsx.load(bytes);
  } catch (error) {
    throw new AnalysisError("invalid_spreadsheet", `“${displayName}”不是有效的 XLSX/XLSM 工作簿，或文件已经损坏。`);
  }

  const accumulator = new TextAccumulator(maximumBytes);
  accumulator.append(`# ${displayName}\n\n`);
  accumulator.append("> XLSX/XLSM 只读提取；公式不会重新计算，value 列是文件内保存的缓存结果。宏不会执行。\n");
  let populatedCellCount = 0;
  workbook.worksheets.forEach((worksheet, worksheetIndex) => {
    progress({ stage: "spreadsheet_sheet", current: worksheetIndex + 1, total: workbook.worksheets.length, detail: worksheet.name });
    accumulator.append(`\n## 工作表：${escapeMarkdownHeading(worksheet.name)}\n\n`);
    if (worksheet.dimensions) accumulator.append(`- 使用区域：\`${worksheet.dimensions}\`\n\n`);
    accumulator.append("```tsv\ncell\ttype\tvalue\tformula\n");
    worksheet.eachRow({ includeEmpty: false }, (row) => {
      row.eachCell({ includeEmpty: false }, (cell) => {
        const rendered = excelValue(cell);
        if (!rendered.value && !rendered.formula) return;
        populatedCellCount += 1;
        accumulator.append(`${cell.address}\t${escapeTSV(rendered.type)}\t${escapeTSV(rendered.value)}\t${escapeTSV(rendered.formula)}\n`);
      });
    });
    accumulator.append("```\n");
  });
  if (workbook.worksheets.length === 0 || populatedCellCount === 0) {
    throw new AnalysisError("empty_spreadsheet", `“${displayName}”没有可分析的工作表单元格。`);
  }
  return {
    text: accumulator.toString(),
    extractedBytes: accumulator.byteCount,
    sheetCount: workbook.worksheets.length,
  };
}

function chunkText(text) {
  if (text.length <= LIMITS.chunkCharacterCount) {
    return [{ text, startLine: 1, endLine: 1 + (text.match(/\n/g)?.length ?? 0) }];
  }
  const chunks = [];
  let start = 0;
  let startLine = 1;
  while (start < text.length) {
    const proposedEnd = Math.min(text.length, start + LIMITS.chunkCharacterCount);
    let end = proposedEnd;
    if (proposedEnd < text.length) {
      const newline = text.lastIndexOf("\n", proposedEnd - 1);
      if (newline >= start + LIMITS.chunkCharacterCount / 2) end = newline + 1;
    }
    const value = text.slice(start, end);
    const lineBreaks = value.match(/\n/g)?.length ?? 0;
    const endLine = startLine + lineBreaks;
    chunks.push({ text: value, startLine, endLine });
    if (end >= text.length) break;
    const overlapStart = Math.max(start, end - LIMITS.chunkOverlapCharacterCount);
    const overlapLineBreaks = text.slice(overlapStart, end).match(/\n/g)?.length ?? 0;
    startLine = endLine - overlapLineBreaks;
    start = overlapStart > start ? overlapStart : end;
  }
  return chunks;
}

async function writeChunks(chunks, directory, displayName) {
  await fs.mkdir(directory, { recursive: true });
  const width = Math.max(3, String(chunks.length).length);
  await Promise.all(chunks.map(async (chunk, index) => {
    const number = String(index + 1).padStart(width, "0");
    const header = `# ${displayName} — 片段 ${index + 1}/${chunks.length}\n\n- 标准化文本行：${chunk.startLine}–${chunk.endLine}\n\n`;
    await fs.writeFile(path.join(directory, `${number}.md`), header + chunk.text, "utf8");
  }));
}

function manifest(metadata) {
  const lines = [
    "# 哈妮丝文件分析会话",
    "",
    "这是一份由用户主动拖入文件后建立的隔离副本。请优先使用 `glob`、`grep` 和 `read` 检索 `chunks/`，需要连续上下文时再读取 `normalized/`。不要猜测未解析的图片内容。",
    "",
    "## 文件",
  ];
  for (const file of metadata.files) {
    let details = `- **${file.displayName}**（${file.kind}，${file.sourceBytes} bytes，${file.chunkCount} 个片段`;
    if (file.pageCount != null) details += `，${file.pageCount} 页`;
    if (file.sheetCount != null) details += `，${file.sheetCount} 个工作表`;
    lines.push(`${details}）`);
    lines.push(`  - 标准化文本：\`${file.normalizedRelativePath}\``);
    lines.push(`  - 检索片段：\`${file.chunkDirectoryRelativePath}/*.md\``);
    lines.push(`  - 隔离副本：\`${file.sourceRelativePath}\``);
  }
  lines.push("");
  if (metadata.files.some((file) => file.kind === "spreadsheet")) {
    lines.push("Excel 仅提取工作表中的单元格值、公式文本与文件内缓存结果；不会重新计算公式，缓存值可能已经过期，也不会执行宏或还原图表、图片、数据透视表和视觉样式。");
    lines.push("");
  }
  lines.push("回答时尽量引用文件名、PDF 页码、Excel 工作表与单元格坐标或标准化文本中的行号。");
  return lines.join("\n");
}

async function validateRequest(request) {
  if (!request || typeof request !== "object" || typeof request.workspace !== "string" || !Array.isArray(request.files)) {
    throw new AnalysisError("invalid_request", "文件解析请求格式无效。");
  }
  if (request.files.length === 0) throw new AnalysisError("no_files", "没有检测到可分析的文件。");
  if (request.files.length > LIMITS.maximumFileCount) {
    throw new AnalysisError("too_many_files", `一次最多拖入 ${LIMITS.maximumFileCount} 个文件，当前有 ${request.files.length} 个。`);
  }
  const workspace = path.resolve(request.workspace);
  const workspaceStat = await fs.stat(workspace).catch(() => null);
  if (!workspaceStat?.isDirectory()) throw new AnalysisError("invalid_workspace", "Agent 工作目录不存在。");
  const maximumFileSizeMB = Number.isInteger(request.maximumFileSizeMB) && request.maximumFileSizeMB >= 1 && request.maximumFileSizeMB <= 100
    ? request.maximumFileSizeMB
    : 10;
  const maximumFileBytes = maximumFileSizeMB * 1_048_576;
  let batchBytes = 0;
  const files = [];
  for (const item of request.files) {
    if (!item || typeof item.path !== "string") throw new AnalysisError("invalid_request", "文件解析请求格式无效。");
    const sourcePath = path.resolve(item.path);
    const stat = await fs.lstat(sourcePath).catch(() => null);
    const displayName = path.basename(sourcePath);
    if (!stat?.isFile() || stat.isSymbolicLink()) {
      throw new AnalysisError("not_regular_file", `“${displayName}”不是普通文件，暂不支持文件夹或特殊文件。`);
    }
    const kind = documentKind(displayName);
    if (!kind) throw new AnalysisError("unsupported_type", `暂不支持“${displayName}”的文件格式。`);
    if (stat.size > maximumFileBytes) {
      throw new AnalysisError("file_too_large", `“${displayName}”超过单文件 ${maximumFileSizeMB} MB 限制；可在 DeepSeek 设置中修改。`);
    }
    batchBytes += stat.size;
    if (batchBytes > LIMITS.maximumBatchBytes) throw new AnalysisError("batch_too_large", "这一批文件总大小超过 100 MB。");
    files.push({ sourcePath, displayName, kind, bytes: stat.size });
  }
  return {
    workspace,
    files,
    sessionId: typeof request.sessionId === "string" && /^[0-9a-f-]{36}$/i.test(request.sessionId) ? request.sessionId.toLowerCase() : randomUUID(),
    agentSessionId: typeof request.agentSessionId === "string" && request.agentSessionId ? request.agentSessionId : `desktop-pet-file-${randomUUID()}`,
  };
}

export async function createSession(request, progress = () => {}) {
  const validated = await validateRequest(request);
  const root = path.join(validated.workspace, "DesktopPet-FileAnalysis");
  const staging = path.join(root, `.staging-${validated.sessionId}`);
  const destination = path.join(root, validated.sessionId);
  await fs.mkdir(root, { recursive: true });
  await fs.rm(staging, { recursive: true, force: true });
  await fs.mkdir(path.join(staging, "sources"), { recursive: true });
  await fs.mkdir(path.join(staging, "normalized"), { recursive: true });
  await fs.mkdir(path.join(staging, "chunks"), { recursive: true });

  try {
    const metadataFiles = [];
    const usedNames = new Set();
    let remainingExtractedBytes = LIMITS.maximumExtractedBytes;
    for (let index = 0; index < validated.files.length; index += 1) {
      const input = validated.files[index];
      progress({ stage: "file", current: index + 1, total: validated.files.length, detail: input.displayName });
      const copiedName = uniqueFilename(input.displayName, usedNames);
      const copiedPath = path.join(staging, "sources", copiedName);
      await fs.copyFile(input.sourcePath, copiedPath);
      const nestedProgress = (event) => progress({ ...event, file: input.displayName });
      let extracted;
      if (input.kind === "pdf") extracted = await extractPDF(copiedPath, input.displayName, remainingExtractedBytes, nestedProgress);
      else if (input.kind === "docx") extracted = await extractDOCX(copiedPath, input.displayName, remainingExtractedBytes);
      else if (input.kind === "spreadsheet") extracted = await extractSpreadsheet(copiedPath, input.displayName, remainingExtractedBytes, nestedProgress);
      else extracted = await extractText(copiedPath, input.displayName, remainingExtractedBytes);
      remainingExtractedBytes -= extracted.extractedBytes;

      const stem = `${String(index + 1).padStart(2, "0")}-${safeStem(input.displayName)}`;
      const normalizedRelativePath = `normalized/${stem}.md`;
      const chunkDirectoryRelativePath = `chunks/${stem}`;
      await fs.writeFile(path.join(staging, normalizedRelativePath), extracted.text, "utf8");
      const chunks = chunkText(extracted.text);
      await writeChunks(chunks, path.join(staging, chunkDirectoryRelativePath), input.displayName);
      metadataFiles.push({
        displayName: input.displayName,
        kind: input.kind,
        sourceRelativePath: `sources/${copiedName}`,
        normalizedRelativePath,
        chunkDirectoryRelativePath,
        sourceBytes: input.bytes,
        extractedBytes: extracted.extractedBytes,
        chunkCount: chunks.length,
        pageCount: extracted.pageCount ?? null,
        sheetCount: extracted.sheetCount ?? null,
      });
    }
    const createdAt = new Date();
    const metadata = {
      id: validated.sessionId,
      agentSessionID: validated.agentSessionId,
      createdAt: createdAt.toISOString(),
      expiresAt: new Date(createdAt.getTime() + LIMITS.retentionMilliseconds).toISOString(),
      files: metadataFiles,
    };
    await fs.writeFile(path.join(staging, ".desktop-pet-file-session.json"), JSON.stringify(metadata, null, 2), "utf8");
    await fs.writeFile(path.join(staging, "manifest.md"), manifest(metadata), "utf8");
    await fs.rename(staging, destination);
    return { metadata, sessionPath: destination, relativePath: `DesktopPet-FileAnalysis/${validated.sessionId}` };
  } catch (error) {
    await fs.rm(staging, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

async function readRequest() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
    if (Buffer.byteLength(input, "utf8") > 1_048_576) throw new AnalysisError("invalid_request", "文件解析请求过大。");
  }
  try {
    return JSON.parse(input);
  } catch (error) {
    throw new AnalysisError("invalid_request", "文件解析请求格式无效。");
  }
}

export async function runCLI() {
  try {
    const request = await readRequest();
    const result = await createSession(request, (event) => emit({ type: "progress", ...event }));
    emit({ type: "completed", ...result });
  } catch (error) {
    const normalized = error instanceof AnalysisError
      ? error
      : new AnalysisError("internal_error", error instanceof Error ? error.message : "本地文件解析失败。");
    emit({ type: "failed", code: normalized.code, message: normalized.message });
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await runCLI();
}
