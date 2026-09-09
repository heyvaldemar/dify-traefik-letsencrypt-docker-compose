# Dify + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/dify-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/dify-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository deploys Dify (an open-source platform for building LLM applications, agents and workflows) behind Traefik with automatic Let's Encrypt TLS, backed by PostgreSQL, Redis and Weaviate, with scheduled backups of both databases and the application data, and companion restore scripts.

Dify is eighteen containers. Most of what this template does is make that number stop mattering: one hostname instead of nine URLs, thirteen images pinned by digest instead of five moving tags, twelve secrets that are yours instead of published defaults, and a deploy job that proves the stack works before a release is cut.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/dify-traefik-letsencrypt-docker-compose
cd dify-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create dify-network

# 3. Copy the environment template and fill in the REQUIRED block
cp .env.example .env
$EDITOR .env
# ^ Fourteen values, each with the command that generates it written above it.

# 4. Deploy
docker compose -f dify-traefik-letsencrypt-docker-compose.yml -p dify up -d
```

The api container runs the database migrations at start, under a Redis lock so that only one of the four containers that try actually does it. On a small host the console answers within three to five minutes of the first `up`.

### What success looks like

```bash
docker compose -f dify-traefik-letsencrypt-docker-compose.yml -p dify ps
curl -sk "https://${DIFY_HOSTNAME}/console/api/setup"
# Expected on a fresh deployment: {"step":"not_started","setup_at":null}
```

Then open `https://${DIFY_HOSTNAME}/install` and create the administrator account.

`ps` shows seventeen services running and `init_permissions` exited: it is a one-shot that gives the storage volume to the uid the api runs as, leaves a flag file, and is a no-op on every later start.

### Common first-deploy issues

- **`agent_backend` restarts in a loop.** `DIFY_AGENT_SERVER_SECRET_KEY` is not free-form: it must be unpadded base64url that decodes to exactly 32 bytes. Use the command in `.env.example`.
- **The console answers 404 through Traefik.** Dify's nginx did not start. It renders its config at boot, so anything that stops it writing `/etc/nginx/conf.d/default.conf` leaves it listening on nothing while its log looks normal.
- **A variable did not take effect.** Check whether the compose file owns it: `.env.example` says so on the line where the value would have been. Secrets and the nine URLs are set by the compose file, from the prefixed variables at the top.
- **Cert issuance fails.** DNS has not propagated, or port 80 is not reachable from the internet.
- **Networks not found.** Step 2 was skipped.

## One hostname, not nine URLs

Dify reads nine separate URL variables — the console API, the console web, the service API, the app API, the app web, the files endpoint, the trigger URL, the endpoint template and the socket URL. Upstream ships them all empty, and empty means "guess from the request", which is exactly what breaks behind a reverse proxy: e-mail links point at localhost, the Human Input node in a workflow has nowhere to send anybody, and signed file URLs are signed for the wrong origin.

Set `DIFY_HOSTNAME` and this compose file derives all nine. The two that must stay internal, the server-side console API and the internal files URL, keep their internal addresses.

## Secrets

Dify's published compose file carries working defaults for its secrets: a database password, a Redis password, a sandbox key, a plugin daemon key, an inner API key, an agent token whose own name says "for-dev-only", and a Weaviate API key. They are defaults, so they are on the internet, and a deployment that keeps them is a deployment anyone can read the source to break into.

Every one of them is required here. The stack refuses to start until it has a value, `.env.example` carries the command that generates each one, and none of the published defaults survives anywhere in this repository. Two of them are shared secrets between containers — the sandbox key and the plugin inner API key — and both sides read the same variable, so they cannot drift apart.

## Dify's own nginx is kept, with Traefik in front

Dify ships a reverse proxy carrying an eleven-entry routing table: `/console/api`, `/api`, `/v1`, `/openapi`, `/files`, `/mcp` and `/triggers` to the api, `/socket.io/` to the websocket worker, `/explore` and everything else to the web frontend, and `/e/` to the plugin daemon with the public webhook URL in a request header.

Reproducing that in Traefik labels would be a fork of Dify's routing that drifts on every release, and one of its rules cannot be reproduced at all: the `Dify-Hook-Url` header is built per request from the scheme, host and path, which a static label cannot express. So Traefik terminates TLS and forwards to nginx, and Dify's routing stays Dify's business.

That means this repository carries ten of Dify's configuration files, under `nginx/` and `ssrf_proxy/`. Vendored files rot silently, so CI reads each one from Dify at the exact version this template pins and fails the run if any of them differs. A routing change upstream becomes a red build here instead of a deployment that quietly serves the old table.

## The sandbox is contained, and CI checks that it still is

Dify runs code that users of the platform write, in a sandbox container. That container sits on an internal Docker network with no route to anything, and reaches the internet only through a squid proxy that sits on both networks with Dify's own rules loaded. Putting it on the routable network instead would look identical from outside and would hand anyone with an account a path to the host's metadata service.

The deploy job asserts the containment directly: it reads the sandbox container's networks and fails if the routable one is among them.

## Updating

`./update.sh` moves this checkout to the latest release tag — a combination this repository's CI has booted, upgraded from the previous release on the same volumes, and smoke-tested — and then runs `docker compose up -d`. It refuses to cross a major version unattended, refuses to run over local changes, and names any variable that became required since your version before anything has moved. `./update.sh --dry-run` says what would happen.

Two cautions Dify's own release notes are explicit about, and which no template can do for you:

