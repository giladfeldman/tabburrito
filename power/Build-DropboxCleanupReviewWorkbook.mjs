#!/usr/bin/env node

import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";


function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`Invalid argument near ${key ?? "end of command"}`);
    }
    result[key.slice(2)] = value;
  }
  for (const required of ["review-queue", "duplicate-groups", "renamed-summary", "output"]) {
    if (!result[required]) throw new Error(`Missing required --${required}`);
  }
  return result;
}


async function loadArtifactTool() {
  const modulePath = path.join(
    os.homedir(),
    ".cache",
    "codex-runtimes",
    "codex-primary-runtime",
    "dependencies",
    "node",
    "node_modules",
    "@oai",
    "artifact-tool",
    "dist",
    "artifact_tool.mjs",
  );
  await fs.access(modulePath);
  return import(pathToFileURL(modulePath).href);
}


function excelColumnName(index) {
  let value = index + 1;
  let result = "";
  while (value > 0) {
    const remainder = (value - 1) % 26;
    result = String.fromCharCode(65 + remainder) + result;
    value = Math.floor((value - 1) / 26);
  }
  return result;
}


async function importCsvSheet(workbook, filePath, sheetName) {
  let csvText = await fs.readFile(filePath, "utf8");
  csvText = csvText.replace(/^\uFEFF/, "");
  await workbook.fromCSV(csvText, { sheetName });
  csvText = "";
  return workbook.worksheets.getItem(sheetName);
}


function normalizeNumericColumns(sheet, rowCount, columnIndexes, chunkSize = 10000) {
  if (rowCount <= 1) return;
  for (const columnIndex of columnIndexes) {
    for (let startRow = 1; startRow < rowCount; startRow += chunkSize) {
      const count = Math.min(chunkSize, rowCount - startRow);
      const range = sheet.getRangeByIndexes(startRow, columnIndex, count, 1);
      const values = range.values.map(([value]) => {
        if (value === "" || value === null || value === undefined) return [null];
        const parsed = Number(value);
        return [Number.isFinite(parsed) ? parsed : value];
      });
      range.values = values;
    }
  }
}


function setColumnWidths(sheet, rowCount, widths) {
  for (const [columnIndexText, width] of Object.entries(widths)) {
    const columnIndex = Number(columnIndexText);
    const letter = excelColumnName(columnIndex);
    sheet.getRange(`${letter}1:${letter}${rowCount}`).format.columnWidth = width;
  }
}


function styleHeader(range, fill = "#16324F") {
  range.format = {
    fill,
    font: { bold: true, color: "#FFFFFF" },
    verticalAlignment: "center",
    wrapText: true,
    borders: { preset: "outside", style: "thin", color: "#0B1F33" },
  };
  range.format.rowHeight = 30;
}


function addReviewConditionalFormatting(sheet, lastRow) {
  const decisionRange = sheet.getRange(`T2:T${lastRow}`);
  decisionRange.conditionalFormats.add("containsText", {
    text: "KEEP",
    format: { fill: "#DCFCE7", font: { color: "#166534", bold: true } },
  });
  decisionRange.conditionalFormats.add("containsText", {
    text: "DELETE_DUPLICATE",
    format: { fill: "#FED7AA", font: { color: "#9A3412", bold: true } },
  });
  decisionRange.conditionalFormats.add("containsText", {
    text: "DELETE_UNIQUE_REVIEWED",
    format: { fill: "#FECACA", font: { color: "#991B1B", bold: true } },
  });
  decisionRange.conditionalFormats.add("containsText", {
    text: "EXCLUDE",
    format: { fill: "#E5E7EB", font: { color: "#374151" } },
  });
  sheet.getRange(`V2:V${lastRow}`).conditionalFormats.add("containsText", {
    text: "YES",
    format: { fill: "#FDE68A", font: { color: "#92400E", bold: true } },
  });
  sheet.getRange(`D2:D${lastRow}`).conditionalFormats.add("containsText", {
    text: "UNIQUE_IN_INVENTORY",
    format: { fill: "#FEE2E2", font: { color: "#7F1D1D" } },
  });
  sheet.getRange(`R2:R${lastRow}`).conditionalFormats.add("cellIs", {
    operator: "equal",
    formula: 1,
    format: { fill: "#FEF3C7", font: { color: "#92400E", bold: true } },
  });
}


