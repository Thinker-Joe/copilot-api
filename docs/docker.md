# Docker deployment

The hardened image runs as the unprivileged `bun` user, keeps persistent state in `/data`, and keeps application code root-owned. Docker Compose publishes the host port on `127.0.0.1` by default. The gateway still requires a gateway API key because it listens on `0.0.0.0` inside the container; a GitHub token is not a gateway key.

## New installation

From the repository root:

```sh
cp .env.example .env
docker compose build
docker compose run --rm copilot-api auth keys --add YOUR_GATEWAY_API_KEY
docker compose run --rm copilot-api auth login
docker compose up -d --no-build
docker compose ps
```

Choose a strong gateway key. The CLI key argument can appear in shell history and the process list: initialize it only on a trusted host. Never paste real keys into issues or logs. The login command is interactive; alternatively set `COPILOT_API_GITHUB_TOKEN` in your untracked `.env`. It takes precedence over the legacy `GH_TOKEN` variable. Avoid setting tokens on the command line.

The default `copilot-api:local` image is built from this checkout, so this works before the changes reach upstream. To use a registry image that supports this deployment contract, set `COPILOT_API_IMAGE` to its version tag or digest, then run `docker compose pull` and `docker compose up -d --no-build`. Do not assume older upstream images support `/data` or this entrypoint.

The project-scoped `copilot-api-data` named volume survives container recreation and `docker compose down`. **Do not use `docker compose down -v` unless intentionally deleting your data.** Keep the same Compose project name when upgrading. The example adds a read-only root filesystem, a writable temporary filesystem, dropped capabilities, no-new-privileges, and bounded logs. Authentication commands use the same volume and restrictions as the server.

## Existing SV / fork deployment

**Do not switch an existing `./data:/data` deployment to the base Compose file alone.** That selects a different, initially empty named volume. Preserve the bind mount using the explicit override:

```sh
cp .env.sv.example .env.sv
# Edit .env.sv: preserve your token, proxy, host binding and absolute data directory.
docker compose --env-file .env.sv -f docker-compose.yaml -f docker-compose.sv.yaml config --quiet
docker compose --env-file .env.sv -f docker-compose.yaml -f docker-compose.sv.yaml pull
docker compose --env-file .env.sv -f docker-compose.yaml -f docker-compose.sv.yaml up -d --no-build
```

Do not overwrite an existing environment file; copy its settings into the new one. Protect environment files with appropriate host permissions. The override defaults to `ghcr.io/thinker-joe/copilot-api:dev` and uses `COPILOT_API_DATA_DIR` (default `./data`). It refuses to auto-create a missing host directory, catching path typos instead of silently starting with empty state. Use the same Compose project name as your existing deployment.

The workflow continues publishing `dev` on dev-branch pushes. Forks retain the development `latest` alias by default for compatibility with existing pull scripts. The repository Actions variable `DOCKER_LATEST_CHANNEL` can explicitly select `dev` or `release`; non-fork repositories default to `release`. Prefer an explicit `dev` tag for SV so future stable-channel changes do not affect it. No server-side switch is performed automatically by this patch.

## Root-image or old-path migration

The former image used `/root/.local/share/copilot-api`. Changing the image or target mount does not migrate ownership, and building an image with `chown /data` does not change a host bind mount. The gateway must not run as root to work around this.

1. Record the current image digest, Compose project name and mount source using `docker inspect`. Stop the old service before backing up, especially because state can include SQLite databases and sidecar files.
2. Back up the **whole** existing data directory to a protected location outside the build context. Keep configuration, GitHub tokens, provider credentials, databases and OAuth-app subdirectories. Do not print their contents.
3. Point the new mount at `/data` while retaining the same host source. Inspect the target image's UID/GID; do not assume every image uses the same numeric IDs.
4. Correct ownership of the selected directory and all its files, not just the directory. Root-owned `0600` files remain unreadable after changing only their parent.
5. Run `auth keys --list` privately with the new image and the same mount; it displays keys. Confirm that provider configuration is preserved, start the service, and check health and an authenticated request. Keep the backup until rollback is no longer needed.

