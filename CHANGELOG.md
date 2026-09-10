# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **`langgenius/dify-web:1.17.0` moved to `langgenius/dify-web:1.17.1`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.
- **`langgenius/dify-agent-local-sandbox:1.17.0` moved to `langgenius/dify-agent-local-sandbox:1.17.1`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.
- **`langgenius/dify-api:1.17.0` moved to `langgenius/dify-api:1.17.1`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.
- **`langgenius/dify-agent-backend:1.17.0` moved to `langgenius/dify-agent-backend:1.17.1`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.

## [1.0.0] - 2026-09-09

First release. A production deployment of Dify behind Traefik, built to the
fleet standard established in
[keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

### Added

- **Dify 1.17.0, eighteen containers, thirteen images pinned by digest.**
  Everything Dify's own compose file starts without a profile, plus PostgreSQL,
  Weaviate and the websocket worker, plus Traefik and a backups sidecar. Five
  of the pins name a version where upstream says `:latest`.
- **One hostname instead of nine URLs.** Dify reads nine separate URL variables
  and ships them all empty, and empty means "guess from the request" — which is
  what breaks e-mail links, the Human Input node and signed file URLs behind a
  reverse proxy. `DIFY_HOSTNAME` derives all nine; the two that must stay
  internal keep their internal addresses.
- **Twelve secrets that are yours.** Every published default in Dify's compose
  file — the database and Redis passwords, the sandbox key, the plugin daemon
  key, the inner API key, the agent token named "for-dev-only", the Weaviate
  API key — is required here, with the command that generates it in
  `.env.example`, and the stack refuses to start without one.
- **Dify's own nginx, with Traefik in front.** Its eleven-entry routing table
  stays upstream's, including the `/e/` rule that builds the public webhook URL
  per request — something a static Traefik label cannot express. The ten
  configuration files it and the two squid proxies read are vendored here, and
  CI diffs each of them against Dify at the pinned version, so a routing change
  upstream is a red build rather than a deployment quietly serving the old table.
- **Backups of both databases and the application data**, each written to a
  `.partial` name and renamed only on success, with a `.failed` rename that
  keeps the evidence. The plugin daemon's database is created on first use, so
  a stack that has never run a plugin reports a skip rather than a failure.
- **Two restore scripts**, database (either one) and application data, each of
  which validates the archive it was handed before it stops anything.
- **Deployment Verification workflow.** Trivy scans of all thirteen images, a
  daily freshness check that also diffs the vendored configuration, and a deploy
  job that boots from `.env.example` itself and requires the console API to
  answer its setup state through Traefik, the Celery worker to complete a
  scheduled task rather than merely run, the code sandbox to answer the api
  while being on no routable network, a dump and an archive to be produced and
  readable, the eight backup and restore scenarios to pass, and Dify to come
  back up on the database the restore test replaced underneath it.
- **`update.sh`**, container hardening on every service, resource limits and
  reservations on all eighteen, and a sixty-second `stop_grace_period` on the
  database, the cache and the vector store.

### Notes for anyone adapting this from Dify's own compose file

Five things that only running it finds, each of which cost a deploy here so it
does not cost one there:

- **`DIFY_AGENT_SERVER_SECRET_KEY` is not free-form.** The agent backend
  refuses to start unless it is unpadded base64url decoding to exactly 32
  bytes. `openssl rand -base64 42` produces something that looks fine and is
  rejected.
- **nginx needs the Debian image, not alpine.** Dify's nginx entrypoint is a
  bash script and the alpine image has no bash: the container restarts forever
  on `/docker-entrypoint.sh: not found`.
- **`conf.d` cannot be mounted read-only.** The entrypoint renders the routing
  table into `/etc/nginx/conf.d/default.conf` at boot. A read-only directory
  mount makes that write fail silently, and nginx comes up listening on nothing
  while its log shows worker processes starting normally. Mount the template
  file, not the directory.
- **Dify's `.env` is not a shell script.** `LOG_DATEFORMAT=%Y-%m-%d %H:%M:%S`
  is a perfectly good compose value and a syntax error for anything that reads
  the file with `source`. It is quoted here, and the end-to-end test assigns
  each line rather than executing it.
- **The plugin debugging port is not published.** Upstream's compose file
  publishes 5003; a production deployment has no use for it.

[Unreleased]: https://github.com/heyvaldemar/dify-traefik-letsencrypt-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/dify-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