function configureReviewQueue(sheet) {
  const used = sheet.getUsedRange();
  const rowCount = used.rowCount;
  normalizeNumericColumns(sheet, rowCount, [0, 8, 9, 10, 11, 17, 18]);
  sheet.showGridLines = false;
  sheet.freezePanes.freezeRows(1);
  sheet.freezePanes.freezeColumns(4);
  styleHeader(sheet.getRange("A1:V1"));
  sheet.getRange(`I2:I${rowCount}`).format.numberFormat = "#,##0";
  sheet.getRange(`J2:J${rowCount}`).format.numberFormat = "0.000";
  sheet.getRange(`L2:L${rowCount}`).format.numberFormat = "#,##0";
  sheet.getRange(`T2:T${rowCount}`).dataValidation = {
    rule: {
      type: "list",
      values: ["KEEP", "DELETE_DUPLICATE", "DELETE_UNIQUE_REVIEWED", "EXCLUDE"],
    },
  };
  sheet.getRange(`V2:V${rowCount}`).dataValidation = {
    rule: { type: "list", values: ["NO", "YES"] },
  };
  addReviewConditionalFormatting(sheet, rowCount);
  setColumnWidths(sheet, rowCount, {
    0: 10, 1: 25, 2: 31, 3: 22, 4: 72, 5: 52, 6: 34, 7: 11,
    8: 17, 9: 12, 10: 14, 11: 23, 12: 24, 13: 19, 14: 14, 15: 21,
    16: 18, 17: 15, 18: 15, 19: 29, 20: 42, 21: 12,
  });
  const table = sheet.tables.add(`A1:V${rowCount}`, true, "ReviewQueueTable");
  table.style = "TableStyleMedium2";
  table.showFilterButton = true;
  return rowCount;
}


function configureDuplicateGroups(sheet) {
  const used = sheet.getUsedRange();
  const rowCount = used.rowCount;
  normalizeNumericColumns(sheet, rowCount, [0, 2, 3, 4, 5, 6, 8]);
  sheet.showGridLines = false;
  sheet.freezePanes.freezeRows(1);
  styleHeader(sheet.getRange("A1:I1"), "#334155");
  sheet.getRange(`C2:C${rowCount}`).format.numberFormat = "#,##0";
  sheet.getRange(`D2:D${rowCount}`).format.numberFormat = "0.000";
  sheet.getRange(`E2:E${rowCount}`).format.numberFormat = "#,##0";
  sheet.getRange(`F2:F${rowCount}`).format.numberFormat = "#,##0";
  sheet.getRange(`G2:G${rowCount}`).format.numberFormat = "0.000";
  setColumnWidths(sheet, rowCount, { 0: 10, 1: 34, 2: 18, 3: 13, 4: 12, 5: 23, 6: 18, 7: 78, 8: 20 });
  const table = sheet.tables.add(`A1:I${rowCount}`, true, "DuplicateGroupsTable");
  table.style = "TableStyleMedium4";
  table.showFilterButton = true;
  return rowCount;
}


function configureRenamedFolders(sheet) {
  const used = sheet.getUsedRange();
  const rowCount = used.rowCount;
  normalizeNumericColumns(sheet, rowCount, [3, 4, 5, 6, 7, 8, 9, 10]);
  sheet.showGridLines = false;
  sheet.freezePanes.freezeRows(1);
  styleHeader(sheet.getRange("A1:L1"), "#475569");
  setColumnWidths(sheet, rowCount, {
    0: 36, 1: 64, 2: 64, 3: 15, 4: 21, 5: 21, 6: 20, 7: 23, 8: 23, 9: 22, 10: 23, 11: 25,
  });
  const table = sheet.tables.add(`A1:L${rowCount}`, true, "RenamedFoldersTable");
  table.style = "TableStyleMedium15";
  table.showFilterButton = true;
  return rowCount;
}


