import { XMLParser } from "fast-xml-parser";

const path = Bun.argv[2];
if (!path) process.exit(2);

const file = Bun.file(path);
const text = await file.text();
const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  parseTagValue: true,
  parseAttributeValue: true,
  isArray: (_name: string, path: string) => path === "rows.row",
});
const started = Bun.nanoseconds();
const document = parser.parse(text) as {
  rows: {
    row: Array<{
      id: number;
      userId: number;
      active: boolean;
      score: number;
      name: string;
      note?: string;
    }>;
  };
};
const elapsed = Math.max(1, Bun.nanoseconds() - started);

const rows = document.rows.row;
let checksum = 0;
for (const row of rows) {
  checksum += Number(row.id) + Number(row.userId) + String(row.name).length;
  if (row.active === true) checksum++;
  if (row.note !== undefined) checksum += String(row.note).length;
}
const bytes = file.size;
console.log(
  `bun_fast_xml_parser size=${bytes} records=${rows.length} nanos=${elapsed} ` +
  `mib_s=${Math.trunc(bytes * 1_000_000_000 / elapsed / 1_048_576)} ` +
  `records_s=${Math.trunc(rows.length * 1_000_000_000 / elapsed)} checksum=${checksum}`,
);
