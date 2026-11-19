import { strict as assert } from "node:assert";
import { oneHome, parseHeld, restateSql, type SeedData, seedKey, seedSql, vetHeld } from "./seed.ts";
import { cue, emitFiles, paymentProgram } from "./effects-fixtures.ts";

const team: SeedData["entities"][number] = {
  name: "Team",
  table: "team",
  columns: [
    { name: "id", type: "uuid" },
    { name: "name", type: "string" },
    { name: "rank", type: "int32" },
    { name: "active", type: "bool" },
    { name: "motto", type: "int64", from: "public.portable_int64_from_json" },
    { name: "rating", type: "double" },
    { name: "crest", type: "json" },
    { name: "ground", type: "geojson" },
  ],
  rows: [],
};

// A domain column reads CUE's json.Marshal spelling, escapes included, through
// its representation function; a base-typed column reads the SQL literal, and
// its CHECK judges it as the domain's function would have.
Deno.test("a row renders each column the way its type is held", () => {
  const sql = seedSql({ src: "seed.json", entities: [team] }, {
    Team: [{
      name: "D'Ávila\u2028", id: "06000000-0000-4000-8000-000000000001", active: true, rank: 3,
      motto: "9007199254740993\u2028", rating: 1.5, crest: { a: [1, "\u2028"] }, ground: { type: "Point", coordinates: [1, 2] },
    }],
  });
  assert.equal(
    sql,
    "INSERT INTO \"team\" (\"id\", \"name\", \"rank\", \"active\", \"motto\", \"rating\", \"crest\", \"ground\") VALUES (" +
      `'06000000-0000-4000-8000-000000000001', 'D''Ávila\u2028', 3, true, ` +
      `public.portable_int64_from_json('"9007199254740993\\u2028"'::json), 1.5, ` +
      `'{"a":[1,"\\u2028"]}'::json, '{"type":"Point","coordinates":[1,2]}'::json) ON CONFLICT (\"id\") DO NOTHING;\n`,
  );
});

// Regression: a seeded JSON null was the json value null while PostgREST stores
// one as SQL NULL, so a seeded row and an API write disagreed. A JSON null is
// absence, of a json column as of every other.
Deno.test("a json column's null is SQL NULL", () => {
  const sql = seedSql({ entities: [{ ...team, rows: [{ id: "a", crest: null }] }] }, {});
  assert.equal(sql, `INSERT INTO \"team\" (\"id\", \"crest\") VALUES ('a', NULL) ON CONFLICT (\"id\") DO NOTHING;\n`);
});

Deno.test("stated rows render without a seed file, and an entity with none renders nothing", () => {
  const stated = { ...team, rows: [{ id: "a" }] };
  const sql = seedSql({ entities: [{ ...team, name: "Empty", table: "empty" }, stated] }, {});
  assert.equal(sql, `INSERT INTO \"team\" (\"id\") VALUES ('a') ON CONFLICT (\"id\") DO NOTHING;\n`);
});

Deno.test("a held row is refused where nothing would judge or render it", () => {
  const data = { src: "seed.json", entities: [team] };
  assert.throws(() => seedSql(data, { Tab: [{ id: "a" }] }), /Tab is not a server entity/);
  assert.throws(() => seedSql(data, { Team: [{ id: "a", colour: "red" }] }), /Team\[0\]: colour is not a field/);
  // JSON.parse rounds it, so what reached the database would not be what the file says.
  assert.throws(() => seedSql(data, { Team: [{ id: "a", rank: 2 ** 53 }] }), /Team\[0\]\.rank/);
  assert.throws(() => seedSql({ src: "seed.json", entities: [{ ...team, rows: [{ id: "a" }] }] }, { Team: [{ id: "b" }] }), /one/);
});

Deno.test("an entity's rows have one home", () => {
  assert.throws(() => oneHome("seed.json", { Team: { seed: [{ id: "a" }] } }, { Team: [{ id: "b" }] }), /in the program and in seed\.json/);
  oneHome("seed.json", { Team: { seed: [] } }, { Team: [{ id: "b" }] });
});

Deno.test("a seed file is entity names to lists of rows", () => {
  assert.throws(() => parseHeld("seed.json", "[]"), /not an object/);
  assert.throws(() => parseHeld("seed.json", '{"Team": {}}'), /Team is not a list of rows/);
  assert.throws(() => parseHeld("seed.json", '{"Team": [1]}'), /Team is not a list of rows/);
  assert.throws(() => parseHeld("seed.json", "{"), /seed\.json/);
});