Example ownership preparation on a Linux host using a rootful Docker daemon, **after stopping and backing up the old service**:

```sh
IMAGE=ghcr.io/thinker-joe/copilot-api:dev
DATA_DIR=/absolute/path/to/existing/data
test -d "$DATA_DIR" || exit 1
test "$DATA_DIR" != / || exit 1
docker pull "$IMAGE"
APP_UID=$(docker run --rm --entrypoint id "$IMAGE" -u bun)
APP_GID=$(docker run --rm --entrypoint id "$IMAGE" -g bun)
sudo chown -R "$APP_UID:$APP_GID" "$DATA_DIR"
sudo chmod 700 "$DATA_DIR"
```

Verify the resolved path before running recursive ownership commands. Do not use `chmod 777`, change unrelated host directories, or recursively rewrite file contents. Rootless Docker and user-namespace remapping require the corresponding host UID mapping; the rootful example does not apply unchanged. Docker Desktop and SELinux hosts have different sharing/label requirements. Test the mount with the intended runtime identity before starting the service.

For rollback, stop the new service and restore the protected backup plus the old image and mount definition. Do not delete the current state while investigating a failure. The config-preservation fix is equivalent to upstream commit `5d7ea5b`: errors other than a genuinely missing config are propagated rather than replacing existing configuration.

## Ports, proxies and health

- Host publication uses `COPILOT_API_BIND` and `COPILOT_API_PORT`. The Compose container port stays 4141. Do not change only the internal CLI port without updating the port mapping.
- With `docker run`, the CLI `--port`/`-p` overrides `PORT`; otherwise it defaults to 4141. The health probe reads the actual bound address, including IPv6 and dynamically allocated ports, from `COPILOT_API_HEALTHCHECK_FILE`. The image puts this file under `/tmp`, not in persistent data.
- Proxy setup is enabled for server startup and can be disabled with `--no-proxy-env`. Compose forwards upper- or lower-case HTTP/HTTPS/ALL/NO proxy variables, preferring nonempty uppercase values. HTTP proxy support does not imply support for every SOCKS proxy configuration.
- `127.0.0.1` in a proxy URL means the container itself, not the Docker host. Use an address reachable from the container. On Linux, an explicitly configured `host-gateway` mapping may be needed for a host proxy.
- The health check bypasses all proxy variables and uses bounded timeouts. It is a local liveness probe, not a check of GitHub credentials, provider availability or remaining quota. Docker health status alone does not restart an unhealthy container; `restart: unless-stopped` responds to process exit.
- For a corporate CA, mount the trusted CA bundle read-only and configure the runtime's CA input appropriately. Never disable certificate verification to make a proxy work.

## Release contract and tests

Stable releases keep the original `vX.Y.Z`, `vX.Y` and `vX` tags, plus unprefixed aliases. Prereleases do not update stable rolling aliases. Branch tags and full commit-SHA tags are also published. In the release channel, stable releases own `latest`; in the dev channel, only the dev branch does. Concurrency is scoped to each Git ref so publishing one version does not cancel another version. Package-write permission is confined to publishing, never PR validation. Deploy a version tag or digest when a moving alias is inappropriate.

The Docker workflow validates Compose, runs application tests, and builds and runs the image natively on Linux AMD64 and ARM64 before publishing. Integration tests use disposable test volumes, synthetic keys, no outbound container network, and the same filesystem/capability restrictions as Compose. To run locally:

```sh
bun test tests/docker-entrypoint.test.ts tests/docker-healthcheck.test.ts tests/server-health.test.ts
docker build -t copilot-api:test .
COPILOT_API_DOCKER_TEST_IMAGE=copilot-api:test bun test tests/docker-smoke.test.ts
```

The smoke suite is opt-in and otherwise skipped. It does not touch deployed containers or existing data volumes. Images include provenance and an SBOM; these are not a substitute for vulnerability scanning or registry access controls. For an upstream PR, keep this generic deployment contract separate from the fork-specific SV override and agree on development-image publishing with maintainers.
