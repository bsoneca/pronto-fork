# Native runtime releases

`release.nu` reads the generated Compose project and deploys the same application images for compute, Feldera, Conduit, Redis, transform, ticker, clock, blob services and the airlock. A native computation must select `DUCKSTREAM_ENGINE=feldera`; the adapter refuses snapshot execution. PostgreSQL, CRUD, authentication, Electric, Caddy and optional rendering remain the shared application stack. Metal reads no Compose project: its release runs `App.services` and `App.blobs` alone.

Compute state and publication transactions remain in PostgreSQL. The database enables durable WAL writes and provisions 128 replication slots and senders for per-table CDC. Feldera's embedded catalog, compiler and runner directories share a persistent volume at `/home/ubuntu/.feldera`. Compute's lake and blob storage receive volumes too. Redis uses AOF with synchronous fsync. Conduit stores connector positions in PostgreSQL instead of memory. Every added runtime deployment has one replica and a Recreate strategy: release replacement must not overlap CDC writers. This trades release availability for a single writer; node fencing and backups remain cluster responsibilities.

`App.runtimeStorage` sets each runtime volume's size (default `10Gi`). `App.runtimeResources` sets runtime requests and limits (default request `500m`/`1Gi`, limit `4`/`8Gi`); compiler-heavy applications need capacity planned from their real workloads. Stateful volumes survive a deployment replacement. Deleting the namespace or its claims destroys that protection.

The adapter replaces Compose database credentials and internal service tokens with Kubernetes Secret references. It signs the internal service JWT from the deployed PostgREST key through stdin and stores it in an application Secret. Compose database passwords and internal JWTs never enter rendered manifests. HTTP services needed by Caddy join Dapr; native CDC and data-plane connections use namespaced Service DNS. Network policies restrict pipeline ingress to the app and permit its database, DNS, mesh and telemetry connections.

## The airlock

An app that declares an effect gets mecha's airlock, its daprd and the bridges named for k8s, as pronto's release deploys them: the design, its walls, its probes and its Secrets are [[../../docs/release-targets#Effects on k8s]]'s, drawn in [`schema/airlock.cue`](schema/airlock.cue). What this fork adds on top of it:

- **A built database gets what an effect needs.** A database built before the app's first effect gets Graphile Worker's schema and the airlock's ledger from `<app>-initdb`, where upstream's release refuses it. Over an already-built database it runs the image's `*_graphile_worker.sql` once, in one transaction, when Graphile's schema is not there: the step is no replay (it inserts its first migration and creates its tables bare), and Graphile migrates its own schema at every worker start. `*_airlock.sql` is re-runnable, and is replayed with the other steps on every release, in one transaction, so a mecha upgrade's ledger reaches a built database; the ledger's job key follows it at once.
- **A tenant's release and a preview of an app with effects are refused** (`airlock-refusals`): a tenant's release drops every NetworkPolicy (`tenant-manifests`) and the walls with them, and a preview's airlock would perform real effects with the release's sinks' credentials.
- **Metal deploys no airlock**: its release names its services itself and runs no other, as for the rest of the compose project's.
- **Names follow the release's id and namespace** (`release.id`, `release.ns`), as every object of the fork's does; the two equal the app's name and namespace where the release is no preview and no tenant's.

Kind provisions the existing operator stack and local certificate. `--dry-run` prints manifests and `--snapshot` validates rendering without applying resources. These checks do not build images or prove a live cluster rollout. The release builds and pushes every selected runtime image, applies schema jobs before services, and waits up to fifteen minutes for native startup.

GCP deployment uses [[../../gcp/docs/index]]. The existing EKS and AKS profiles still only render manifests.
