import assert from 'node:assert/strict'
import { releasedIssuers, signInSecrets } from './edge-signin.ts'

const env = (values: Record<string, string>) => (name: string) => values[name]

Deno.test('an app naming no provider gives the Worker no secret', () => {
  assert.deepEqual(signInSecrets({}, env({ OIDC_GOOGLE_CLIENT_SECRET: 'stray' })), {})
})

Deno.test('a provider with no client id is refused, as compose refuses it', () => {
  assert.throws(() => releasedIssuers({ OIDC_PROVIDERS: 'google' }), { message: /OIDC_GOOGLE_CLIENT_ID is required/ })
})

Deno.test("a client secret is a publish's secret, and Google's own issuer needs one", () => {
  const vars = { OIDC_PROVIDERS: 'google', OIDC_GOOGLE_CLIENT_ID: 'c' }
  assert.deepEqual(signInSecrets(vars, env({ OIDC_GOOGLE_CLIENT_SECRET: 's' })), { OIDC_GOOGLE_CLIENT_SECRET: 's' })
  assert.throws(() => signInSecrets(vars, env({})), { message: /OIDC_GOOGLE_CLIENT_SECRET is required/ })
  // A broker in Google's place, a public client named by the door's origin.
  assert.deepEqual(signInSecrets({ ...vars, OIDC_GOOGLE_CLIENT_ID: 'origin', OIDC_GOOGLE_ISSUER: 'https://broker.example' }, env({})), {})
})

Deno.test("a release goes out only through an issuer a reader reaches: the local broker's is refused", () => {
  const vars = (issuer: string) => ({ OIDC_PROVIDERS: 'google', OIDC_GOOGLE_CLIENT_ID: 'origin', OIDC_GOOGLE_ISSUER: issuer })
  releasedIssuers(vars('https://id.bonkchess.com'))
  releasedIssuers({ OIDC_PROVIDERS: 'google', OIDC_GOOGLE_CLIENT_ID: 'app.apps.googleusercontent.com' })
  releasedIssuers({})
  for (const local of ['http://localhost:28443', 'https://localhost:28443', 'http://127.0.0.1:28443', 'https://id.localhost', 'http://id.example.com']) {
    assert.throws(() => releasedIssuers(vars(local)), /OIDC_GOOGLE_ISSUER is .* a local broker/, local)
  }
})
