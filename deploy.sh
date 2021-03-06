#!/bin/bash
#
# Copyright 2019 The Google Cloud Robotics Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Manage a deployment

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${DIR}/scripts/common.sh"

set -o pipefail -o errexit

PROJECT_NAME="cloud-robotics"

TERRAFORM="$HOME/.cache/cloud-robotics/terraform"
TERRAFORM_VERSION=0.11.7
TERRAFORM_DIR="${DIR}/src/bootstrap/cloud/terraform"
TERRAFORM_APPLY_FLAGS=${TERRAFORM_APPLY_FLAGS:- -auto-approve}

APP_MANAGEMENT=${APP_MANAGEMENT:-true}


# utility functions

function include_config {
  source "${DIR}/scripts/include-config.sh"

  PROJECT_DOMAIN=${CLOUD_ROBOTICS_DOMAIN:-"www.endpoints.${GCP_PROJECT_ID}.cloud.goog"}
  PROJECT_OWNER_EMAIL=${CLOUD_ROBOTICS_OWNER_EMAIL:-$(gcloud config get-value account)}
  KUBE_CONTEXT="gke_${GCP_PROJECT_ID}_${GCP_ZONE}_${PROJECT_NAME}"

  HELM="${DIR}/bazel-out/../../../external/kubernetes_helm/helm --kube-context ${KUBE_CONTEXT}"
}

function robot_bootstrap {
  bazel build //src/bootstrap/robot:all
  bazel run //src/go/cmd/setup-robot:setup-robot.push
  bazel run //src/app_charts/robco-base:robco-base-robot.push

  gsutil -h "Cache-Control:private, max-age=0, no-transform" \
    cp -a public-read \
      src/bootstrap/robot/install_k8s_on_robot.sh \
      bazel-genfiles/src/bootstrap/robot/setup_robot.sh \
      "gs://${GCP_PROJECT_ID}-robot/"
}

function check_project_resources {
  # TODO(rodrigoq): if cleanup-services.sh is adjusted to allow specifying the
  # project, adjust this message too.
  echo "Project resource status:"
  "${DIR}"/scripts/show-resource-usage.sh ${GCP_PROJECT_ID} \
    || die "ERROR: Quota reached, consider running scripts/cleanup-services.sh"
}

function clear_iot_devices {
  local iot_registry_name="$1"
  local devices=$(gcloud beta iot devices list \
    --project "${GCP_PROJECT_ID}" \
    --region "${GCP_REGION}" \
    --registry "${iot_registry_name}" \
    --format='value(id)')
  if [[ -n "${devices}" ]] ; then
    echo "Clearing IoT devices from ${iot_registry_name}" 1>&2
    for dev in ${devices}; do
      gcloud beta iot devices delete \
        --quiet \
        --project "${GCP_PROJECT_ID}" \
        --region "${GCP_REGION}" \
        --registry "${iot_registry_name}" \
        ${dev}
    done
  fi
}

function terraform_install {
  local installed_version=$("${TERRAFORM}" version 2>/dev/null | head -n 1)
  if [[ ! "${installed_version}" =~ v${TERRAFORM_VERSION}$ ]]; then
    echo "Downloading terraform v${TERRAFORM_VERSION}..."
    local bin_dir=$(dirname "${TERRAFORM}")
    mkdir -p "${bin_dir}"
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
      | funzip > "${TERRAFORM}"
    chmod +x "${TERRAFORM}"
  fi
}

function terraform_exec {
  ( cd "${TERRAFORM_DIR}" && ${TERRAFORM} "$@" )
}