function buildSummary(sheet, reviewLastRow) {
  sheet.showGridLines = false;
  sheet.getRange("A1:H1").merge();
  sheet.getRange("A1").values = [["Dropbox cleanup review — safety-first cloud inventory"]];
  sheet.getRange("A1:H1").format = {
    fill: "#0B3558",
    font: { bold: true, color: "#FFFFFF", size: 18 },
    verticalAlignment: "center",
  };
  sheet.getRange("A1:H1").format.rowHeight = 38;
  sheet.getRange("A2:H2").merge();
  sheet.getRange("A2").values = [["Snapshot: 4 August 2026 • Workbook is a review tool only and cannot change Dropbox"]];
  sheet.getRange("A2:H2").format = {
    fill: "#DDEBF7",
    font: { color: "#16324F", italic: true },
    verticalAlignment: "center",
  };
  sheet.getRange("A2:H2").format.rowHeight = 25;

  sheet.getRange("A4:B4").values = [["Cloud snapshot", "Value"]];
  sheet.getRange("D4:E4").values = [["Your decisions (live)", "Value"]];
  sheet.getRange("G4:H4").values = [["Safety checks (live)", "Value"]];
  styleHeader(sheet.getRange("A4:B4"));
  styleHeader(sheet.getRange("D4:E4"), "#0F766E");
  styleHeader(sheet.getRange("G4:H4"), "#9A3412");

  sheet.getRange("A5:B13").values = [
    ["Files inventoried", 700593],
    ["Logical cloud size (GiB)", 1389169590916 / 1024 ** 3],
    ["Exact duplicate groups", 41005],
    ["Maximum duplicate reclaim (GiB)", 72338417415 / 1024 ** 3],
    ["Video files", 13829],
    ["Video library size (GiB)", 581.38],
    ["Files ≥100 MiB", 1808],
    ["Consolidated review paths", reviewLastRow - 1],
    ["Duplicate-video rows", 2156],
  ];
  sheet.getRange("D5:D10").values = [
    ["Rows marked for deletion"],
    ["Rows approved YES"],
    ["Approved deletion size (GiB)"],
    ["Approved duplicate size (GiB)"],
    ["Approved unique size (GiB)"],
    ["Decisions not yet approved"],
  ];
  const queue = "'Review Queue'";
  const decision = `${queue}!$T$2:$T$${reviewLastRow}`;
  const reason = `${queue}!$U$2:$U$${reviewLastRow}`;
  const approved = `${queue}!$V$2:$V$${reviewLastRow}`;
  const sizeBytes = `${queue}!$I$2:$I$${reviewLastRow}`;
  const shared = `${queue}!$R$2:$R$${reviewLastRow}`;
  sheet.getRange("E5:E10").formulas = [
    [`=COUNTIF(${decision},"DELETE_DUPLICATE")+COUNTIF(${decision},"DELETE_UNIQUE_REVIEWED")`],
    [`=COUNTIFS(${decision},"DELETE_DUPLICATE",${approved},"YES")+COUNTIFS(${decision},"DELETE_UNIQUE_REVIEWED",${approved},"YES")`],
    [`=(SUMIFS(${sizeBytes},${decision},"DELETE_DUPLICATE",${approved},"YES")+SUMIFS(${sizeBytes},${decision},"DELETE_UNIQUE_REVIEWED",${approved},"YES"))/1073741824`],
    [`=SUMIFS(${sizeBytes},${decision},"DELETE_DUPLICATE",${approved},"YES")/1073741824`],
    [`=SUMIFS(${sizeBytes},${decision},"DELETE_UNIQUE_REVIEWED",${approved},"YES")/1073741824`],
    ["=E5-E6"],
  ];
  sheet.getRange("G5:G9").values = [
    ["Approved rows in shared folders"],
    ["Approved unique rows without reason"],
    ["Approved duplicate rows"],
    ["Immediate review status"],
    ["Dropbox changes performed"],
  ];
  sheet.getRange("H5:H9").formulas = [
    [`=COUNTIFS(${shared},1,${approved},"YES",${decision},"DELETE_DUPLICATE")+COUNTIFS(${shared},1,${approved},"YES",${decision},"DELETE_UNIQUE_REVIEWED")`],
    [`=COUNTIFS(${decision},"DELETE_UNIQUE_REVIEWED",${approved},"YES",${reason},"")`],
    [`=COUNTIFS(${decision},"DELETE_DUPLICATE",${approved},"YES")`],
    ["=IF(SUM(H5:H6)=0,\"NO IMMEDIATE FLAGS\",\"REVIEW FLAGS\")"],
    ["=\"NONE — REVIEW WORKBOOK ONLY\""],
  ];

  sheet.getRange("A16:C16").values = [["Candidate category", "Files", "Logical GiB"]];
  styleHeader(sheet.getRange("A16:C16"), "#4F46E5");
  const categories = [
    "EXACT_DUPLICATE_VIDEO",
    "EXACT_DUPLICATE_OTHER",
    "UNIQUE_LARGE_VIDEO",
    "UNIQUE_VIDEO",
    "UNIQUE_LARGE_OTHER",
  ];
  sheet.getRange("A17:A21").values = categories.map((value) => [value]);
  const categoryRange = `${queue}!$B$2:$B$${reviewLastRow}`;
  for (let row = 17; row <= 21; row += 1) {
    sheet.getRange(`B${row}`).formulas = [[`=COUNTIF(${categoryRange},A${row})`]];
    sheet.getRange(`C${row}`).formulas = [[`=SUMIF(${categoryRange},A${row},${sizeBytes})/1073741824`]];
  }

  sheet.getRange("A24:H24").merge();
  sheet.getRange("A24").values = [["How to use the review queue"]];
  styleHeader(sheet.getRange("A24:H24"), "#334155");
  sheet.getRange("A25:H28").merge(true);
  sheet.getRange("A25:A28").values = [
    ["1. Filter Review Queue by Extension (.mp4, .mov, etc.), SizeGiB, CandidateCategory, or TopLevelFolder."],
    ["2. For an exact duplicate, identify the copy to KEEP before marking another DELETE_DUPLICATE."],
    ["3. Unique files require DELETE_UNIQUE_REVIEWED, an explanation in Reason, and a separate YES approval."],
    ["4. Send the reviewed workbook back for a second cloud-state check, dry run, and a tiny recoverable pilot."],
  ];
  sheet.getRange("A25:H28").format = {
    fill: "#F8FAFC",
    font: { color: "#334155" },
    wrapText: true,
    borders: { preset: "outside", style: "thin", color: "#CBD5E1" },
  };
  sheet.getRange("A25:H28").format.rowHeight = 25;

  sheet.getRange("B5:B13").format.numberFormat = "#,##0.00";
  sheet.getRange("B5:B5").format.numberFormat = "#,##0";
  sheet.getRange("B7:B7").format.numberFormat = "#,##0";
  sheet.getRange("B9:B9").format.numberFormat = "#,##0";
  sheet.getRange("B11:B13").format.numberFormat = "#,##0";
  sheet.getRange("E5:E6").format.numberFormat = "#,##0";
  sheet.getRange("E7:E9").format.numberFormat = "0.000";
  sheet.getRange("E10:E10").format.numberFormat = "#,##0";
  sheet.getRange("H5:H7").format.numberFormat = "#,##0";
  sheet.getRange("B17:B21").format.numberFormat = "#,##0";
  sheet.getRange("C17:C21").format.numberFormat = "0.000";
  sheet.getRange("H8:H9").format = { fill: "#FFF7ED", font: { bold: true, color: "#9A3412" }, wrapText: true };
  sheet.getRange("A4:H13").format.borders = { preset: "inside", style: "thin", color: "#E2E8F0" };
  setColumnWidths(sheet, 28, { 0: 33, 1: 17, 2: 4, 3: 31, 4: 17, 5: 4, 6: 35, 7: 25 });
  sheet.freezePanes.freezeRows(2);
}


