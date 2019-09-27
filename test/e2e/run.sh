#!/usr/bin/env bash

set -o errexit

declare -a on_exit_items

function on_exit() {
    if [ "${#on_exit_items[@]}" -gt 0 ]; then
        echo -e '\nRunning deferred items, please do not interrupt until they are done:'
    fi
    for I in "${on_exit_items[@]}"; do
        echo "deferred: ${I}"
        eval "${I}"
    done
}

# Cleaning up only makes sense in a local environment
# it just wastes time in CircleCI
if [ "${CI}" != 'true' ]; then
    trap on_exit EXIT
fi

function defer() {
    on_exit_items=("$*" "${on_exit_items[@]}")
}

REPO_ROOT=$(git rev-parse --show-toplevel)
SCRIPT_DIR="${REPO_ROOT}/test/e2e"
KIND_VERSION="v0.5.1"
CACHE_DIR="${REPO_ROOT}/cache/$CURRENT_OS_ARCH"
KIND_CACHE_PATH="${CACHE_DIR}/kind-$KIND_VERSION"
KIND_CLUSTER=flux-e2e
USING_KIND=false
HELM_OP_NAMESPACE=helm-operator-e2e
DEMO_NAMESPACE=demo

# Check if there is a kubernetes cluster running, otherwise use Kind
if ! kubectl version > /dev/null 2>&1 ; then
    if [ ! -f "${KIND_CACHE_PATH}" ]; then
        echo '>>> Downloading Kind'
        mkdir -p "${CACHE_DIR}"
        curl -sL "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${CURRENT_OS_ARCH}" -o "${KIND_CACHE_PATH}"
    fi
    echo '>>> Creating Kind Kubernetes cluster'
    cp "${KIND_CACHE_PATH}" "${REPO_ROOT}/test/bin/kind"
    chmod +x "${REPO_ROOT}/test/bin/kind"
    defer kind --name "${KIND_CLUSTER}" delete cluster > /dev/null 2>&1
    kind create cluster --name "${KIND_CLUSTER}" --wait 5m
    export KUBECONFIG="$(kind --name="${KIND_CLUSTER}" get kubeconfig-path)"
    USING_KIND=true
    kubectl get pods --all-namespaces
fi

if ! helm version > /dev/null 2>&1; then
    echo '>>> Installing Tiller'
    kubectl --namespace kube-system create sa tiller
    defer kubectl --namespace kube-system delete sa tiller
    kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
    defer kubectl delete clusterrolebinding tiller-cluster-rule
    helm init --service-account tiller --upgrade --wait
    defer helm reset --force
fi

kubectl create namespace "$HELM_OP_NAMESPACE"
defer kubectl delete namespace "$HELM_OP_NAMESPACE"

if [ "${USING_KIND}" = 'true' ]; then
    echo '>>> Loading images into the Kind cluster'
    kind --name "${KIND_CLUSTER}" load docker-image 'docker.io/fluxcd/helm-operator:latest'
fi

echo '>>> Installing the Flux Helm Operator with Helm'

CREATE_CRDS='true'
if kubectl get crd fluxhelmreleases.helm.fluxcd.io > /dev/null 2>&1; then
  # CRDs existed, don't try to create them
  echo 'CRDs exists, setting createCRD=false'
  CREATE_CRDS='false'
else
  # Schedule CRD deletion before calling helm, since it may fail and create them anyways
  defer kubectl delete crd fluxhelmreleases.helm.fluxcd.io > /dev/null 2>&1
fi

defer helm delete --purge flux > /dev/null 2>&1

helm install --name flux-helm-operator --wait \
--namespace "${HELM_OP_NAMESPACE}" \
--set image.repository=docker.io/fluxcd/helm-operator \
--set image.tag=latest \
--set createCRD="${CREATE_CRDS}" \
"${REPO_ROOT}/chart/helm-operator"

echo '>>> Applying HelmRelease'
kubectl create namespace "${DEMO_NAMESPACE}"
defer kubectl delete namespace "${DEMO_NAMESPACE}"

kubectl -n "${DEMO_NAMESPACE}" apply -f ${REPO_ROOT}/test/mongodb-hr.yaml

echo '>>> Waiting for Helm release mongodb'
retries=24
count=0
ok=false
until ${ok}; do
    kubectl -n "${DEMO_NAMESPACE}" describe deployment/mongodb && ok=true || ok=false
    echo -n '.'
    sleep 5
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n "${HELM_OP_NAMESPACE}" logs deployment/flux-helm-operator
        echo ' No more retries left'
        exit 1
    fi
done
echo ' done'

echo '>>> Helm operator logs'
kubectl -n "${HELM_OP_NAMESPACE}" logs deployment/flux-helm-operator

echo '>>> List pods'
kubectl -n "${DEMO_NAMESPACE}" get pods

echo '>>> Check Helm releases'
kubectl -n "${DEMO_NAMESPACE}" rollout status deployment/mongodb

echo -e '\nEnd to end test was successful!!\n'
