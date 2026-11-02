---
type: decision
title: "release@gcp: a passed local gate replaces the rc preview, until something deploy-shaped changes"
description: The gated gcp release skips the rc preview, and goes straight to staging and going live, where the local gate passed for the app's tree and no deploy-shaped file changed since a release passed rc.
status: proposed
---

# The local gate replaces rc

The rc gate deploys a preview, builds the drivers in Cloud Build and runs them
against it: most of the release's wall time. The local pre-gate
([2026-11-01-release-concurrency](2026-11-01-release-concurrency.md)) already
runs the same drivers (`local-drivers.ts`) against the same app on a local
stack. What rc adds is what only the cloud has: the images as built there, the
service and job as rendered, the schema on Cloud SQL, the secrets and grants.
All of it is a function of a few files, and none of it changes with a change in
the app's screens, rules or content.

## The rule

A release (not `--preview`, `--dry-run`, `--snapshot` or `--no-gate`) skips rc
when both hold:

- its local gate passed for this exact tree, either found in the ledger
  (`~/.cache/pronto/local-gate/<app>/<key>`, stamped by `integrate@local` or by
  the app's full rehearsal) or run first, and
- its deploy-shaped key has a stamp (`~/.cache/pronto/rc-passed/<app>/<key>`),
  written only after a release that ran rc succeeded.

The deploy-shaped key hashes `release.cue`, `program.cue`, `cue.mod/module.cue`,
`.mise.toml`, `mise.lock`, `compose*.yaml` and `.bayt/compose*.yaml`, `infra/`,
and pronto's `gcp/*.nu` and `plugin.json`. (Sidecars are declared in
release.cue and compose; `program.cue` is taken whole, its release and target
sections not being separable.) Any change to one runs rc, and so does
`--rc`, `--no-local-gate` (nothing then stands in for it), and a first release.
The log says which path was taken and why. The skipped path is `--no-gate`'s
(stage, images built in Cloud Build, go live), after the local gate.

## Not covered

A change outside those files that behaves differently only in the cloud (an
image's base, a Cloud-only environment) is not seen until a release that runs
rc; `--rc` is for it. Stamps are per machine.

## Interface

`nu gcp/local-gate-key.nu <verb> <app dir>`: `key` and `deploy-key` print the
keys; `passed` and `rc-passed` print true or false; `stamp` records a local pass
for the tree as it stands (what an app's rehearsal calls after a full pass);
`rc-stamp` records an rc pass.