function buildMediaSummary(sheet, reviewLastRow, videoExtensions) {
  sheet.showGridLines = false;
  sheet.getRange("A1:F1").merge();
  sheet.getRange("A1").values = [["Video inventory by extension — live from Review Queue"]];
  sheet.getRange("A1:F1").format = {
    fill: "#0F766E",
    font: { bold: true, color: "#FFFFFF", size: 16 },
    verticalAlignment: "center",
  };
  sheet.getRange("A1:F1").format.rowHeight = 34;
  sheet.getRange("A2:F2").merge();
  sheet.getRange("A2").values = [["Filter the authoritative Review Queue to make decisions; this sheet is a live summary only."]];
  sheet.getRange("A2:F2").format = { fill: "#D1FAE5", font: { color: "#065F46", italic: true } };
  sheet.getRange("A3:F3").values = [["Extension", "Files", "Logical GiB", "Exact duplicate files", "Unique files", "Approved deletion GiB"]];
  styleHeader(sheet.getRange("A3:F3"), "#115E59");
  sheet.getRange(`A4:A${3 + videoExtensions.length}`).values = videoExtensions.map((value) => [value]);
  const queue = "'Review Queue'";
  const extension = `${queue}!$H$2:$H$${reviewLastRow}`;
  const duplicateStatus = `${queue}!$D$2:$D$${reviewLastRow}`;
  const sizeBytes = `${queue}!$I$2:$I$${reviewLastRow}`;
  const decision = `${queue}!$T$2:$T$${reviewLastRow}`;
  const approved = `${queue}!$V$2:$V$${reviewLastRow}`;
  for (let row = 4; row <= 3 + videoExtensions.length; row += 1) {
    sheet.getRange(`B${row}:F${row}`).formulas = [[
      `=COUNTIF(${extension},A${row})`,
      `=SUMIF(${extension},A${row},${sizeBytes})/1073741824`,
      `=COUNTIFS(${extension},A${row},${duplicateStatus},"EXACT_DUPLICATE")`,
      `=COUNTIFS(${extension},A${row},${duplicateStatus},"UNIQUE_IN_INVENTORY")`,
      `=(SUMIFS(${sizeBytes},${extension},A${row},${decision},"DELETE_DUPLICATE",${approved},"YES")+SUMIFS(${sizeBytes},${extension},A${row},${decision},"DELETE_UNIQUE_REVIEWED",${approved},"YES"))/1073741824`,
    ]];
  }
  const totalRow = 4 + videoExtensions.length;
  sheet.getRange(`A${totalRow}:F${totalRow}`).values = [["TOTAL", null, null, null, null, null]];
  sheet.getRange(`B${totalRow}:F${totalRow}`).formulas = [[
    `=SUM(B4:B${totalRow - 1})`,
    `=SUM(C4:C${totalRow - 1})`,
    `=SUM(D4:D${totalRow - 1})`,
    `=SUM(E4:E${totalRow - 1})`,
    `=SUM(F4:F${totalRow - 1})`,
  ]];
  sheet.getRange(`A${totalRow}:F${totalRow}`).format = {
    fill: "#CCFBF1",
    font: { bold: true, color: "#134E4A" },
    borders: { preset: "doubleBottom", style: "medium", color: "#0F766E" },
  };
  sheet.getRange(`B4:B${totalRow}`).format.numberFormat = "#,##0";
  sheet.getRange(`C4:C${totalRow}`).format.numberFormat = "0.000";
  sheet.getRange(`D4:E${totalRow}`).format.numberFormat = "#,##0";
  sheet.getRange(`F4:F${totalRow}`).format.numberFormat = "0.000";
  setColumnWidths(sheet, totalRow, { 0: 15, 1: 14, 2: 16, 3: 24, 4: 16, 5: 24 });
  const table = sheet.tables.add(`A3:F${totalRow - 1}`, true, "MediaExtensionTable");
  table.style = "TableStyleMedium9";
  table.showFilterButton = true;
  sheet.freezePanes.freezeRows(3);
  return totalRow;
}


