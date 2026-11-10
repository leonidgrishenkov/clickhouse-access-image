# clickhouse-access image

Terraform with everything the `clickhouse-access` pipeline needs baked in. That project
manages the analytic ClickHouse's roles, users, grants and settings profiles with the
`clickhousedbops` provider from GitLab CI. This repo produces a versioned image; the
pipeline consumes it by tag and never rebuilds it.

## Publishing

Published to Amazon ECR Public at `public.ecr.aws/a8c0b5z6/clickhouse-access`.

Releases go through CI: pushing a tag on a commit on `main` runs
[`release.yml`](.github/workflows/release.yml). Its push job waits in the `release`
environment until you approve it (**Review deployments** on the run page), then builds
`linux/amd64` + `linux/arm64` and pushes the image tagged with the git tag, `latest` and
the commit SHA. Tag as `<terraform version>-<build>`:

```bash
git tag 1.16.5-1 && git push origin 1.16.5-1
```

Consumers pull it with:

```bash
docker pull public.ecr.aws/a8c0b5z6/clickhouse-access:1.16.5-1
```

Build a local single-arch copy to test with:

```bash
docker build -t clickhouse-access:test .
```

Publishing by hand has to be multi-arch: CI runners are almost always amd64, while this is
typically built on an arm64 Mac, and a single-arch push gives an image that fails to run for
most consumers. The default `docker` buildx driver rejects multi-platform builds, so use a
`docker-container` builder. It cannot load the result locally either, so build and push in
one step:

```bash
# ECR Public auth tokens are only issued from us-east-1.
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws
docker buildx create --name multiarch --driver docker-container --bootstrap   # once
docker buildx build --builder multiarch --platform linux/amd64,linux/arm64 \
  -t public.ecr.aws/a8c0b5z6/clickhouse-access:1.16.5-1 --push .
docker buildx imagetools inspect public.ecr.aws/a8c0b5z6/clickhouse-access:1.16.5-1
```

Known consumer: the `analytic/clickhouse-access` GitLab project, which pins the tag in
its `.gitlab-ci.yml`.

## What is in it and why

The pipeline used to run on stock `hashicorp/terraform` and `apk add python3` in every
apply job, its plan jobs added `jq`, and its `review:claude` job installed Claude Code on
every run. This image does that once:

| Component | Version | Note |
|---|---|---|
| `hashicorp/terraform` | **1.16.5** | Follows `TF_VERSION` of the consumer's `.gitlab-ci.yml`; Alpine 3.24 underneath |
| `python3` (apk) | 3.14.x | For `publish_password.py`, which the apply job runs through `local-exec` to save generated user passwords to GitLab CI/CD variables, and for the review scripts |
| Claude Code | **2.1.308** | `/usr/local/bin/claude`, the native `linux-*-musl` binary, for `review:claude`: Claude reviews the MR and a script posts the findings |
| `libgcc`, `libstdc++` (apk) | 15.2.x | Runtime of the Claude Code binary on musl |
| `ripgrep` (apk) | 15.1.x | Backs Claude Code's Grep and Glob tools |
| `git` (apk) | 2.54.x | The review job builds the MR's diff and exports the commit. The base image has it too; listed so the job doesn't depend on that |
| `jq` (apk) | 1.8.x | For `check_lost_resources.sh`, which the plan jobs run on the saved plan |

The CA bundle (`ca-certificates`) and `wget` (busybox, through OpenSSL's `ssl_client`)
come with Alpine itself; both `wget` and Python verify TLS against that bundle. There is no
`curl`: the consumer's scripts use Python's `urllib`, and the build downloads with `wget`.

Claude Code makes the image about 290 MB bigger (~480 MB instead of ~190 MB): the
binary alone is 285 MB.

Claude Code is not installed with `install.sh`: that script needs `bash` and `curl`, and it
always downloads the latest binary first and lets it install the pinned version. The
Dockerfile downloads the pinned musl binary for the build platform (`TARGETARCH`) from
`downloads.claude.ai` and checks it against the sha256 in that release's `manifest.json`,
which is what `install.sh` does too.

Each version is a build arg, so a version can be tried without editing the Dockerfile:

```bash
docker build --build-arg TERRAFORM_VERSION=1.17.1 -t clickhouse-access:test .
```

The apk packages are pinned to major.minor (`python3~=3.14`), not to an exact `-rN` build:
Alpine drops old builds from its repositories, so an exact pin stops building, while an
unpinned `apk add` fails hadolint (DL3018) in the release workflow. A new Terraform
version can move to a new Alpine branch with other versions. If the build then fails with
a package unsatisfiable, raise its build arg (`PYTHON_VERSION`, `GIT_VERSION`,
`JQ_VERSION`, `GCC_VERSION`, `RIPGREP_VERSION`) to what that branch ships:

```bash
docker run --rm --entrypoint sh hashicorp/terraform:<version> \
  -c 'apk update -q && apk policy python3 git jq libgcc libstdc++ ripgrep'
```

## Contract for consumers

1. **The entrypoint is `terraform`**, as upstream: `docker run ... clickhouse-access:1.16.5-1 version`.
   GitLab CI has to keep `entrypoint: [""]` in `image:`, otherwise the runner's shell
   script is passed to `terraform` as arguments.
2. **Claude Code needs `USE_BUILTIN_RIPGREP=0`.** The bundled ripgrep is built for glibc,
   so on musl Claude Code has to use the system one. The image sets it, with
   `DISABLE_AUTOUPDATER=1`, as `ENV`; a job that clears the environment, as `review:claude`
   does with `env -i`, passes both again. Without it Grep and Glob don't work.
3. **Python is the standard library only.** There is no pip. A script that needs a
   third-party package needs a new image version, not a `pip install` in the job.
4. **Providers are not baked in.** `terraform init` still downloads them, pinned by each
   layer's lock file; cache them in CI with `TF_PLUGIN_CACHE_DIR`.
5. **It runs as root**, like the upstream image.

## Bumping Terraform

1. Change `TERRAFORM_VERSION` in the [`Dockerfile`](Dockerfile), and the package pins if the
   new base image is on another Alpine branch (see above).
2. Merge to `main`, tag `<new version>-1` and approve the release.
3. In the consumer, change the image tag in `.gitlab-ci.yml`.

## Bumping Claude Code

1. Change `CLAUDE_CODE_VERSION` in the [`Dockerfile`](Dockerfile). The build fails if the
   release has no musl binary for a platform or its checksum doesn't match.
2. Merge to `main`, tag the next build of the same Terraform version (`1.16.5-3` after
   `1.16.5-2`) and approve the release.
3. In the consumer, change the image tag in `.gitlab-ci.yml`.