function terraform_init {
  terraform_install

  IMAGE_PROJECT_ID="$(echo ${CLOUD_ROBOTICS_CONTAINER_REGISTRY} | sed -n -e 's:^.*gcr.io/::p')"

  # Pass CLOUD_ROBOTICS_DOMAIN here and not PROJECT_DOMAIN, as we only create dns resources if a custom
  # domain is used.
  cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
# autogenerated by deploy.sh, do not edit!
name = "${GCP_PROJECT_ID}"
id = "${GCP_PROJECT_ID}"
domain = "${CLOUD_ROBOTICS_DOMAIN}"
zone = "${GCP_ZONE}"
region = "${GCP_REGION}"
billing_account = "${GCP_BILLING_ACCOUNT}"
shared_owner_group = "${CLOUD_ROBOTICS_SHARED_OWNER_GROUP}"
EOF

  if [[ -n "${IMAGE_PROJECT_ID}" ]] && [[ "${IMAGE_PROJECT_ID}" != "${GCP_PROJECT_ID}" ]]; then
    cat >> "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
private_image_repositories = ["${IMAGE_PROJECT_ID}"]
EOF
  fi

  if [[ -n "${TERRAFORM_GCS_BUCKET:-}" ]]; then
    cat > "${TERRAFORM_DIR}/backend.tf" <<EOF
# autogenerated by deploy.sh, do not edit!
terraform {
  backend "gcs" {
    bucket = "${TERRAFORM_GCS_BUCKET}"
    prefix = "${TERRAFORM_GCS_PREFIX}"
  }
}
EOF
  else
    rm -f "${TERRAFORM_DIR}/backend.tf"
  fi

  # TODO(ensonic): we created this symlink before and apparently terraform fails when the symlink is
  # there but not pointing anywhere
  rm -f ${TERRAFORM_DIR}/config.auto.tfvars || true

  terraform_exec init -upgrade -reconfigure \
    || die "terraform init failed"
}

function terraform_apply {
  terraform_init

  # Workaround for https://github.com/terraform-providers/terraform-provider-google/issues/2118
  terraform_exec import google_app_engine_application.app ${GCP_PROJECT_ID} 2>/dev/null || true
  # TODO(swolter): Temporary hack to import entries created by external-dns, delete 2019-01-31
  if [[ -n "${CLOUD_ROBOTICS_DOMAIN:-}" ]]; then
    terraform_exec import google_dns_record_set.www-entry "external-dns/${CLOUD_ROBOTICS_DOMAIN}./A" \
      2>/dev/null || true
  fi
  # TODO(swolter): Temporary hack to remove DNS delegation from TF management, delete 2019-01-31
  terraform_exec state rm google_dns_record_set.dns-delegation-entry \
    2>/dev/null || true
  # TODO(swolter): Temporary hack to clear out the old IoT registry before deleting.
  if terraform_exec state show google_cloudiot_registry.robco-robots | grep '^.'; then
    clear_iot_devices "robco-robots"
  fi

  # google_endpoints_service references built file (see endpoints.tf)
  bazel build //src/proto/map:proto_descriptor

  terraform_exec apply ${TERRAFORM_APPLY_FLAGS} \
    || die "terraform apply failed"
}

function terraform_delete {
  # We only do a partial deletion because e.g. projects take ages to redeploy.
  terraform_exec destroy \
      -auto-approve \
      -target google_container_cluster.cloud-robotics \
      -target google_cloudiot_registry.cloud-robotics \
      -target google_dns_managed_zone.external-dns \
    || die "terraform destroy failed"
}


function cluster_auth {
  gcloud container clusters get-credentials "${PROJECT_NAME}" \
    --zone ${GCP_ZONE} \
    --project ${GCP_PROJECT_ID} \
    || die "create: failed to get cluster credentials"
}

function helm_init {
  bazel build "@kubernetes_helm//:helm"
  ${HELM} init --history-max=10 --upgrade --force-upgrade --wait
}