function buildInstructions(sheet, databasePath) {
  sheet.showGridLines = false;
  sheet.getRange("A1:H1").merge();
  sheet.getRange("A1").values = [["Safety instructions — read before marking any deletion"]];
  sheet.getRange("A1:H1").format = {
    fill: "#7F1D1D",
    font: { bold: true, color: "#FFFFFF", size: 17 },
    verticalAlignment: "center",
  };
  sheet.getRange("A1:H1").format.rowHeight = 38;
  sheet.getRange("A3:B3").values = [["Topic", "Rule"]];
  styleHeader(sheet.getRange("A3:B3"), "#334155");
  const rows = [
    ["Authority", "Only decisions entered on Review Queue will be considered later. Other sheets are summaries."],
    ["KEEP", "Use when the path must remain in Dropbox."],
    ["DELETE_DUPLICATE", "Use only for EXACT_DUPLICATE rows after identifying at least one verified survivor in the same GroupId."],
    ["DELETE_UNIQUE_REVIEWED", "High risk. Use only after deliberately reviewing the unique file; Reason is mandatory."],
    ["EXCLUDE", "Remove the item from this cleanup exercise without deleting it."],
    ["Approved", "A decision is inert until Approved is changed from NO to YES. The later executor will still recheck cloud metadata."],
    ["Shared folders", "Treat InSharedFolder=1 as exceptional. Deleting may affect other people or may be blocked by permissions."],
    ["Large/video review", "Filter Extension, SizeGiB, CandidateCategory, TopLevelFolder, and ServerModified. Numeric size columns sort correctly."],
    ["Exact duplicates", "Dropbox content hash plus identical size establishes byte-identical content, not that both paths have the same meaning."],
    ["Unique files", "UNIQUE_IN_INVENTORY means no byte-identical cloud copy was found in this snapshot."],
    ["What happens next", "Return the reviewed workbook. A separate write-scoped app will create a dry-run manifest, revalidate every path/revision/hash, and pilot a tiny recoverable batch."],
    ["Current capability", "This workbook and the scanner cannot upload, move, rename, or delete Dropbox content."],
    ["Inventory database", databasePath],
  ];
  sheet.getRange(`A4:B${3 + rows.length}`).values = rows;
  sheet.getRange(`A4:A${3 + rows.length}`).format = { fill: "#F1F5F9", font: { bold: true, color: "#334155" }, wrapText: true };
  sheet.getRange(`B4:B${3 + rows.length}`).format = { wrapText: true, verticalAlignment: "top" };
  sheet.getRange(`A3:B${3 + rows.length}`).format.borders = { preset: "inside", style: "thin", color: "#CBD5E1" };
  setColumnWidths(sheet, 3 + rows.length, { 0: 28, 1: 115 });
  sheet.getRange(`A4:B${3 + rows.length}`).format.rowHeight = 34;
  sheet.freezePanes.freezeRows(3);
}


