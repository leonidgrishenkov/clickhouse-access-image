# CI image for the analytic `clickhouse-access` GitLab project: Terraform plus everything
# its pipeline used to install on the fly. The apply job runs
# modules/access/publish_password.py through local-exec and did `apk add --no-cache
# python3` on every run, the plan jobs added jq, and review:claude installed Claude Code.
#
# The Terraform version follows TF_VERSION in that project's .gitlab-ci.yml; bump them
# together. The upstream `terraform` entrypoint is kept, so GitLab CI still needs
# `entrypoint: [""]` to run its shell scripts.
ARG TERRAFORM_VERSION=1.16.5
FROM hashicorp/terraform:${TERRAFORM_VERSION}

# pipefail for the pipe in the Claude Code RUN below (hadolint DL4006); busybox ash has it.
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Major.minor only: `~=` takes the newest 3.14.x in the base image's Alpine branch
# (3.24 for Terraform 1.16.5). An exact -rN pin breaks as soon as Alpine replaces that
# build, and an unpinned `python3` fails hadolint (DL3018) in the release workflow.
# publish_password.py needs 3.10+ (`dict | None`) and only the standard library: no pip.
ARG PYTHON_VERSION=3.14
# The rest is pinned the same way. The base image already has git, but the review job
# builds the MR's diff and exports the commit with it, so it is listed rather than
# assumed. jq is for the plan jobs' check_lost_resources.sh. libgcc and libstdc++ (they
# follow the branch's GCC) and ripgrep are what Claude Code needs at runtime on musl;
# ripgrep backs its Grep and Glob tools (USE_BUILTIN_RIPGREP below). The CA bundle and
# wget come with Alpine itself; nothing needs curl.
ARG GIT_VERSION=2.54
ARG JQ_VERSION=1.8
ARG GCC_VERSION=15.2
ARG RIPGREP_VERSION=15.1

RUN apk add --no-cache \
      "python3~=${PYTHON_VERSION}" \
      "git~=${GIT_VERSION}" \
      "jq~=${JQ_VERSION}" \
      "libgcc~=${GCC_VERSION}" \
      "libstdc++~=${GCC_VERSION}" \
      "ripgrep~=${RIPGREP_VERSION}"

# Claude Code, the native musl binary of an exact version, checked against the sha256 in
# that release's manifest - what install.sh does. install.sh itself is not used: it needs
# bash and curl, first downloads the latest binary and lets it install the pinned one.
ARG CLAUDE_CODE_VERSION=2.1.308
# Set by BuildKit for each platform of a multi-arch build.
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) platform=linux-x64-musl ;; \
      arm64) platform=linux-arm64-musl ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && release="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
 && wget -q -O /tmp/manifest.json "${release}/manifest.json" \
 && wget -q -O /tmp/claude "${release}/${platform}/claude" \
 && python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["platforms"][sys.argv[2]]["checksum"] + "  /tmp/claude")' \
      /tmp/manifest.json "${platform}" | sha256sum -c - \
 && install -m 0755 /tmp/claude /usr/local/bin/claude \
 && rm /tmp/claude /tmp/manifest.json \
 && claude --version

# The bundled ripgrep is built for glibc; on musl Claude Code has to use the system one.
# A job that clears the environment (review:claude runs claude under env -i) passes both
# again itself.
ENV USE_BUILTIN_RIPGREP=0 \
    DISABLE_AUTOUPDATER=1
