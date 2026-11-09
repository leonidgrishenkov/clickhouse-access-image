# CI image for the analytic `clickhouse-access` GitLab project: Terraform plus everything
# its pipeline used to install on the fly. Today that is python3 alone - the apply job
# runs modules/access/publish_password.py through local-exec and did
# `apk add --no-cache python3` on every run.
#
# The Terraform version follows TF_VERSION in that project's .gitlab-ci.yml; bump them
# together. The upstream `terraform` entrypoint is kept, so GitLab CI still needs
# `entrypoint: [""]` to run its shell scripts.
ARG TERRAFORM_VERSION=1.16.5
FROM hashicorp/terraform:${TERRAFORM_VERSION}

# Major.minor only: `~=` takes the newest 3.14.x in the base image's Alpine branch
# (3.24 for Terraform 1.16.5). An exact -rN pin breaks as soon as Alpine replaces that
# build, and an unpinned `python3` fails hadolint (DL3018) in the release workflow.
# publish_password.py needs 3.10+ (`dict | None`) and only the standard library: no pip.
ARG PYTHON_VERSION=3.14

RUN apk add --no-cache "python3~=${PYTHON_VERSION}"