async function savePreview(workbook, outputDirectory, sheetName, range, fileName) {
  const preview = await workbook.render({ sheetName, range, format: "png", scale: 1 });
  await fs.writeFile(path.join(outputDirectory, fileName), new Uint8Array(await preview.arrayBuffer()));
}


const args = parseArgs(process.argv.slice(2));
const reviewQueuePath = path.resolve(args["review-queue"]);
const duplicateGroupsPath = path.resolve(args["duplicate-groups"]);
const renamedSummaryPath = path.resolve(args["renamed-summary"]);
const outputPath = path.resolve(args.output);
for (const input of [reviewQueuePath, duplicateGroupsPath, renamedSummaryPath]) await fs.access(input);
await fs.mkdir(path.dirname(outputPath), { recursive: true });

const { SpreadsheetFile, Workbook } = await loadArtifactTool();
const workbook = Workbook.create();
const summary = workbook.worksheets.add("Summary");
const reviewQueue = await importCsvSheet(workbook, reviewQueuePath, "Review Queue");
const duplicateGroups = await importCsvSheet(workbook, duplicateGroupsPath, "Duplicate Groups");
const renamedFolders = await importCsvSheet(workbook, renamedSummaryPath, "Renamed Folders");
const mediaSummary = workbook.worksheets.add("Media Summary");
const instructions = workbook.worksheets.add("Instructions");

