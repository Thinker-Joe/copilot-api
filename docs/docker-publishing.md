# Container image publishing

This reference describes the triggers, validation steps, image tags, and build metadata configured in `.github/workflows/release-docker.yml`.

## Triggers and permissions

- Pushing a version tag matching `v*.*.*` starts validation and, if validation succeeds, publishing to GHCR. Tag pushes are not filtered by changed file paths.
- Pull requests matching the workflow's path filters run validation only. They do not log in to GHCR or publish images.
- Manual dispatch runs validation for the selected ref. Publishing is allowed only for a tag ref starting with `v`; dispatching a branch does not publish an image. Use a valid semantic version tag for release aliases.
- Branch pushes do not trigger this workflow.
- The workflow grants `contents: read` by default. Only the publish job receives `packages: write`.

## Validation before publishing

Both native Linux runners, AMD64 and ARM64, must succeed. Each runner installs locked root and desktop dependencies, runs `bun run lint:all`, `bun run typecheck:all`, and `bun test`, then builds a local image.

Additional checks depend on the files in the selected revision:

- If `docker-compose.yaml` exists, validate the base Compose configuration. If `docker-compose.bind.yaml` also exists, validate the merged configuration.
- If `tests/docker-smoke.test.ts` exists, run it against the local image using `COPILOT_API_DOCKER_TEST_IMAGE`.

When these files are absent, their checks are skipped. A successful image build alone does not verify container lifecycle behavior.

## Published image and metadata

The image is published under `ghcr.io/<owner>/<repository>`, with the repository identifier converted to lowercase.

After validation, the publish job builds and pushes a multi-platform image for `linux/amd64` and `linux/arm64` using Buildx and QEMU. This is a separate build, not a promotion of the local images produced by the validation jobs.

The build requests an SBOM and `mode=max` provenance attestations. These describe image contents and build inputs; they are not image signatures or vulnerability scan results. The workflow does not sign images.

## Image tags

The following examples use hypothetical version tags:

| Git tag | Image tags |
| --- | --- |
| `v2.5.3` | `v2.5.3`, `v2.5`, `v2`, `2.5.3`, `2.5`, `2`, `latest`, `sha-<full commit SHA>` |
| `v2.6.0-beta.1` | `v2.6.0-beta.1`, `2.6.0-beta.1`, `sha-<full commit SHA>` |

Stable versions receive both `v`-prefixed and unprefixed version aliases. Prereleases receive only full-version and commit tags: they do not update major, minor, or `latest` aliases. The explicit `prefix=v` preserves the prefix on prerelease tags as well.

Tags, including `sha-*`, can be overwritten by another publishing run. Pin the image digest when a deployment must refer to immutable image content.

## Concurrency and reruns

Concurrency is grouped by Git ref. Runs for different version tags do not cancel each other, and tag runs do not cancel an in-progress run for the same ref.

Publishing a stable version updates its rolling aliases, including `latest`, without checking whether that version is newer than the previously published one. Rerunning an older stable release can therefore move those aliases backward. Releases for different refs can also finish out of version order. Review the selected tag before rerunning or manually dispatching a release.
