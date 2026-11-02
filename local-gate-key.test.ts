// The ledgers of release@gcp's gates (gcp/local-gate-key.nu): a stamp is found for the tree it
// was made for, and only a deploy-shaped file moves the rc key.

import { assertEquals } from "jsr:@std/assert@1.0.11"

const script = new URL("./gcp/local-gate-key.nu", import.meta.url).pathname

const nu = async (home: string, ...args: string[]) => {
  const out = await new Deno.Command("nu", { args: [script, ...args], env: { HOME: home }, stdout: "piped", stderr: "piped" }).output()
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr))
  return new TextDecoder().decode(out.stdout).trim()
}

Deno.test("a stamp holds for its tree alone; the rc stamp moves only with a deploy-shaped file", async () => {
  const home = await Deno.makeTempDir()
  const repo = await Deno.makeTempDir()
  const app = `${repo}/app`
  await Deno.mkdir(app)
  await Deno.writeTextFile(`${app}/release.cue`, "a")
  await Deno.writeTextFile(`${app}/page.ts`, "b")
  await new Deno.Command("git", { args: ["init", "-q"], cwd: repo }).output()
  assertEquals(await nu(home, "passed", app), "false")
  assertEquals(await nu(home, "rc-passed", app), "false")
  await nu(home, "stamp", app)
  await nu(home, "rc-stamp", app)
  assertEquals([await nu(home, "passed", app), await nu(home, "rc-passed", app)], ["true", "true"])
  await Deno.writeTextFile(`${app}/page.ts`, "c")
  assertEquals([await nu(home, "passed", app), await nu(home, "rc-passed", app)], ["false", "true"])
  await Deno.writeTextFile(`${app}/release.cue`, "d")
  assertEquals(await nu(home, "rc-passed", app), "false")
})
