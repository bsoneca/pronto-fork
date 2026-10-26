// testdata/machine's cases, each compiled by cue in a process of its own
// (program.cue says why), several at once. A case is named to cue as a field
// of a file on stdin: `-e` over the same unification evaluates otherwise.
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.11";
import { screenFindings } from "../omnishell/check-markup.ts";

type Expect = { value: unknown; equals?: unknown; has?: string[]; lacks?: string[]; order?: string[] };
type Listed = { admits: Record<string, { why?: string }>; refuses: Record<string, { why?: string; says: string[] }> };

const dir = new URL("./testdata/machine/", import.meta.url);
const files = [...Deno.readDirSync(dir)].map((e) => e.name).filter((n) => n.endsWith(".cue")).sort();

function listed(): Listed {
  // Fields named admits and refuses would shadow the package's.
  const expr = "{a: {for n, c in admits {(n): {if c.why != _|_ {why: c.why}}}}, r: {for n, c in refuses {(n): {says: c.says, if c.why != _|_ {why: c.why}}}}}";
  const out = new Deno.Command("cue", { args: ["export", ...files, "-e", expr, "--out", "json"], cwd: dir, stdout: "piped", stderr: "piped" }).outputSync();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  const { a, r } = JSON.parse(new TextDecoder().decode(out.stdout));
  return { admits: a, refuses: r };
}

// Each cue holds one compiled program; a slot per core bounds them.
let free = navigator.hardwareConcurrency;
const waiting: (() => void)[] = [];
async function compile(result: string): Promise<{ success: boolean; stdout: string; stderr: string }> {
  if (free > 0) free--;
  else await new Promise<void>((resume) => waiting.push(resume));
  try {
    const child = new Deno.Command("cue", { args: ["export", ...files, "-", "-e", "result", "--out", "json"], cwd: dir, stdin: "piped", stdout: "piped", stderr: "piped" }).spawn();
    const writer = child.stdin.getWriter();
    await writer.write(new TextEncoder().encode(`package machine\nresult: ${result}\n`));
    await writer.close();
    const out = await child.output();
    return { success: out.success, stdout: new TextDecoder().decode(out.stdout), stderr: new TextDecoder().decode(out.stderr) };
  } finally {
    const next = waiting.shift();
    if (next) next();
    else free++;
  }
}

function holds(name: string, e: Expect, why?: string): void {
  const msg = why ? `${name}: ${why}` : name;
  if ("equals" in e) assertEquals(e.value, e.equals, msg);
  const text = e.value as string;
  for (const s of e.has ?? []) assertStringIncludes(text, s, msg);
  for (const s of e.lacks ?? []) assert(!text.includes(s), `${msg}: holds ${JSON.stringify(s)}`);
  const at = (e.order ?? []).map((s) => text.indexOf(s));
  assert(at.every((i, n) => i >= 0 && (n === 0 || at[n - 1] < i)), `${msg}: not in order ${JSON.stringify(e.order)}`);
}

const cases = listed();
const label = (name: string) => JSON.stringify(name);

// The programs start compiling here, before the tests that await them.
const admitted = Object.fromEntries(Object.keys(cases.admits).map((name) => [name, compile(`admits[${label(name)}] & {program: _program}`)]));
const refused = Object.fromEntries(Object.keys(cases.refuses).map((name) => [name, compile(`refuses[${label(name)}].program & _program`)]));

async function expectations(name: string): Promise<Record<string, Expect>> {
  const res = await admitted[name];
  assert(res.success, `${name}: ${res.stderr}`);
  return JSON.parse(res.stdout).expect;
}

for (const [name, { why }] of Object.entries(cases.admits)) {
  Deno.test(name, async () => {
    for (const [key, e] of Object.entries(await expectations(name))) holds(`${name} ${key}`, e, why);
  });
}

for (const [name, { why, says }] of Object.entries(cases.refuses)) {
  Deno.test(name, async () => {
    const res = await refused[name];
    assert(!res.success, why ? `${name} was admitted: ${why}` : `${name} was admitted`);
    for (const s of says) assertStringIncludes(res.stderr, s, name);
  });
}

Deno.test("a pending discriminant's SQL default leaves omnishell's markup gate its finding", async () => {
  const schema = (await expectations("omitting SQL expression values preserves the markup gate for pending discriminants")).schema.value as Parameters<typeof screenFindings>[2];
  const html = '<ul data-live="challenge">' +
    '<template data-item data-when="kind=eq.note"><li>Note</li></template>' +
    '<template data-item data-when="kind=eq.link"><li>Link</li></template>';
  const findings = screenFindings("shell/screens/board.html", html + "</ul>", schema, new Set(), []);
  assertEquals(findings.length, 1);
  assertStringIncludes(findings[0].message, '"kind" is DB-defaulted');
  assertEquals(screenFindings("shell/screens/board.html", html + "<template data-item><li>Pending</li></template></ul>", schema, new Set(), []), []);
});
