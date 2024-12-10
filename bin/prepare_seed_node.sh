#!/usr/bin/env bash

set -eux

script_dir="$(dirname "${BASH_SOURCE[0]}")"
prep_seed_node_env_file="${script_dir}/.prepare_seed_node.env"
if [ -f "${prep_seed_node_env_file}" ]; then
    # shellcheck source=/dev/null
    chmod +x "${prep_seed_node_env_file}" && source "${prep_seed_node_env_file}"
fi

HTTP_PROXY="${HTTP_PROXY:=}"
HTTPS_PROXY="${HTTPS_PROXY:=}"
NO_PROXY="${NO_PROXY:=}"
PROXY_CA_CERTIFICATE_PATH="${PROXY_CA_CERTIFICATE_PATH:=}"

MCC_CDN_REGION="${MCC_CDN_REGION:=}"
MCC_CDN_BASE_URL="${MCC_CDN_BASE_URL:=}"
MCC_RELEASES_URL="${MCC_RELEASES_URL:=}"
SEED_NODE_USER="${SEED_NODE_USER:="mcc-user"}"
MCC_VERSION="${MCC_VERSION:=}"

kaas_release_yaml=""
releases_dir="kaas-bootstrap/releases"

# fail fast
if [ "${MCC_CDN_REGION}" != "public" ] && [ -z "${MCC_VERSION}" ]; then
    echo "Error: MCC_VERSION must be provided for non-public cdn region"
    exit 1
fi

sudo mkdir -p /etc/docker/
cat << EOF > daemon.json
{
  "default-address-pools":
  [
    {"base":"10.200.0.0/16","size":24}
  ],
  "proxies": {
    "http-proxy": "${HTTP_PROXY}",
    "https-proxy": "${HTTPS_PROXY}",
    "no-proxy": "${NO_PROXY}"
  }
}
EOF
sudo mv daemon.json /etc/docker/daemon.json

apt_cmd="DEBIAN_FRONTEND=noninteractive apt-get"
if [ -n "${HTTP_PROXY}" ] || [ -n "${HTTPS_PROXY}" ]; then
    apt_cmd="http_proxy=${HTTP_PROXY} https_proxy=${HTTPS_PROXY} ${apt_cmd}"
    if [ -n "${NO_PROXY}" ]; then
        apt_cmd="no_proxy=${NO_PROXY} ${apt_cmd}"
    fi
    if [ -n "${PROXY_CA_CERTIFICATE_PATH}" ]; then
        sudo cp "${PROXY_CA_CERTIFICATE_PATH}" /usr/local/share/ca-certificates/
        sudo update-ca-certificates
    fi
fi
apt_cmd="sudo ${apt_cmd}"

${apt_cmd} update
${apt_cmd} install \
    arping bridge-utils docker.io golang-cfssl ipmitool net-tools tar traceroute wget -y
sudo usermod -aG docker "${SEED_NODE_USER}"

function get_kaas_release_yaml {
    kaas_release_yaml="$(find "${releases_dir}/kaas" -name "*.yaml" -type f)"
    # Sanity check: only one kaas release file should exist there
    if [ "$(echo "${kaas_release_yaml}" | wc -l)" -ne "1" ]; then
        echo "Error: more than one yaml file is found in kaas releases folder"
        exit 1
    fi

    echo "${kaas_release_yaml}"
}

wget_cmd=$(which wget)
if [ -z "${wget_cmd}" ]; then
    echo "Error: wget command is not found"
    exit 1
fi
wget_cmd="${wget_cmd} --tries 5 --no-verbose --show-progress --waitretry=15 --retry-connrefused"

if [ -n "${HTTPS_PROXY}" ] || [ -n "${HTTP_PROXY}" ]; then
    wget_proxy_optons="-e use_proxy=yes"
    if [ -n "${HTTPS_PROXY}" ]; then
        wget_proxy_optons="${wget_proxy_optons} -e https_proxy=${HTTPS_PROXY}"
    fi
    if [ -n "${HTTP_PROXY}" ]; then
        wget_proxy_optons="${wget_proxy_optons} -e http_proxy=${HTTP_PROXY}"
    fi
    if [ -n "${NO_PROXY}" ]; then
        wget_proxy_optons="${wget_proxy_optons} -e no_proxy=${NO_PROXY}"
    fi
    if [ -n "${PROXY_CA_CERTIFICATE_PATH}" ]; then
        wget_proxy_optons="${wget_proxy_optons} --ca-certificate=${PROXY_CA_CERTIFICATE_PATH}"
    fi
    wget_cmd="${wget_cmd} ${wget_proxy_optons}"
fi

yq_bin=$(which yq || true)
if [ -z "${yq_bin}" ]; then
    os_tag=$(uname -s)
    yq_bin_url="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_${os_tag}_amd64"
    yq_bin="/home/${SEED_NODE_USER}/yq"
    ${wget_cmd} -O "${yq_bin}" "${yq_bin_url}"
    chmod a+x "${yq_bin}"
fi

if [ "${MCC_CDN_REGION}" == "public" ]; then
    ${wget_cmd} https://binary.mirantis.com/releases/get_container_cloud.sh
    chmod a+x get_container_cloud.sh
    ./get_container_cloud.sh
else
    kaas_release_yaml="kaas/${MCC_VERSION}.yaml"
    mkdir -p ${releases_dir}/{kaas,cluster}

    pushd "${releases_dir}" || exit 1

    # Donwload kaas release
    ${wget_cmd} "${MCC_RELEASES_URL}/releases/${kaas_release_yaml}" -O "${kaas_release_yaml}"

    # Download cluster releases
    for cr in $(${yq_bin} eval '.spec.supportedClusterReleases[].version' "${kaas_release_yaml}"); do
        cr_file="cluster/${cr}.yaml"
        ${wget_cmd} "${MCC_RELEASES_URL}/releases/${cr_file}" -O "${cr_file}"
    done

    bootstrap_version="$(${yq_bin} eval '.spec.bootstrap.version' "${kaas_release_yaml}")"

    popd || exit 1

    bootstrap_tarball_url="${MCC_CDN_BASE_URL}/core/bin/bootstrap-linux-${bootstrap_version}.tar.gz"
    ${wget_cmd} --show-progress "${bootstrap_tarball_url}"
    tar -xzf "$(basename "${bootstrap_tarball_url}")" -C kaas-bootstrap
fi

if [ -z "${kaas_release_yaml}" ]; then
    kaas_release_yaml=$(get_kaas_release_yaml)
fi
if [ -z "${MCC_VERSION}" ]; then
    mcc_version="$(${yq_bin} eval '.spec.version' "${kaas_release_yaml}")"
    # Return kaas version
    echo "${mcc_version}" > "${script_dir}/mcc_version"
fi

echo "export PATH=\$PATH:/home/${SEED_NODE_USER}/kaas-bootstrap/bin" >> "/home/${SEED_NODE_USER}/.bashrc"