function helm_charts {
  bazel build "@kubernetes_helm//:helm" \
      //src/app_charts/robco-base:robco-base-cloud \
      //src/app_charts/robco-platform-apps:robco-platform-apps-cloud \
      //src/app_charts:push

  # Running :push outside the build system shaves ~3 seconds off an incremental
  # build.
  ${DIR}/bazel-bin/src/app_charts/push

  # Transitionary helper:
  # Delete the obsolete robot-cluster app. It has been merged back into robco-base.
  ${HELM} delete --purge robot-cluster-cloud 2>/dev/null || true

  INGRESS_IP=$(cd "${TERRAFORM_DIR}" && ${TERRAFORM} output ingress-ip)

  ${HELM} repo update
  # TODO(ensonic): we'd like to use this as part of 'robco-base-cloud', but have no means of
  # enforcing dependencies. The cert-manager chart introduces new CRDs that we are using in
  # robco-base-cloud.
  # TODO(rodrigoq): when upgrading to v0.6, make sure the CRDs are manually
  # installed beforehand: https://github.com/jetstack/cert-manager/pull/1138
  helmout=$(${HELM} upgrade --install cert-manager --set rbac.create=false stable/cert-manager --version v0.5.2) \
    || die "Helm failed for jetstack-cert-manager: $helmout"

  values=$(cat <<EOF
    --set-string domain=${PROJECT_DOMAIN}
    --set-string ingress_ip=${INGRESS_IP}
    --set-string project=${GCP_PROJECT_ID}
    --set-string region=${GCP_REGION}
    --set-string owner_email=${PROJECT_OWNER_EMAIL}
    --set-string app_management=${APP_MANAGEMENT}
    --set-string deploy_environment=${CLOUD_ROBOTICS_DEPLOY_ENVIRONMENT}
    --set-string oauth2_proxy.client_id=${CLOUD_ROBOTICS_OAUTH2_CLIENT_ID}
    --set-string oauth2_proxy.client_secret=${CLOUD_ROBOTICS_OAUTH2_CLIENT_SECRET}
    --set-string oauth2_proxy.cookie_secret=${CLOUD_ROBOTICS_COOKIE_SECRET}
EOF
)

  # TODO(rodrigoq): during the repo reorg, make sure that the release name
  # matches the chart name. Right now one is "robco-cloud-base" and the other is
  # "robco-base-cloud", which is confusing.
  helmout=$(${HELM} upgrade --install robco-cloud-base ./bazel-genfiles/src/app_charts/robco-base/robco-base-cloud-0.0.1.tgz $values) \
    || die "Helm failed for robco-base-cloud: $helmout"
  echo "helm installed robco-base-cloud to ${KUBE_CONTEXT}: $helmout"

  helmout=$(${HELM} upgrade --install robco-platform-apps ./bazel-genfiles/src/app_charts/robco-platform-apps/robco-platform-apps-cloud-0.0.1.tgz) \
    || die "Helm failed for robco-platform-apps-cloud: $helmout"
  echo "helm installed robco-platform-apps-cloud to ${KUBE_CONTEXT}"
}

# commands

function set-project {
  [[ $# -eq 1 ]] || die "usage: $0 set-project <project-id>"

  local project_id=$1

  [[ ! -e "${DIR}/config.sh" ]] || die "ERROR: config.sh already exists"
  [[ ! -e "${DIR}/config.bzl" ]] || die "ERROR: config.bzl already exists"

  # Check that the project exists and that we have access.
  gcloud projects describe "${project_id}" >/dev/null \
    || die "ERROR: unable to access ${project_id}"

  # Extract the billing account name from gcloud. The output looks like:
  # billingAccountName: billingAccounts/001E73-146317-2C82DD
  local billing_account=$(gcloud beta billing projects describe "${project_id}" \
    | sed -n "s#^billingAccountName.*/##p")

  [[ -n "${billing_account}" ]] \
    || die "ERROR: failed to get billing account for ${project_id}. Please check that billing is enabled."

  # Create config files based on templates.
  cat "${DIR}/config.bzl.tmpl" \
    | sed "s/my-project/${project_id}/" \
    > "${DIR}/config.bzl"
  echo "Created config.bzl for ${project_id}."

  cat "${DIR}/config.sh.tmpl" \
    | sed -e "s/my-project/${project_id}/" \
      -e "s/012345-678901-234567/${billing_account}/" \
    > "${DIR}/config.sh"
  echo "Created config.sh for ${project_id}."

  # Load the newly created config and import the project into the Terraform
  # state.
  include_config
  terraform_init
  terraform_exec import google_project.project "${project_id}" \
    || die "ERROR: failed to import project ${project_id} into Terraform"

  echo "Project successfully set to ${project_id}."
}

function create {
  include_config
  terraform_apply
  cluster_auth
  # TODO(b/123625511): move robot_bootstrap after helm_charts. For now, make
  # sure `setup-robot.push` is the first container push to avoid a GCR bug with
  # parallel pushes on newly created projects.
  robot_bootstrap
  helm_init
  helm_charts
  check_project_resources
}

function delete {
  include_config
  clear_iot_devices "cloud-robotics"
  terraform_delete
}

# Alias for create.
function update {
  create
}

function fast_push {
  include_config
  helm_charts
}

# main

if [ "$#" -lt 1 ]; then
  die "Usage: $0 {set-project|create|delete|update|fast_push}"
fi

# call arguments verbatim:
$@