Deno.test("held rows are judged by cue against #Seed, then by the beyond checks", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/p.cue`, "package p\ncode: #Seed: {Team?: [...{rank?: int & <10, day?: string}]}\n");
    const entities = { Team: { fields: [{ name: "rank", type: "int32" as const }, { name: "day", type: "date" as const }] } };
    const vet = async (held: object) => {
      await Deno.writeTextFile(`${dir}/seed.json`, JSON.stringify(held));
      await vetHeld(dir, "seed.json", held as never, entities);
    };
    await vet({ Team: [{ rank: 3, day: "2026-02-28" }] });
    await assert.rejects(vet({ Team: [{ rank: 12 }] }), /a row does not satisfy its entity/);
    await assert.rejects(vet({ Team: [{ day: "2026-02-30" }] }), /Team\.seed\[0\]\.day: .*calendar date/);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("a held seed cannot bypass a machine's states, and changing those states invalidates its verdict", async () => {
  const dir = await Deno.makeTempDir({ dir: "." });
  const entities = { Payment: { fields: [{ name: "id", type: "uuid" as const }, { name: "status", type: "string" as const }] } };
  const source = (states: string) => `package test
import "bonisoft.org/plugins/pronto"
code: pronto.#App & {
  meta: {name: "held-machine", description: "test", ir: sha256: "", targets: [], clocks: [], decisions: {}, tests: {}}
  state: {
    entities: Payment: {table: "payment", durability: "server", fields: [{name: "id", type: "uuid", pk: true}, {name: "status", type: "string"}]}
    seed: src: "seed.json"
    mecha: rows: lifecycle: {entity: "payment", field: "status", initial: "pending", states: {${states}}}
  }
  capabilities: {hatches: {}, vendored: {}}
  surface: {screens: {}, handlers: {}, design: {colors: {primary: "#111111", secondary: "#555555", accent: "#0055aa", danger: "#aa0000", neutral: "#fafafa", surface: "#ffffff", border: "#dddddd", "surface-muted": "#efefef"}, dark: {primary: "#f5f5f5", secondary: "#aaaaaa", accent: "#66aaff", danger: "#ff6666", neutral: "#111111", surface: "#1a1a1a", border: "#333333", "surface-muted": "#242424"}, shell: nav: "topbar"}, flows: {}}
}
`;
  try {
    const bytes = new TextEncoder().encode('{"Payment":[{"id":"06000000-0000-4000-8000-000000000001","status":"settled"}]}');
    const held = parseHeld("seed.json", new TextDecoder().decode(bytes));
    await Deno.writeFile(`${dir}/seed.json`, bytes);
    await Deno.writeTextFile(`${dir}/program.cue`, source('pending: {}, settled: {type: "final"}'));
    await vetHeld(dir, "seed.json", held, entities);
    assert.equal(seedSql({ src: "seed.json", entities: [{name: "Payment", table: "payment", columns: [{name: "id", type: "uuid"}, {name: "status", type: "string"}], rows: []}] }, held),
      "INSERT INTO \"payment\" (\"id\", \"status\") VALUES ('06000000-0000-4000-8000-000000000001', 'settled') ON CONFLICT (\"id\") DO NOTHING;\n");
    const before = await seedKey(bytes, entities, "", { lifecycle: {entity: "payment", field: "status", states: {pending: {}, settled: {type: "final"}}} });
    const after = await seedKey(bytes, entities, "", { lifecycle: {entity: "payment", field: "status", states: {pending: {}}} });
    assert.notEqual(before, after);
    await Deno.writeTextFile(`${dir}/program.cue`, source("pending: {}"));
    await assert.rejects(vetHeld(dir, "seed.json", held, entities), /a row does not satisfy its entity/);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

const content: SeedData = {
  entities: [
    { name: "Lesson", table: "lesson", restate: true, columns: [{ name: "id", type: "uuid" }, { name: "title", type: "string" }], rows: [{ id: "a", title: "One" }, { id: "b", title: "O'Two" }] },
    { name: "Team", table: "team", columns: [{ name: "id", type: "uuid" }], rows: [{ id: "t" }] },
  ],
};
const hashOf = (sql: string) => sql.match(/sha256 = '([0-9a-f]{64})'/)![1];

Deno.test("a declared table is restated in one DO block, keyed by the hash of its rows; an undeclared one is left out", () => {
  const sql = restateSql(content, {});
  assert.match(sql, /TRUNCATE "lesson";/);
  assert.doesNotMatch(sql, /"team"/);
  assert.match(sql, /INSERT INTO "lesson" \("id", "title"\) VALUES \('b', 'O''Two'\)/);
  // Plain SQL: squawk and every runner read it, so no psql command.
  assert.doesNotMatch(sql, /^\\/m);
  assert.match(sql, /DO \$restate_[0-9a-f]{12}\$\nBEGIN\n/);
  assert.match(sql, /ON CONFLICT \(id\) DO UPDATE SET sha256/);
  assert.match(sql, /CREATE TABLE IF NOT EXISTS pronto_seed\.restated/);
  assert.doesNotMatch(sql, /public\./);
  // The hash moves with the rows and with nothing else.
  const other = restateSql({ entities: [{ ...content.entities[0], rows: [{ id: "a", title: "One" }] }, content.entities[1]] }, {});
  assert.notEqual(hashOf(sql), hashOf(other));
  const team = restateSql({ entities: [content.entities[0], { ...content.entities[1], rows: [{ id: "u" }] }] }, {});
  assert.equal(team, sql);
  // A newly declared table restates even when it holds no rows.
  const empty = { ...content.entities[1], name: "Empty", table: "empty", restate: true, rows: [] };
  assert.notEqual(hashOf(restateSql({ entities: [content.entities[0], empty] }, {})), hashOf(sql));
  // The first-creation seed is unchanged by the declaration.
  assert.equal(seedSql(content, {}).split("\n").length, 4);
  assert.throws(() => restateSql({ entities: [content.entities[1]] }, {}), /no entity declares/);
});

Deno.test("a restated table's parent is loaded before it", () => {
  const parent = { name: "Unit", table: "unit", restate: true, columns: [{ name: "id", type: "uuid" }], rows: [{ id: "u" }] };
  const child = { name: "Lesson", table: "lesson", restate: true, columns: [{ name: "id", type: "uuid" }, { name: "unit_id", type: "uuid", ref: "unit" }], rows: [{ id: "a", unit_id: "u" }] };
  restateSql({ entities: [parent, child] }, {});
  assert.throws(() => restateSql({ entities: [child, parent] }, {}), /Lesson\.unit_id references unit, which is restated after it/);
});

// The program emits 901 only for a declaration, and refuses it where something else writes the table.
// The fixture imports pronto by its monorepo path; the module here is the mirror's.
const here = (program: string) => program.replace("bonisoft.org/plugins/pronto", "github.com/bonisoft3/pronto");
const note = (extra = "") => `Note: {table: "note", durability: "server", ${extra} seed: [{id: "06000000-0000-4000-8000-000000000001"}], fields: [{name: "id", type: "uuid", pk: true}]}`;
const restated = (declare: boolean, entity = note(declare ? "seedRestated: true," : "")) => here(paymentProgram({ entity }));
const SEED = "services/database/migrations/900_seed.sql";
const RESTATE = "services/database/migrations/901_seed_restate.sql";
const exportOut = (program: string) => cue(["export", "-", "-e", "out", "--out", "json"], program);

Deno.test("a program emits the restate step only for a declared table", async () => {
  const on = await emitFiles(restated(true));
  const off = await emitFiles(restated(false));
  assert.ok(RESTATE in on);
  assert.ok(!(RESTATE in off));
  assert.equal(on[RESTATE].data.entities.find((e: { name: string }) => e.name === "Note").restate, true);
  // 900 carries the same rows; only the marker differs.
  const strip = (d: { entities: Record<string, unknown>[] }) => d.entities.map(({ restate: _, ...e }) => e);
  assert.deepEqual(strip(on[SEED].data), strip(off[SEED].data));
  assert.equal(on[SEED].text, off[SEED].text);
});

const refused = async (program: string, message: RegExp) => {
  const res = await exportOut(program);
  assert.equal(res.success, false);
  assert.match(res.stderr, message);
};

Deno.test("a restated table another writer makes is refused", async () => {
  const form = restated(true).replace("forms: []", `forms: [{id: "new-note", entity: "Note", action: "create", fields: []}]`);
  await refused(form, /entity Note is restated from its seed, but form board also writes it/);
  assert.equal((await exportOut(restated(true))).success, true);
});

Deno.test("a restated table that an unrestated one references is refused; a restated one may", async () => {
  const child = (restate: boolean) => `${note("seedRestated: true,")}\n      Page: {table: "page", durability: "server", ${restate ? "seedRestated: true," : ""} fields: [{name: "id", type: "uuid", pk: true}, {name: "note_id", type: "uuid", ref: "note"}]}`;
  await refused(restated(true, child(false)), /entity Note is restated from its seed, but entity Page field note_id references it/);
  assert.equal((await exportOut(restated(true, child(true)))).success, true);
});

Deno.test("a restated table a schedule emits into, a pipeline reads, or a client may write is refused", async () => {
  const tick = `Note: {table: "note", durability: "server", seedRestated: true, fields: list.Concat([pronto.#tickFields, [{name: "status", type: "text"}]])}\n      Done: {table: "done", durability: "live", fields: [{name: "id", type: "uuid", pk: true}]}`;
  await refused(
    restated(true, tick).replace('import "bonisoft.org/plugins/pronto"', 'import "list"\nimport "bonisoft.org/plugins/pronto"').replace('import "github.com/bonisoft3/pronto"', 'import "list"\nimport pronto "github.com/bonisoft3/pronto"') +
      `\napp: state: schedules: tick: {cron: "0 3 * * *", emits: {entity: "Note", values: {}}, done: {entity: "Done", filter: "id=eq.{id}"}}\n`,
    /entity Note is restated from its seed, but schedule tick emits into it/,
  );
  await refused(
    restated(true) + `\napp: state: pipelines: copy: {from: "Note", to: "Payment", key: "id"}\n`,
    /entity Note is restated from its seed, but pipeline copy reads it/,
  );
  await refused(restated(true, note(`seedRestated: true, access: {scope: "private", owner: "id"},`)), /its private access lets a client write it/);
  await refused(restated(true, note(`seedRestated: true, access: {scope: "public", write: true},`)), /its public access lets a client write it/);
  assert.equal((await exportOut(restated(true, note(`seedRestated: true, access: {scope: "public"},`)))).success, true);
  assert.equal((await exportOut(restated(true, note(`seedRestated: true, access: {scope: "internal"},`)))).success, true);
});
