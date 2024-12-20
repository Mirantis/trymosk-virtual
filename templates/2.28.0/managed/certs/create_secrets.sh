#!/usr/bin/env bash

set -eou pipefail

KUBECONFIG="${KUBECONFIG:=""}"
KUBECTL_BIN="${KUBECTL_BIN:="/home/mcc-user/kaas-bootstrap/bin/kubectl"}"

if [ -z "${KUBECONFIG}" ]; then
    echo "Error: KUBECONFIG must be provided"
    exit 1
fi

script_dir="$(dirname "${BASH_SOURCE[0]}")"
pushd "${script_dir}" || true

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

cfssl gencert -ca=ca.pem \
    -ca-key=ca-key.pem \
    --config=ca-config.json \
    -profile=kubernetes server-csr.json | cfssljson -bare server

${KUBECTL_BIN} -n openstack create secret generic osh-dev-hidden \
    --from-file=ca_cert=ca.pem \
    --from-file=api_cert=server.pem \
    --from-file=api_key=server-key.pem
${KUBECTL_BIN} -n openstack label secret osh-dev-hidden "openstack.lcm.mirantis.com/osdpl_secret=true"

echo "Openstack certificates has been created successfully"
