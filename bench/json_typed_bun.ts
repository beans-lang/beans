const path = Bun.argv[2];
if (!path) process.exit(2);

const text = await Bun.file(path).text();
const started = Bun.nanoseconds();
const rows = JSON.parse(text) as Array<{
  id: number;
  userId: number;
  active: boolean;
  score: number;
  name: string;
  note: string | null;
}>;
const elapsed = Math.max(1, Bun.nanoseconds() - started);

let checksum = 0;
for (const row of rows) {
  checksum += row.id + row.userId + row.name.length;
  if (row.active) checksum++;
  if (row.note !== null) checksum += row.note.length;
}
const bytes = Buffer.byteLength(text);
console.log(
  `bun_json_parse size=${bytes} records=${rows.length} nanos=${elapsed} ` +
  `mib_s=${Math.trunc(bytes * 1_000_000_000 / elapsed / 1_048_576)} ` +
  `records_s=${Math.trunc(rows.length * 1_000_000_000 / elapsed)} checksum=${checksum}`,
);