const reviewRowCount = configureReviewQueue(reviewQueue);
const duplicateGroupRowCount = configureDuplicateGroups(duplicateGroups);
const renamedRowCount = configureRenamedFolders(renamedFolders);
buildSummary(summary, reviewRowCount);
const videoExtensions = [
  ".3gp", ".asf", ".avi", ".divx", ".dv", ".f4v", ".flv", ".hevc", ".m2ts", ".m4v",
  ".mkv", ".mod", ".mov", ".mp4", ".mpeg", ".mpg", ".mts", ".mxf", ".ogv", ".qt",
  ".rm", ".rmvb", ".ts", ".vob", ".webm", ".wmv",
];
const mediaLastRow = buildMediaSummary(mediaSummary, reviewRowCount, videoExtensions);
buildInstructions(instructions, args.database ?? "Dropbox-cloud-file-inventory_2026-08-04_124136.sqlite");

const formulaValues = [
  ...summary.getRange("A1:H28").values.flat(),
  ...mediaSummary.getRange(`A1:F${mediaLastRow}`).values.flat(),
].map((value) => String(value ?? ""));
const formulaErrors = formulaValues.filter((value) => /#(?:REF!|DIV\/0!|VALUE!|NAME\?|N\/A)/i.test(value));
if (formulaErrors.length > 0) {
  throw new Error(`Formula error values detected: ${[...new Set(formulaErrors)].join(", ")}`);
}

const inspection = await workbook.inspect({
  kind: "workbook,sheet,table",
  maxChars: 12000,
  tableMaxRows: 5,
  tableMaxCols: 8,
  tableMaxCellChars: 80,
});
await fs.writeFile(path.join(path.dirname(outputPath), "Dropbox-cleanup-review-workbook-inspection.ndjson"), inspection.ndjson, "utf8");

await savePreview(workbook, path.dirname(outputPath), "Summary", "A1:H28", "preview-summary.png");
await savePreview(workbook, path.dirname(outputPath), "Review Queue", "A1:V18", "preview-review-queue.png");
await savePreview(workbook, path.dirname(outputPath), "Duplicate Groups", "A1:I20", "preview-duplicate-groups.png");
await savePreview(workbook, path.dirname(outputPath), "Renamed Folders", `A1:L${Math.min(renamedRowCount, 10)}`, "preview-renamed-folders.png");
await savePreview(workbook, path.dirname(outputPath), "Media Summary", `A1:F${mediaLastRow}`, "preview-media-summary.png");
await savePreview(workbook, path.dirname(outputPath), "Instructions", "A1:B16", "preview-instructions.png");

const exported = await SpreadsheetFile.exportXlsx(workbook);
await exported.save(outputPath);

console.log(JSON.stringify({
  output: outputPath,
  reviewQueueRows: reviewRowCount - 1,
  duplicateGroups: duplicateGroupRowCount - 1,
  renamedChecks: renamedRowCount - 1,
  formulaErrors: formulaErrors.length,
  previews: 6,
}, null, 2));