- **A deployment upgraded from a Dify older than 1.15.0** may still owe a one-time model-type migration that `flask db upgrade` does not include. Dify has flagged it in every release since. Run `docker compose -p dify exec -T api flask data-migrate legacy-model-types --apply` after upgrading, and back the database up first.
- **Dify renames variables between releases.** 1.17.0 renamed `EDITION` to `DEPLOYMENT_EDITION` and removed three more. `update.sh` names what became required; what was renamed is in the release notes.

## Supply chain trust

Thirteen images pinned to `tag@sha256:<digest>` as interpolation defaults in the compose `x-images` block. `git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

Five of them are pinned to a version where Dify's own compose file says `:latest` — busybox, nginx, both squid proxies and the plugin daemon's peers. A template that ships a moving tag ships a different stack every day. The squid one mattered for a second reason: the image tagged `latest` there had not been rebuilt in ten months, while the version line this template pins still is.

Four of the images are one Dify release — the api, the web frontend, the agent's local sandbox and the agent backend — so all four version variables carry the same version, and CI fails the run if they ever disagree.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. Nested defaults need Docker Compose v2.5 or newer (2022).

The daily `check-pin-freshness` CI job re-resolves each pin against its registry, compares the pinned Dify and Traefik versions against the latest upstream releases, and diffs the vendored configuration against Dify's own. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Configuration lives in .env, deliberately

Everywhere else in this fleet, `.env` holds only secrets and deliberate overrides, and every other setting is a compose interpolation default. Not here.

Dify configures these images from an env file with 244 variables in it, and that file is upstream's contract with its own images. Reproducing it as compose defaults would fork that contract and drift from it silently: a variable Dify adds would be a variable this template does not pass. So `.env.example` is Dify's own file, from the release this template pins, with one change — the fifty-seven variables the compose file owns carry a line saying what sets them instead of a value that would look like it worked.

CI copies `.env.example` to `.env` and boots from it. A variable missing from that file is a failed run, not a surprise for the next person who deploys.

## Production checklist

- [ ] **Create the administrator account immediately after deploy**, at `/install`. Until you do, the first stranger who finds the URL can.
- [ ] **Generate all twelve secrets.** `.env.example` carries the command for each; none of them may keep a placeholder.
- [ ] **Host-mount the backup volumes.** By default the dumps and archives land in named volumes: if the host dies, they die with it.
- [ ] **Keep `.env` with your backups.** The provider credentials in the database are encrypted with `DIFY_SECRET_KEY`; a database restored without it is rows nobody can decrypt.
- [ ] **Know the restore procedure.** Run both restore scripts against a test deployment before you need them in production.
- [ ] **Read Dify's licence if you plan to sell access.** It is Apache 2.0 with additional terms: a single-tenant self-hosted deployment may be commercial, but operating a multi-tenant service, or removing the logo and copyright from the console, needs a commercial licence from Dify.

## Backups and restore

The `backups` container runs one loop: a `pg_dump | gzip` of the main database, then the same of the plugin daemon's database, then a `tar.gz` of the application storage and the installed plugin packages, then a prune, then sleep. Defaults are a 30-minute warm-up, a 24-hour interval and 7-day retention, all overridable in `.env`. The plugin database is created by the daemon on first start, so on a stack that has never run a plugin that step reports a skip rather than a failure.

Restore with the interactive scripts, **database first, then the application data from the same timestamp**:

```bash
chmod +x ./*.sh
./dify-restore-database.sh                  # apps, workflows, accounts, credentials
./dify-restore-database.sh --plugin         # installed plugin records
./dify-restore-application-data.sh          # uploaded documents and plugin packages
```

**The knowledge-base embeddings in Weaviate are not in these archives, on purpose.** A `tar` of a running vector store is a copy that may not open, and shipping something that looks like a backup and is not is worse than saying so. After restoring, re-index the affected knowledge bases from the Dify console: the source documents are in the application data archive, so nothing is lost but the model calls. If you need point-in-time vector backups, Weaviate's own backup module is the tool for it.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults: the same values CI boots the stack under. Eighteen containers fit on a host with 8 GB under these defaults. The two that grow under real load are `worker`, which indexes documents, and `weaviate`, which holds the embeddings. Override any of them in `.env` and the override survives every `git pull`. If a service is OOM-killed, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`. Infrastructure containers — the reverse proxies, the database, the cache, the one-shot permissions job and the backups sidecar — run with `cap_drop: [ALL]` and add back only what their entrypoints need. The application containers keep the default capability set on purpose: upstream images assume it, and a wrong guess there is a boot loop in production rather than a hardening win. CI boots the stack under exactly these settings on every push.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/dify-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck and actionlint, Trivy scans of all thirteen pinned images, the daily freshness check including the vendored-configuration diff, and a deploy job that boots the stack from `.env.example` itself and then requires the console API to answer with its setup state through Traefik, the Celery worker to complete a scheduled task rather than merely run, the code sandbox to answer the api while being on no routable network, a dump and an archive to be produced and readable, the eight backup and restore scenarios to pass, and Dify to come back up on the database the restore test replaced underneath it.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the smoke test. The scenario that matters most is the restore roundtrip: insert a marker row, restore the earliest backup, assert the marker is gone. A backup that cannot be restored fails the build. Run it yourself against a running deployment with short intervals in `.env` (`BACKUP_INIT_SLEEP=15s`, `BACKUP_INTERVAL=60s`):

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

It stops the database container briefly to prove failure detection. Run it on a staging copy, not on production.

## Security notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- Only Traefik publishes a port. The plugin debugging port Dify's own compose exposes is not published here.
- The code sandbox and the agent's sandbox each sit on an internal network with a squid proxy as the only way out.
- Dify is licensed Apache 2.0 with additional terms restricting multi-tenant operation and console rebranding. This repository is the deployment template, MIT-licensed; the licence that governs Dify itself is Dify's.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
