#!/usr/bin/env bash

set -eou pipefail

# FIXME: stdout redirect breaks `read` logic
#exec > >(logger -s -t "$(basename "$0")") 2>&1

: "${MCC_DEMO_DEBUG:=}"
script_dir="$(dirname "${BASH_SOURCE[0]}")"
: "${ENV_FILE:="${script_dir}/.deploy.env"}"
work_dir="${script_dir}/.workdir"
mcc_version_file="${work_dir}/.mcc_version"
virtualenv_dir="${work_dir}/venv"
mkdir -p "${work_dir}"

# Proxy variables
export HTTP_PROXY="${HTTP_PROXY:=}"
export HTTPS_PROXY="${HTTPS_PROXY:=}"
export NO_PROXY="${NO_PROXY:=}"
export PROXY_CA_CERTIFICATE_PATH="${PROXY_CA_CERTIFICATE_PATH:=}"

# YQ variables
: "${YQ_VERSION:="4.13.0"}"

function _print_header {
    echo "########## Running stage: ${1} ##########"
}

function set_vars {
    _print_header "${FUNCNAME[0]}"
    # Vsphere variables
    collect_vsphere_vars

    # Seed node variables
    export SEED_NODE_USER="${SEED_NODE_USER:="mcc-user"}"
    export SEED_NODE_PXE_BRIDGE="${SEED_NODE_PXE_BRIDGE:="br0"}"
    : "${SEED_NODE_CPU_NUM:=8}"
    : "${SEED_NODE_MEMORY_MB:=16384}"
    : "${SEED_NODE_DISK_SIZE:=30GiB}"

    # Network variables
    _prepare_pxe_net_vars
    _prepare_lcm_net_vars
    _prepare_openstack_net_vars

    if [ -n "${HTTP_PROXY}" ] || [ -n "${HTTPS_PROXY}" ]; then
        if ! [[ "${NO_PROXY}" =~ ${NETWORK_PXE_SUBNET} ]]; then
            NO_PROXY="${NO_PROXY},${NETWORK_PXE_SUBNET}"
        fi
        if ! [[ "${NO_PROXY}" =~ ${NETWORK_LCM_SUBNET} ]]; then
            NO_PROXY="${NO_PROXY},${NETWORK_LCM_SUBNET}"
        fi
        if ! [[ "${NO_PROXY}" =~ ${NETWORK_OPENSTACK_SUBNET} ]]; then
            NO_PROXY="${NO_PROXY},${NETWORK_OPENSTACK_SUBNET}"
        fi
    fi

    export NTP_SERVERS="${NTP_SERVERS:=}"
    export NAMESERVERS="${NAMESERVERS:=}"
    if [ -z "${NAMESERVERS}" ]; then
        echo "Error: NAMESERVERS must be provided"
        exit 1
    fi

    # Machine variables
    # Management cluster machines
    : "${MGMT_MACHINES_CPU_NUM:=8}"
    : "${MGMT_MACHINES_MEMORY_MB:=32768}"
    : "${MGMT_MACHINES_DISK_SIZE:=150GiB}"
    # Child cluster machines
    : "${CHILD_WORKER_MACHINES_CPU_NUM:=8}"
    : "${CHILD_CONTROL_MACHINES_CPU_NUM:=8}"
    : "${CHILD_WORKER_MACHINES_MEMORY_MB:=24576}"
    : "${CHILD_CONTROL_MACHINES_MEMORY_MB:=32768}"
    # root disk
    : "${CHILD_MACHINES_ROOT_DISK_SIZE:=80GiB}"
    # Ceph disk
    : "${CHILD_MACHINES_CEPH_DISK_SIZE:=40GiB}"

    # SSH variables
    : "${SSH_PRIVATE_KEY_PATH:="${work_dir}/mcc_id_rsa"}"
    : "${SSH_PUBLIC_KEY_PATH:="${work_dir}/mcc_id_rsa.pub"}"

    # Govc variables
    : "${GOVC_FOLDER:="${script_dir}/bin"}"
    : "${GOVC_BIN:="${GOVC_FOLDER}/govc"}"
    : "${GOVC_BIN_VERSION:="v0.43.0"}"
    : "${GOVC_BIN_OS_TAG:=}"
    : "${GOVC_BIN_OS_ARCH:=}"

    # Timeout variables
    : "${MGMT_CLUSTER_READINESS_TIMEOUT:=90}"
    : "${CHILD_CLUSTER_READINESS_TIMEOUT:=90}"
    : "${CHILD_CEPH_CLUSTER_TIMEOUT:=20}"
    : "${OSDPL_APPLIED_TIMEOUT:=60}"
    : "${OPENSTACK_READINESS_TIMEOUT:=90}"
    : "${BMH_READINESS_TIMEOUT:=30}"
    : "${IRONIC_DEPLOYMENT_TIMEOUT:=30}"

    # MCC global variables
    export MCC_CDN_REGION="${MCC_CDN_REGION:="public"}"
    export MCC_CDN_BASE_URL="${MCC_CDN_BASE_URL:=}"
    export MCC_RELEASES_URL="${MCC_RELEASES_URL:=}"

    if [ -z "${MCC_CDN_BASE_URL}" ]; then
        case "${MCC_CDN_REGION}" in
            internal-ci )
                MCC_CDN_BASE_URL="https://artifactory.mcp.mirantis.net/artifactory/binary-dev-kaas-virtual"
                ;;
            internal-eu )
                MCC_CDN_BASE_URL="https://artifactory-eu.mcp.mirantis.net/artifactory/binary-dev-kaas-virtual"
                ;;
            public-ci )
                MCC_CDN_BASE_URL="https://binary-dev-kaas-virtual.mcp.mirantis.com"
                ;;
            public )
                MCC_CDN_BASE_URL="https://binary.mirantis.com"
                ;;
            * )
                die "Unknown CDN region: ${MCC_CDN_REGION}"
                ;;
        esac
    fi

    # MCC management cluster variables
    export MCC_MGMT_CLUSTER_NAME="${MCC_MGMT_CLUSTER_NAME:="mcc-mgmt"}"
    export MCC_SERVICEUSER_PASSWORD="${MCC_SERVICEUSER_PASSWORD:=}"
    : "${MCC_LICENSE_FILE:="mirantis.lic"}"

    # MCC child cluster variables
    export MCC_CHILD_CLUSTER_NAME="${MCC_CHILD_CLUSTER_NAME:="mcc-child"}"
    export MCC_CHILD_CLUSTER_NAMESPACE="${MCC_CHILD_CLUSTER_NAMESPACE:="child-ns"}"
    export MCC_CHILD_CLUSTER_RELEASE="${MCC_CHILD_CLUSTER_RELEASE:=""}"
    export MCC_CHILD_OPENSTACK_RELEASE="${MCC_CHILD_OPENSTACK_RELEASE:="antelope"}"
    export MCC_OPENSTACK_PUBLIC_DOMAIN="${MCC_OPENSTACK_PUBLIC_DOMAIN:="it.just.works"}"

    # ==================================================================================
    # Internal variables mostly:

    # Skip step variables
    : "${SKIP_GOVC_DOWNLOAD:=}"
    : "${SKIP_VSPHERE_VMS_CREATION:=}"
    : "${SKIP_SEED_NODE_CREATION:="false"}"
    : "${SKIP_SEED_NODE_SETUP:="false"}"

    if [[ -z "${NETWORK_LCM_SEED_IP}" ]] && [[ "${SKIP_SEED_NODE_CREATION}" =~ [Tt]rue ]]; then
        echo "Error: NETWORK_LCM_SEED_IP must be set if SKIP_SEED_NODE_CREATION is set to true"
        exit 1
    fi

    # MCC_VERSION should be used for internal deployments or for standalone stages run only
    : "${MCC_VERSION:=}"
    : "${APPLY_COREDNS_HACK:="true"}"
    : "${VM_NAME_PREFIX:=""}"
}

function _prepare_pxe_net_vars() {
    local out_file="${work_dir}/pxe-net.out"
    export NETWORK_PXE_SUBNET="${NETWORK_PXE_SUBNET:="10.0.0.0/26"}"
    export NETWORK_PXE_RANGE="${NETWORK_PXE_RANGE:="10.0.0.2-10.0.0.60"}"
    python_exec "${script_dir}/bin/prepare_network.py" pxe "${NETWORK_PXE_RANGE}" "${out_file}"
    # shellcheck source=/dev/null
    chmod +x "${out_file}" && source "${out_file}"
    export NETWORK_PXE_BRIDGE_IP \
        NETWORK_PXE_DHCP_RANGE \
        NETWORK_PXE_STATIC_RANGE_MGMT \
        NETWORK_PXE_METALLB_RANGE
}

function _prepare_lcm_net_vars() {
    local out_file="${work_dir}/lcm-net.out"
    export NETWORK_LCM_SUBNET="${NETWORK_LCM_SUBNET:=}"
    export NETWORK_LCM_GATEWAY="${NETWORK_LCM_GATEWAY:=}"

    if [ -z "${NETWORK_LCM_SUBNET}" ] || \
        [ -z "${NETWORK_LCM_GATEWAY}" ]; then
        echo "Error: some LCM network variables are not set, but mandatory:
            NETWORK_LCM_SUBNET: ${NETWORK_LCM_SUBNET}
            NETWORK_LCM_GATEWAY: ${NETWORK_LCM_GATEWAY}
        "
    fi

    export NETWORK_LCM_RANGE="${NETWORK_LCM_RANGE:=}"
    if [ -n "${NETWORK_LCM_RANGE}" ]; then
        python_exec "${script_dir}/bin/prepare_network.py" lcm "${NETWORK_LCM_RANGE}" "${out_file}"
        # shellcheck source=/dev/null
        chmod +x "${out_file}" && source "${out_file}"
    else
        # If NETWORK_LCM_RANGE is not provided, we expect to get more detailed input
        if [ -z "${NETWORK_LCM_SEED_IP}" ] || \
            [ -z "${NETWORK_LCM_MGMT_LB_HOST}" ] || \
            [ -z "${NETWORK_LCM_CHILD_LB_HOST}" ] || \
            [ -z "${NETWORK_LCM_METALLB_RANGE_MGMT}" ] || \
            [ -z "${NETWORK_LCM_STATIC_RANGE_MGMT}" ] || \
            [ -z "${NETWORK_LCM_METALLB_RANGE_CHILD}" ] || \
            [ -z "${NETWORK_LCM_STATIC_RANGE_CHILD}" ] || \
            [ -z "${NETWORK_LCM_METALLB_OPENSTACK_ADDRESS}" ]; then
            echo "Error: some LCM network variables are not set, but mandatory:
                NETWORK_LCM_SUBNET: ${NETWORK_LCM_SUBNET}
                NETWORK_LCM_GATEWAY: ${NETWORK_LCM_GATEWAY}
                NETWORK_LCM_MGMT_LB_HOST: ${NETWORK_LCM_MGMT_LB_HOST}
                NETWORK_LCM_MGMT_LB_HOST: ${NETWORK_LCM_MGMT_LB_HOST}
                NETWORK_LCM_CHILD_LB_HOST: ${NETWORK_LCM_CHILD_LB_HOST}
                NETWORK_LCM_METALLB_RANGE_MGMT: ${NETWORK_LCM_METALLB_RANGE_MGMT}
                NETWORK_LCM_METALLB_RANGE_CHILD: ${NETWORK_LCM_METALLB_RANGE_CHILD}
                NETWORK_LCM_STATIC_RANGE_CHILD: ${NETWORK_LCM_STATIC_RANGE_CHILD}
                NETWORK_LCM_METALLB_OPENSTACK_ADDRESS: ${NETWORK_LCM_METALLB_OPENSTACK_ADDRESS}
            "
            exit 1
        fi
    fi

    export NETWORK_LCM_SEED_IP="${NETWORK_LCM_SEED_IP:=}"
    export NETWORK_LCM_MGMT_LB_HOST="${NETWORK_LCM_MGMT_LB_HOST:=}"
    export NETWORK_LCM_CHILD_LB_HOST="${NETWORK_LCM_CHILD_LB_HOST:=}"
    export NETWORK_LCM_METALLB_RANGE_MGMT="${NETWORK_LCM_METALLB_RANGE_MGMT:=}"
    export NETWORK_LCM_STATIC_RANGE_MGMT="${NETWORK_LCM_STATIC_RANGE_MGMT:=}"
    export NETWORK_LCM_METALLB_RANGE_CHILD="${NETWORK_LCM_METALLB_RANGE_CHILD:=}"
    export NETWORK_LCM_STATIC_RANGE_CHILD="${NETWORK_LCM_STATIC_RANGE_CHILD:=}"
    export NETWORK_LCM_METALLB_OPENSTACK_ADDRESS="${NETWORK_LCM_METALLB_OPENSTACK_ADDRESS:=}"
}

function _prepare_openstack_net_vars() {
    export NETWORK_OPENSTACK_SUBNET="${NETWORK_OPENSTACK_SUBNET:=}"
    export NETWORK_OPENSTACK_GATEWAY="${NETWORK_OPENSTACK_GATEWAY:=}"
    export NETWORK_OPENSTACK_RANGE="${NETWORK_OPENSTACK_RANGE:=}"

    if [ -z "${NETWORK_OPENSTACK_SUBNET}" ] || \
        [ -z "${NETWORK_OPENSTACK_GATEWAY}" ] || \
        [ -z "${NETWORK_OPENSTACK_RANGE}" ]; then
        echo "Error: some Openstack network variables are not set, but mandatory:
            NETWORK_OPENSTACK_SUBNET: ${NETWORK_OPENSTACK_SUBNET}
            NETWORK_OPENSTACK_GATEWAY: ${NETWORK_OPENSTACK_GATEWAY}
            NETWORK_OPENSTACK_RANGE: ${NETWORK_OPENSTACK_RANGE}
        "
        exit 1
    fi

    export network_openstack_range_start network_openstack_range_end
    network_openstack_range_start="$(echo "${NETWORK_OPENSTACK_RANGE}" | cut -d '-' -f 1)"
    network_openstack_range_end="$(echo "${NETWORK_OPENSTACK_RANGE}" | cut -d '-' -f 2)"
}

function usage() {
    echo "Usage: deploy.sh"
    echo ""
    echo "Available commands:"
    echo ""
    echo "  all                                       starts MCC environment deployment:"
    echo "                                              1.  create_seed_vm"
    echo "                                              2.  create_mgmt_cluster_vms"
    echo "                                              3.  create_child_cluster_vms"
    echo "                                              4.  prepare_mgmt_cluster_templates"
    echo "                                              5.  setup_bootstrap_cluster"
    echo "                                              6.  prepare_child_cluster_templates"
    echo "                                              7.  deploy_mgmt_cluster"
    echo "                                              8.  deploy_child_cluster"
    echo "                                              9.  deploy_openstack"
    echo "                                              10. apply_coredns_hack"
    echo "  create_seed_vm                            creates seed node VM"
    echo "  setup_bootstrap_cluster                   creates a Kind bootstrap cluster on seed node"
    echo "  create_mgmt_cluster_vms                   creates a set of VMs for management cluster"
    echo "  create_child_cluster_vms                  creates a set if VMs for child cluster"
    echo "  prepare_mgmt_cluster_templates            renders k8s objects templates for management cluster deployment. Result is stored in ${work_dir}/templates/management"
    echo "  prepare_child_cluster_templates           renders k8s objects templates for child cluster deployment. Result is stored in ${work_dir}/templates/child"
    echo "  deploy_mgmt_cluster                       deploys management cluster by applying rendered k8s objects YAMLs (after 'prepare_mgmt_cluster_templates' action)"
    echo "  deploy_child_cluster                      deploys child cluster by applying rendered k8s objects YAMLs (after 'prepare_child_cluster_templates' action)"
    echo "  apply_coredns_hack                        apply hack for coredns on child cluster. Note: custom Openstack hostnames have to be resolved inside child cluster,"
    echo "                                            otherwise the Openstack endpoints are not accessible. If user adds Openstack endpoints to the DNS, the hack is not needed"
    echo "  cleanup                                   cleanup VMs from the provided folder on Vsphere"
    echo "  cleanup_bootstrap_cluster                 cleanup bootstrap cluster from seed node. Useful when management cluster deployment"
    echo "                                            is required to be restarted from scratch"
    echo "  collect_mgmt_cluster_logs                 collects mgmt cluster logs via 'container-cloud collect logs' command on seed node, packs to logs.tar.gz and copies into ${work_dir}"
    echo "  collect_child_cluster_logs                collects child cluster logs via 'container-cloud collect logs' command on seed node, packs to logs.tar.gz and copies into ${work_dir}"
    echo "  collect_logs                              combines collect_mgmt_cluster_logs and collect_child_cluster_logs"
    echo "  help                                      shows this help message"
    echo ""
    echo "Required binaries:"
    echo "  curl"
    echo "  jq"
    echo "  mktemp"
    echo "  python3"
    echo "  scp"
    echo "  ssh"
    echo "  ssh-keygen"
    echo "  tar"
    echo "  virtualenv"
    echo ""
    echo "Supported environment variables:"
    echo ""
    echo "  Common variables:"
    echo "    MCC_DEMO_DEBUG                            whether to enable debug logging for scripts"
    echo "    ENV_FILE                                  file with environment vairalbes for script"
    echo ""
    echo "  Vsphere variables:"
    echo "    VSPHERE_SERVER                            Vsphere server fqdn or ip"
    echo "    VSPHERE_SERVER_PORT                       Port to access Vsphere API. Default is 443"
    echo "    VSPHERE_SERVER_PROTOCOL                   Protocol to access Vsphere API. Default is https"
    echo "    VSPHERE_SERVER_INSECURE                   Whether to ignore Vsphere server ssl certificate"
    echo "    VSPHERE_USERNAME                          User name to access Vsphere API"
    echo "    VSPHERE_PASSWORD                          User password to access Vsphere API"
    echo "    VSPHERE_DATACENTER                        Vsphere datacenter name"
    echo "    VSPHERE_DATASTORE                         Vsphere datastore full path (preferred) or name. Example /<datacenter-name>/datastore/<datastore-name>"
    echo "    VSPHERE_DATASTORE_MGMT_CLUSTER            Vsphere datastore full path (preferred) or name for management cluster machines. Example /<datacenter-name>/datastore/<datastore-name>"
    echo "    VSPHERE_DATASTORE_CHILD_CLUSTER           Vsphere datastore full path (preferred) or name for child cluster machines. Example /<datacenter-name>/datastore/<datastore-name>"
    echo "    VSPHERE_NETWORK_LCM                       Vsphere network full path (preferred) or name fosr MCC. Example /<datacenter-name>/network/<network-name>"
    echo "    VSPHERE_NETWORK_OPENSTACK                 Vsphere network full path (preferred) or name for Openstack. Example /<datacenter-name>/network/<network-name>"
    echo "    VSPHERE_RESOURCE_POOL                     Vsphere resource pool full path (preferred) or name. Example /<datacenter-name>/host/<cluster-name>/Resources/<pool-name>"
    echo "    VSPHERE_FOLDER                            Vsphere folder pool full path (preferred) or name to place VMs. Defaults to /<datacenter-name>/vm/mcc"
    echo "    VSPHERE_VMDK_IMAGE_DATASTORE_PATH         Path to Ubuntu 22.04 vmdk image on datastore (preferred over VSPHERE_VM_TEMPLATE)"
    echo "    VSPHERE_VMDK_IMAGE_LOCAL_PATH             Local path to Ubuntu 22.04 vmdk image (preferred over VSPHERE_VM_TEMPLATE). Image will be uploaded to datastore by the script"
    echo "    VSPHERE_VM_TEMPLATE                       Full path (preferred) or name of Ubuntu 22.04 VM template on Vsphere"
    echo ""
    echo "  Network variables:"
    echo ""
    echo "    NAMESERVERS                               Comma-separated list of nameservers for MCC clusters"
    echo "    NTP_SERVERS                               Comma-separated list of ntp servers for MCC clusters"
    echo ""
    echo "    LCM (MCC control) network:"
    echo "      NETWORK_LCM_SUBNET                      CIDR of LCM network. Example 172.16.10.0/24"
    echo "      NETWORK_LCM_GATEWAY                     Gateway of LCM network"
    echo "      NETWORK_LCM_RANGE                       Range from LCM network which can be used for MCC deployment. Range will be automatically splitted"
    echo "                                              for MCC need. Minimal required number of addresses - 40. Example 172.16.10.10-172.16.10.50."
    echo "                                              If you want to manually allocated IPs use parameters NETWORK_LCM variables below"
    echo ""
    echo "      NETWORK_LCM_SEED_IP                     Seed node address"
    echo "      NETWORK_LCM_MGMT_LB_HOST                Load balancer address for MCC management cluster"
    echo "      NETWORK_LCM_CHILD_LB_HOST               Load balancer address for MCC child cluster"
    echo "      NETWORK_LCM_METALLB_RANGE_MGMT          Metallb address range for MCC management cluster"
    echo "      NETWORK_LCM_STATIC_RANGE_MGMT           Address range for MCC management cluster nodes"
    echo "      NETWORK_LCM_METALLB_RANGE_CHILD         Metallb address range for MCC child cluster"
    echo "      NETWORK_LCM_STATIC_RANGE_CHILD          Address range for MCC child cluster nodes"
    echo "      NETWORK_LCM_METALLB_OPENSTACK_ADDRESS   Adress for Openstack services"
    echo ""
    echo "    Openstack network:"
    echo "      NETWORK_OPENSTACK_SUBNET                CIDR of Openstack network. Example 172.16.20.0/24"
    echo "      NETWORK_OPENSTACK_GATEWAY               Gateway of Openstack network"
    echo "      NETWORK_OPENSTACK_RANGE                 Range from Openstack network. Minimal required number of addresses - 5. Example 172.16.20.10-172.16.20.50."
    echo ""
    echo "    PXE network (override only if defaults are not suitable):"
    echo "      NETWORK_PXE_SUBNET                      CIDR of Openstack network. Default is 10.0.0.0/26"
    echo "      NETWORK_PXE_RANGE                       Range from PXE network. Default is 10.0.0.2-10.0.0.60"
    echo ""
    echo "  Machine variables:"
    echo "    SEED_NODE_CPU_NUM                         Seed node CPU num. Default is 8"
    echo "    SEED_NODE_MEMORY_MB                       Seed node RAM in MB. Default is 16384"
    echo "    SEED_NODE_DISK_SIZE                       Seed node disk size. Default is 30GiB"
    echo "    SEED_NODE_USER                            User name to access seed node via ssh. Default is 'mcc-user'"
    echo "    SEED_NODE_PXE_BRIDGE                      PXE bridge name for MCC setup. Default is 'br0'"
    echo "    MGMT_MACHINES_MEMORY_MB                   Management cluster machines RAM in MB. Default is 32768"
    echo "    MGMT_MACHINES_CPU_NUM                     Management cluster machines CPU. Default is 8"
    echo "    MGMT_MACHINES_DISK_SIZE                   Management cluster machines disk size. Default is 150GiB"
    echo "    CHILD_CONTROL_MACHINES_CPU_NUM            Child cluster control machines CPU num. Default is 8"
    echo "    CHILD_CONTROL_MACHINES_MEMORY_MB          Child cluster control machines RAM in MB. Default is 32768"
    echo "    CHILD_WORKER_MACHINES_CPU_NUM             Child cluster worker machines CPU num. Default is 8"
    echo "    CHILD_WORKER_MACHINES_MEMORY_MB           Child cluster worker machines RAM in MB. Default is 24576"
    echo "    CHILD_MACHINES_ROOT_DISK_SIZE             Child cluster machines disk size for /root partition. Default is 80GiB"
    echo "    CHILD_MACHINES_CEPH_DISK_SIZE             Child cluster machines disk size for ceph. Default is 40GiB"
    echo ""
    echo "  MCC variables:"
    echo "     MCC_MGMT_CLUSTER_NAME                    Name for MCC management cluster. Default is mcc-mgmt"
    echo "     MCC_SERVICEUSER_PASSWORD                 'serviceuser' password to access MCC management cluster web UI. Default is auto-generated"
    echo "     MCC_LICENSE_FILE                         Local path to MCC licence file"
    echo "     MCC_CHILD_CLUSTER_NAME                   Name for MCC child cluster. Default is mcc-child"
    echo "     MCC_CHILD_CLUSTER_NAMESPACE              Namespace where MCC child cluster is going to be created. Defaults is child-ns"
    echo "     MCC_CHILD_CLUSTER_RELEASE                Cluster release for MCC child cluster. Default is auto-selected"
    echo "     MCC_CHILD_OPENSTACK_RELEASE              Openstack release for MCC child cluster. Default is auto-selected"
    echo "     MCC_OPENSTACK_PUBLIC_DOMAIN              Public domain for Openstack"
    echo ""
    echo "  Proxy variables:"
    echo "    HTTP_PROXY                                HTTP proxy"
    echo "    HTTPS_PROXY                               HTTPS proxy"
    echo "    NO_PROXY                                  Comma-separated list of IPs/FQDNs which should be accessible without proxy"
    echo "    PROXY_CA_CERTIFICATE_PATH                 Proxy certificate path (for MITM proxy)"
    echo ""
    echo "  SSH variables"
    echo "    SSH_PRIVATE_KEY_PATH                      Path to private ssh key to access Seed node and MCC cluster machines."
    echo "                                              If empty, the new ssh key pair will be generated"
    echo "    SSH_PUBLIC_KEY_PATH                       Path to public ssh key"
    echo ""
    echo "  Govc variables:"
    echo "    GOVC_BIN                                  Path to exiting govc binary. Leave empty, so the binary will be downloaded by script"
    echo "    GOVC_BIN_VERSION                          Govc binary version"
    echo "    GOVC_BIN_OS_TAG                           Govc OS tag (darwin,linux)"
    echo "    GOVC_BIN_OS_ARCH                          Govc OS arch (x86_64,arm64)"
    echo "    GOVC_FOLDER                               Folder where govc binary is downloaded"
    echo ""
    echo "  Timeout variables (minutes):"
    echo "    MGMT_CLUSTER_READINESS_TIMEOUT            Time to wait for mgmt cluster object readiness. Default: 90 (min)"
    echo "                                              MCC artifacts (container images, helm charts etc.) may take more time to download"
    echo "                                              on a poor Internet connection (f.e. via proxy)"
    echo "    CHILD_CLUSTER_READINESS_TIMEOUT           Time to wait for child cluster object readiness. Default: 90 (min)"
    echo "    CHILD_CEPH_CLUSTER_TIMEOUT                Time to wait for kaascephcluster object readiness on child. Default: 20 (min)"
    echo "    OSDPL_APPLIED_TIMEOUT                     Time to wait for osdpl object state 'APPLIED'. Default: 60 (min)"
    echo "    OPENSTACK_READINESS_TIMEOUT               Time to wait for the all openstack components readiness. Default: 90 (min)"
    echo "    BMH_READINESS_TIMEOUT                     Time to wait for all baremetalhosts (per cluster) became 'available' or 'provisioned'. Default: 30 (min)"
    echo "    IRONIC_DEPLOYMENT_TIMEOUT                 Time to wait for ironic deployment readiness. Default: 30 (min)"
    echo "                                              Provisioning artifacts (OS images, kernels, initramfs etc) may take more time to download"
    echo "                                              on a poor Internet connection (f.e. via proxy)"
    echo ""
}

function verify_binaries {
    case "$(uname -s)" in
        Linux*) base64_encode_cmd="base64 -w 0";;
        Darwin*) base64_encode_cmd="base64";;
        *) die "Unexpected system: $(uname -s)"
    esac
    curl_bin=$(which curl)
    ssh_bin=$(which ssh)
    ssh_bin="${ssh_bin} -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    scp_bin=$(which scp)
    scp_bin="${scp_bin} -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ssh_keygen_bin=$(which ssh-keygen)
    tar_bin=$(which tar)
    mktemp_bin=$(which mktemp)
    jq_bin=$(which jq)

    virtualenv_bin=$(which virtualenv)
    ${virtualenv_bin} "${virtualenv_dir}"
    set +u
    # shellcheck source=/dev/null
    source "${virtualenv_dir}/bin/activate"
    set -u
    if { [ -n "${HTTP_PROXY}" ] || [ -n "${HTTPS_PROXY}" ] ;} && [ -n "${PROXY_CA_CERTIFICATE_PATH}" ]; then
        export PIP_CERT="${PROXY_CA_CERTIFICATE_PATH}"
    fi
    pip3 install -r "${script_dir}/bin/requirements.txt"
    deactivate

    echo "Basic binaries have been verified"
}

function python_exec {
    # shellcheck source=/dev/null
    source "${virtualenv_dir}/bin/activate"
    python3 "$@"
    deactivate
}

function render_template {
    python_exec "${script_dir}/bin/render_template.py"
}

function collect_vsphere_vars {
    export VSPHERE_SERVER="${VSPHERE_SERVER:=}"
    export VSPHERE_SERVER_PORT="${VSPHERE_SERVER_PORT:="443"}"
    export VSPHERE_SERVER_PROTOCOL="${VSPHERE_SERVER_PROTOCOL:="https"}"
    export VSPHERE_SERVER_INSECURE="${VSPHERE_SERVER_INSECURE:="false"}"
    export VSPHERE_USERNAME="${VSPHERE_USERNAME:=}"
    export VSPHERE_PASSWORD="${VSPHERE_PASSWORD:=}"
    : "${VSPHERE_DATACENTER:=}"
    : "${VSPHERE_DATASTORE:=}"
    : "${VSPHERE_DATASTORE_MGMT_CLUSTER:="${VSPHERE_DATASTORE}"}"
    : "${VSPHERE_DATASTORE_CHILD_CLUSTER:="${VSPHERE_DATASTORE}"}"
    : "${VSPHERE_NETWORK_LCM:=}"
    : "${VSPHERE_NETWORK_OPENSTACK:=}"
    : "${VSPHERE_RESOURCE_POOL:=}"
    : "${VSPHERE_FOLDER:="${VSPHERE_DATACENTER}/vm/mcc"}"
    : "${VSPHERE_VM_TEMPLATE:=}"
    : "${VSPHERE_VMDK_IMAGE_LOCAL_PATH:=}"
    : "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH:=}"

    if [ -z "${VSPHERE_SERVER}" ] \
        || [ -z "${VSPHERE_USERNAME}" ] \
        || [ -z "${VSPHERE_PASSWORD}" ] \
        || [ -z "${VSPHERE_DATACENTER}" ] \
        || [ -z "${VSPHERE_NETWORK_LCM}" ] \
        || [ -z "${VSPHERE_NETWORK_OPENSTACK}" ] \
        || [ -z "${VSPHERE_RESOURCE_POOL}" ]; then
        echo "Error: some vsphere vars are not provided:"
        echo "  VSPHERE_SERVER: ${VSPHERE_SERVER}"
        echo "  VSPHERE_USERNAME: ${VSPHERE_USERNAME}"
        echo "  VSPHERE_PASSWORD: ${VSPHERE_PASSWORD}"
        echo "  VSPHERE_DATACENTER: ${VSPHERE_DATACENTER}"
        echo "  VSPHERE_NETWORK_LCM: ${VSPHERE_NETWORK_LCM}"
        echo "  VSPHERE_NETWORK_OPENSTACK: ${VSPHERE_NETWORK_OPENSTACK}"
        echo "  VSPHERE_RESOURCE_POOL: ${VSPHERE_RESOURCE_POOL}"
        echo "  VSPHERE_VM_TEMPLATE: ${VSPHERE_VM_TEMPLATE}"
        exit 1
    fi
    if [ -z "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH}" ] \
        && [ -z "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}" ] \
        && [ -z "${VSPHERE_VM_TEMPLATE}" ]; then
        echo "Error: Vsphere VM image has to be provided via one of the following variables:
            VSPHERE_VMDK_IMAGE_DATASTORE_PATH
            VSPHERE_VMDK_IMAGE_LOCAL_PATH
            VSPHERE_VM_TEMPLATE"
        exit 1
    fi

    if [ -z "${VSPHERE_DATASTORE}" ]; then
        if [ -z "${VSPHERE_DATASTORE_MGMT_CLUSTER}" ]; then
            echo "VSPHERE_DATASTORE_MGMT_CLUSTER or VSPHERE_DATASTORE must be provided"
            exit 1
        fi
        if [ -z "${VSPHERE_DATASTORE_CHILD_CLUSTER}" ]; then
            echo "VSPHERE_DATASTORE_CHILD_CLUSTER or VSPHERE_DATASTORE must be provided"
            exit 1
        fi
    fi

    echo "Vsphere variables have been verified"

    # Ensure some vsphere objects are provided by full path, not just name
    if ! [[ "${VSPHERE_FOLDER}" =~ ^/.* ]]; then
        VSPHERE_FOLDER="/${VSPHERE_DATACENTER}/vm/${VSPHERE_FOLDER}"
    fi

    if ! [[ "${VSPHERE_NETWORK_LCM}" =~ ^/.* ]]; then
        VSPHERE_NETWORK_LCM="/${VSPHERE_DATACENTER}/network/${VSPHERE_NETWORK_LCM}"
    fi

    if ! [[ "${VSPHERE_NETWORK_OPENSTACK}" =~ ^/.* ]]; then
        VSPHERE_NETWORK_OPENSTACK="/${VSPHERE_DATACENTER}/network/${VSPHERE_NETWORK_OPENSTACK}"
    fi

    cat << EOF > "${work_dir}/govc.env"
#!/bin/bash
export GOVC_URL=${VSPHERE_SERVER_PROTOCOL}://${VSPHERE_SERVER}:${VSPHERE_SERVER_PORT}
export GOVC_USERNAME=${VSPHERE_USERNAME}
export GOVC_PASSWORD=${VSPHERE_PASSWORD}
EOF
    if [[ "${VSPHERE_SERVER_INSECURE}" =~ [Tt]rue ]]; then
        echo "export GOVC_INSECURE=true" >> "${work_dir}/govc.env"
    fi

    # shellcheck source=/dev/null
    chmod +x "${work_dir}/govc.env" && source "${work_dir}/govc.env"
}

function _curl {
    local curl_cmd="${curl_bin}"
    if [ -n "${HTTP_PROXY}" ] || [ -n "${HTTPS_PROXY}" ]; then
        if [ -n "${HTTP_PROXY}" ]; then
            curl_cmd="${curl_bin} -x ${HTTP_PROXY}"
        fi
        if [ -n "${HTTPS_PROXY}" ]; then
            curl_cmd="${curl_bin} -x ${HTTPS_PROXY}"
        fi
        if [ -n "${NO_PROXY}" ]; then
            curl_cmd="${curl_cmd} --noproxy ${NO_PROXY}"
        fi
        if [ -n "${PROXY_CA_CERTIFICATE_PATH}" ]; then
            curl_cmd="${curl_cmd} --cacert ${PROXY_CA_CERTIFICATE_PATH}"
        fi
    fi

    ${curl_cmd} "$@"
}

function ensure_govc_lib {
    if [[ "${SKIP_GOVC_DOWNLOAD}" =~ [Tt]rue ]]; then
        if ! [ -f "${GOVC_BIN}" ]; then
            echo "Error: govc binary download is skipped, but GOVC_BIN is not provided"
            exit 1
        else
            echo "GOVC is already in place: ${GOVC_BIN}"
            return
        fi
    fi

    if [ -z "${GOVC_BIN_OS_TAG}" ]; then
        GOVC_BIN_OS_TAG=$(uname -s)
    fi
    if [ -z "${GOVC_BIN_OS_ARCH}" ]; then
        GOVC_BIN_OS_ARCH=$(uname -m)
    fi

    local govc_bin_download_url govc_archive_name tempdir
    govc_bin_download_url="https://github.com/vmware/govmomi/releases/download/${GOVC_BIN_VERSION}/govc_${GOVC_BIN_OS_TAG}_${GOVC_BIN_OS_ARCH}.tar.gz"
    govc_archive_name=$(basename "${govc_bin_download_url}")
    tempdir=$("${mktemp_bin}" -d)

    _curl -fL -o "${tempdir}/${govc_archive_name}" "${govc_bin_download_url}"

    ${tar_bin} xzf "${tempdir}/${govc_archive_name}" -C "${tempdir}"
    mkdir -p "${GOVC_FOLDER}"
    mv "${tempdir}/govc" "${GOVC_FOLDER}"
    rm -rf "${tempdir}"
}

function verify_vsphere_objects {
    # Verify credentials
    ${GOVC_BIN} about
    # Verify objects:
    # 1. Datastore
    if [ -n "${VSPHERE_DATASTORE}" ]; then
        ${GOVC_BIN} datastore.info "${VSPHERE_DATASTORE}"
    fi
    if [ -n "${VSPHERE_DATASTORE_MGMT_CLUSTER}" ] && [ "${VSPHERE_DATASTORE_MGMT_CLUSTER}" != "${VSPHERE_DATASTORE}" ]; then
        ${GOVC_BIN} datastore.info "${VSPHERE_DATASTORE_MGMT_CLUSTER}"
    fi
    if [ -n "${VSPHERE_DATASTORE_CHILD_CLUSTER}" ] && [ "${VSPHERE_DATASTORE_CHILD_CLUSTER}" != "${VSPHERE_DATASTORE}" ]; then
        ${GOVC_BIN} datastore.info "${VSPHERE_DATASTORE_CHILD_CLUSTER}"
    fi
    # 2. Networks
    ${GOVC_BIN} object.collect "${VSPHERE_NETWORK_LCM}"
    ${GOVC_BIN} object.collect "${VSPHERE_NETWORK_OPENSTACK}"
    # 3. Resource pool
    ${GOVC_BIN} pool.info "${VSPHERE_RESOURCE_POOL}"
    # 4. Folder (create if does not exist)
    ${GOVC_BIN} folder.create "${VSPHERE_FOLDER}" || true
    # 5. VM image
    if [ -n "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH}" ]; then
        ${GOVC_BIN} datastore.ls -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH}"
    elif [ -n "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}" ]; then
        if ! [[ "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}" =~ .*\.vmdk ]]; then
            echo "Error: only VMDK image is supported"
            exit 1
        fi

        file "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}"
    else
        ${GOVC_BIN} vm.info "${VSPHERE_VM_TEMPLATE}"
    fi

    echo "Vsphere access has been verified"
}

function verify_mcc_vars {
    if [ "${MCC_CDN_REGION}" != "public" ] && [ -z "${MCC_RELEASES_URL}" ]; then
        echo "Error: MCC_RELEASES_URL must be provided for non-public CDN region"
        exit 1
    fi
    if [ "${MCC_CDN_REGION}" != "public" ] && [ -z "${MCC_VERSION}" ]; then
        echo "Error: MCC_VERSION must be provided for non-public CDN region"
        exit 1
    fi
    if [ -z "${MCC_LICENSE_FILE}" ] || ! [ -f "${MCC_LICENSE_FILE}" ]; then
        echo "Error MCC_LICENSE_FILE is not found"
        exit 1
    fi
}

function _set_tmpl_file_vars {
    # TODO: implement templating for userdata/metadata, e.g. jinja
    seed_userdata_file="${work_dir}/userdata.yaml"
    seed_userdata_file_tmpl="${script_dir}/userdata.yaml.tmpl"
    seed_metadata_file="${work_dir}/metadata.yaml"
    seed_metadata_file_tmpl="${script_dir}/metadata.yaml.tmpl"
    seed_network_config_file="${work_dir}/network_config"
    seed_network_config_file_tmpl="${script_dir}/network_config.tmpl"
}

function _set_ssh_public_key_var {
    export MCC_SSH_PUBLIC_KEY
    MCC_SSH_PUBLIC_KEY=$(cat "${SSH_PUBLIC_KEY_PATH}")
}

function prepare_ssh_key {
    if ! [ -f "${SSH_PRIVATE_KEY_PATH}" ]; then
        ${ssh_keygen_bin} -t rsa -f "${SSH_PRIVATE_KEY_PATH}" -P ""
    fi
    chmod 600 "${SSH_PRIVATE_KEY_PATH}"

    if ! [ -f "${SSH_PUBLIC_KEY_PATH}" ]; then
        ${ssh_keygen_bin} -f "${SSH_PRIVATE_KEY_PATH}" -y > "${SSH_PUBLIC_KEY_PATH}"
    fi

    # Prepare seed VM userdata
    _set_ssh_public_key_var

    # Generate password for seed node user
    seed_node_pwd_file="${work_dir}/seed_node_password"
    export SEED_NODE_PWD
    SEED_NODE_PWD=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 10; echo -n)
    echo "${SEED_NODE_PWD}" > "${seed_node_pwd_file}"
    echo "Password for user ${SEED_NODE_USER} is stored in ${seed_node_pwd_file}"

    _set_tmpl_file_vars
    render_template < "${seed_userdata_file_tmpl}" > "${seed_userdata_file}"

    echo "SSH key has been prepared"
}

function _set_vsphere_vm_vars {
    seed_folder="${VSPHERE_FOLDER}/seed"
    mgmt_folder="${VSPHERE_FOLDER}/management"
    child_folder="${VSPHERE_FOLDER}/child"

    seed_base_name="mcc-seed"
    mgmt_machine_name_prefix="mgmt-master"
    child_control_machine_name_prefix="child-control"
    child_worker_machine_name_prefix="child-worker"
    export vm_name_prefix_tmpl=""
    if [ -n "${VM_NAME_PREFIX}" ]; then
        vm_name_prefix_tmpl="${VM_NAME_PREFIX}-"
        seed_base_name="${VM_NAME_PREFIX}-${seed_base_name}"
        mgmt_machine_name_prefix="${VM_NAME_PREFIX}-${mgmt_machine_name_prefix}"
        child_control_machine_name_prefix="${VM_NAME_PREFIX}-${child_control_machine_name_prefix}"
        child_worker_machine_name_prefix="${VM_NAME_PREFIX}-${child_worker_machine_name_prefix}"
    fi
    seed_full_name="${seed_folder}/${seed_base_name}"

}

function prepare_seed_node_metadata {
    _set_tmpl_file_vars
    local metadata userdata
    export seed_mac_address network_lcm_mask encoded_network_config

    seed_mac_address="$(${GOVC_BIN} vm.info -json "${seed_full_name}" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"

    network_lcm_mask="$(echo "${NETWORK_LCM_SUBNET}" | awk -F "/" '{print $2}')"
    render_template < "${seed_network_config_file_tmpl}" > "${seed_network_config_file}"

    encoded_network_config=$(${base64_encode_cmd} < "${seed_network_config_file}")
    render_template < "${seed_metadata_file_tmpl}" > "${seed_metadata_file}"
    unset seed_mac_address network_lcm_mask encoded_network_config

    metadata="$(${base64_encode_cmd} < "${seed_metadata_file}")"
    userdata="$(${base64_encode_cmd} < "${seed_userdata_file}")"

    if [ -n "${metadata}" ]; then
        ${GOVC_BIN} vm.change -vm "${seed_full_name}" \
            -e guestinfo.metadata="${metadata}" \
            -e guestinfo.metadata.encoding="base64"
    fi

    if [ -n "${userdata}" ]; then
        ${GOVC_BIN} vm.change -vm "${seed_full_name}" \
            -e guestinfo.userdata="${userdata}" \
            -e guestinfo.userdata.encoding="base64"
    fi
}

function create_seed_vm {
    _print_header "${FUNCNAME[0]}"
    _set_vsphere_vm_vars

    ${GOVC_BIN} folder.info "${seed_folder}" || ${GOVC_BIN} folder.create "${seed_folder}"

    local vm_disk_name="${seed_base_name}/${seed_base_name}.vmdk"

    if [ -n "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}" ] && [ -z "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH}" ]; then
        local do_upload="true"
        local import_folder="mcc-seed-image"
        local import_file_name
        import_file_name="${import_folder}/$(basename "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}")"

        set +e
        # Do not fail if file is not found
        if ${GOVC_BIN} datastore.ls -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${import_file_name}"; then
            echo "Skipping uploaded because ${import_file_name} is already in place"
            do_upload="false"
        else
            echo "${import_file_name} is not found on datastore. Doing upload"
        fi
        set -e

        if [ "${do_upload}" == "true" ]; then
            ${GOVC_BIN} import.vmdk \
                -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" \
                -folder="${seed_folder}" \
                -pool "${VSPHERE_RESOURCE_POOL}" \
                "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}" \
                "${import_folder}"
        fi

        if ! ${GOVC_BIN} datastore.ls -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${seed_base_name}"; then
            ${GOVC_BIN} datastore.mkdir -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${seed_base_name}"
        fi
        ${GOVC_BIN} datastore.cp -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" \
            "${import_file_name}" \
            "${vm_disk_name}"
    fi

    if [ -n "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH}" ]; then
        if ! ${GOVC_BIN} datastore.ls -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${seed_base_name}"; then
            ${GOVC_BIN} datastore.mkdir -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${seed_base_name}"
        fi

        # Copy original disk to seed node disk
        ${GOVC_BIN} datastore.cp -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" \
            "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH}" "${vm_disk_name}"
    fi

    if [ -n "${VSPHERE_VMDK_IMAGE_DATASTORE_PATH}" ] || [ -n "${VSPHERE_VMDK_IMAGE_LOCAL_PATH}" ]; then
        # Default disk size is 10GiB which is too small
        ${GOVC_BIN} datastore.disk.extend -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" \
            -size="${SEED_NODE_DISK_SIZE}" "${vm_disk_name}"

        # Create seed node
        ${GOVC_BIN} vm.create -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" \
            -pool="${VSPHERE_RESOURCE_POOL}" \
            -folder="${seed_folder}" \
            -net="${VSPHERE_NETWORK_LCM}" \
            -on=false \
            -m="${SEED_NODE_MEMORY_MB}" \
            -c="${SEED_NODE_CPU_NUM}" \
            -disk="${vm_disk_name}" \
            "${seed_base_name}"

    else # VSPHERE_VM_TEMPLATE
        # Create seed node
        ${GOVC_BIN} vm.clone -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" \
            -pool="${VSPHERE_RESOURCE_POOL}"  \
            -vm="${VSPHERE_VM_TEMPLATE}" \
            -folder="${seed_folder}" \
            -net="${VSPHERE_NETWORK_LCM}" \
            -template=false \
            -on=false \
            -m="${SEED_NODE_MEMORY_MB}" \
            -c="${SEED_NODE_CPU_NUM}" \
            "${seed_base_name}"
    fi

    prepare_seed_node_metadata

    ${GOVC_BIN} vm.power -on "${seed_full_name}"

    echo "Seed node VM has been created: IP ${NETWORK_LCM_SEED_IP}"
}

function create_mgmt_cluster_vms {
    _print_header "${FUNCNAME[0]}"
    _set_vsphere_vm_vars

    ${GOVC_BIN} folder.info "${mgmt_folder}" || ${GOVC_BIN} folder.create "${mgmt_folder}"

    # Create management cluster VMs
    for (( num=0; num<3; num++ )); do
        machine_name="${mgmt_machine_name_prefix}-$num"
        ${GOVC_BIN} vm.create -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" \
            -pool="${VSPHERE_RESOURCE_POOL}"  \
            -folder "${mgmt_folder}" \
            -net "${VSPHERE_NETWORK_LCM}" \
            -on=false \
            -m="${MGMT_MACHINES_MEMORY_MB}" \
            -c="${MGMT_MACHINES_CPU_NUM}" \
            -disk="${MGMT_MACHINES_DISK_SIZE}" \
            "${machine_name}"

        ${GOVC_BIN} vm.change -vm "${mgmt_folder}/${machine_name}" -e disk.EnableUUID=TRUE
    done

    echo "Vsphere management cluster VMs have been created"
}

function create_child_cluster_vms {
    _print_header "${FUNCNAME[0]}"
    _set_vsphere_vm_vars

    ${GOVC_BIN} folder.info "${child_folder}" || ${GOVC_BIN} folder.create "${child_folder}"

    local disk_id
    # Create child cluster VMs for control plane
    for (( num=0; num<3; num++ )); do
        machine_name="${child_control_machine_name_prefix}-$num"
        ${GOVC_BIN} vm.create -ds="${VSPHERE_DATASTORE_CHILD_CLUSTER}" \
            -pool="${VSPHERE_RESOURCE_POOL}"  \
            -folder "${child_folder}" \
            -net "${VSPHERE_NETWORK_LCM}" \
            -on=false \
            -m="${CHILD_CONTROL_MACHINES_MEMORY_MB}" \
            -c="${CHILD_CONTROL_MACHINES_CPU_NUM}" \
            -disk="${CHILD_MACHINES_ROOT_DISK_SIZE}" \
            "${machine_name}"

        ${GOVC_BIN} vm.change -vm "${child_folder}/${machine_name}" -e disk.EnableUUID=TRUE
        disk_id="$(${GOVC_BIN} disk.create -ds="${VSPHERE_DATASTORE_CHILD_CLUSTER}" \
            -size "${CHILD_MACHINES_CEPH_DISK_SIZE}" "${machine_name}-disk-2" | tail -n 1)"
        ${GOVC_BIN} disk.attach -vm "${child_folder}/${machine_name}" -ds="${VSPHERE_DATASTORE_CHILD_CLUSTER}" "${disk_id}"
        ${GOVC_BIN} vm.network.add -net "${VSPHERE_NETWORK_OPENSTACK}" -vm "${child_folder}/${machine_name}"
    done

    # Create child cluster VMs for workers/computes
    for (( num=0; num<3; num++ )); do
        machine_name="${child_worker_machine_name_prefix}-$num"
        ${GOVC_BIN} vm.create -ds="${VSPHERE_DATASTORE_CHILD_CLUSTER}" \
            -pool="${VSPHERE_RESOURCE_POOL}"  \
            -folder "${child_folder}" \
            -net "${VSPHERE_NETWORK_LCM}" \
            -on=false \
            -m="${CHILD_WORKER_MACHINES_MEMORY_MB}" \
            -c="${CHILD_WORKER_MACHINES_CPU_NUM}" \
            -disk="${CHILD_MACHINES_ROOT_DISK_SIZE}" \
            "${machine_name}"

        ${GOVC_BIN} vm.change -vm "${child_folder}/${machine_name}" -e disk.EnableUUID=TRUE -nested-hv-enabled TRUE
        disk_id="$(${GOVC_BIN} disk.create -ds="${VSPHERE_DATASTORE_CHILD_CLUSTER}" \
            -size "${CHILD_MACHINES_CEPH_DISK_SIZE}" "${machine_name}-disk-2" | tail -n 1)"
        ${GOVC_BIN} disk.attach -vm "${child_folder}/${machine_name}" -ds="${VSPHERE_DATASTORE_CHILD_CLUSTER}" "${disk_id}"
        ${GOVC_BIN} vm.network.add -net "${VSPHERE_NETWORK_OPENSTACK}" -vm "${child_folder}/${machine_name}"
    done

    echo "Vsphere child cluster VMs have been created"
}

function wait_for_seed_ssh_available {
    local num_attepts=30
    while [ ${num_attepts} -ne 0 ]; do
        echo "Trying ssh to seed node: ${NETWORK_LCM_SEED_IP}"
        res=$(${ssh_bin} -o ConnectTimeout=5 -i "${SSH_PRIVATE_KEY_PATH}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}" echo ok || true)
        if [ "${res}" == "ok" ]; then
            return
        fi

        num_attepts=$((num_attepts-1))
        if [ ${num_attepts} -eq 0 ]; then
            echo "Error: timeout waiting for ssh to be available"
            exit 1
        fi
        sleep 5
    done
}

function prepare_mgmt_cluster_templates {
    _print_header "${FUNCNAME[0]}"
    _set_vsphere_vm_vars
    export mgmt_node_mac_address_0 mgmt_node_mac_address_1 mgmt_node_mac_address_2
    mgmt_node_mac_address_0="$(${GOVC_BIN} vm.info -json "${mgmt_folder}/${mgmt_machine_name_prefix}-0" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"
    mgmt_node_mac_address_1="$(${GOVC_BIN} vm.info -json "${mgmt_folder}/${mgmt_machine_name_prefix}-1" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"
    mgmt_node_mac_address_2="$(${GOVC_BIN} vm.info -json "${mgmt_folder}/${mgmt_machine_name_prefix}-2" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"

    if [ -z "${MCC_SERVICEUSER_PASSWORD}" ]; then
        MCC_SERVICEUSER_PASSWORD=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 10; echo)
    fi

    _set_ssh_public_key_var
    _set_templates_dir_vars
    rm -rf "${mgmt_templates_work_dir}" && mkdir -p "${mgmt_templates_work_dir}"

    # Management cluster templates
    local f_b_name
    # shellcheck disable=SC2044
    for file in $(find "${mgmt_templates_local_dir}" -type f  -name "*.template"); do
        f_b_name=$(basename "${file}")
        render_template < "${file}" > "${mgmt_templates_work_dir}/${f_b_name}"
        ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${mgmt_templates_work_dir}/${f_b_name}" \
            "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${mgmt_templates_remote_dir}"
    done
}

function prepare_child_cluster_templates {
    _print_header "${FUNCNAME[0]}"
    # shellcheck source=/dev/null
    [ -f "${mcc_version_file}" ] && source "${mcc_version_file}"
    if [ -z "${MCC_VERSION}" ]; then
        echo "Error: MCC_VERSION is not set. Unable to prepare management cluster templates"
        exit 1
    fi

    _set_vsphere_vm_vars
    export child_control_mac_address_0 child_control_mac_address_1 child_control_mac_address_2
    child_control_mac_address_0="$(${GOVC_BIN} vm.info -json "${child_folder}/${child_control_machine_name_prefix}-0" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"
    child_control_mac_address_1="$(${GOVC_BIN} vm.info -json "${child_folder}/${child_control_machine_name_prefix}-1" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"
    child_control_mac_address_2="$(${GOVC_BIN} vm.info -json "${child_folder}/${child_control_machine_name_prefix}-2" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"

    export child_worker_mac_address_0 child_worker_mac_address_1 child_worker_mac_address_2
    child_worker_mac_address_0="$(${GOVC_BIN} vm.info -json "${child_folder}/${child_worker_machine_name_prefix}-0" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"
    child_worker_mac_address_1="$(${GOVC_BIN} vm.info -json "${child_folder}/${child_worker_machine_name_prefix}-1" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"
    child_worker_mac_address_2="$(${GOVC_BIN} vm.info -json "${child_folder}/${child_worker_machine_name_prefix}-2" \
        | ${jq_bin} -r '.virtualMachines[0].config.hardware.device[] | select (.deviceInfo.label == "Network adapter 1") | .macAddress')"

    _set_bootstrap_vars

    if [ -z "${MCC_CHILD_CLUSTER_RELEASE}" ]; then
        MCC_CHILD_CLUSTER_RELEASE="$(${ssh_cmd} "/home/${SEED_NODE_USER}/yq" \
            eval '.spec.supportedClusterReleases[0].name' \
            "/home/${SEED_NODE_USER}/kaas-bootstrap/releases/kaas/${MCC_VERSION}.yaml")"
    fi

    _set_ssh_public_key_var
    _set_templates_dir_vars
    rm -rf "${child_templates_work_dir}" && mkdir -p "${child_templates_work_dir}"
    ${ssh_cmd} mkdir -p "${child_templates_remote_dir}"

    local f_b_name
    # shellcheck disable=SC2044
    for file in $(find "${child_templates_local_dir}" -maxdepth 1 -type f  -name "*.template"); do
        f_b_name=$(basename "${file}")
        render_template < "${file}" > "${child_templates_work_dir}/${f_b_name%.tmpl}"
        ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${child_templates_work_dir}/${f_b_name%.tmpl}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${child_templates_remote_dir}"
    done

    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" -r "${child_templates_local_dir}/certs" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${child_templates_remote_dir}/certs"
    ${ssh_cmd} chmod +x "${child_templates_remote_dir}/certs/create_secrets.sh"

    cp -r "${child_templates_local_dir}/hack" "${child_templates_work_dir}/hack"
}

function setup_seed {
    local prepare_env_file="${work_dir}/.prepare_seed_node.env"
    local remote_proxy_cert_file=""
    if { [ -n "${HTTP_PROXY}" ] || [ -n "${HTTPS_PROXY}" ] ;} && [ -n "${PROXY_CA_CERTIFICATE_PATH}" ]; then
        remote_proxy_cert_file="/home/${SEED_NODE_USER}/$(basename "${PROXY_CA_CERTIFICATE_PATH}")"
        ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${PROXY_CA_CERTIFICATE_PATH}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${remote_proxy_cert_file}"
    fi

    cat << EOF > "${prepare_env_file}"
#!/bin/bash
export HTTPS_PROXY="${HTTPS_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export NO_PROXY="${NO_PROXY}"
export PROXY_CA_CERTIFICATE_PATH="${remote_proxy_cert_file}"

export MCC_CDN_REGION="${MCC_CDN_REGION}"
export MCC_CDN_BASE_URL="${MCC_CDN_BASE_URL}"
export MCC_RELEASES_URL="${MCC_RELEASES_URL}"
export SEED_NODE_USER="${SEED_NODE_USER}"

export YQ_VERSION="${YQ_VERSION}"
EOF

    if [ -n "${MCC_VERSION}" ]; then
        echo "export MCC_VERSION=${MCC_VERSION}" >> "${prepare_env_file}"
    fi

    local ssh_cmd="${ssh_bin} -i ${SSH_PRIVATE_KEY_PATH} ${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}"
    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${script_dir}/bin/prepare_seed_node.sh" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:"
    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${prepare_env_file}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:"
    ${ssh_cmd} chmod +x prepare_seed_node.sh
    ${ssh_cmd} bash -x prepare_seed_node.sh
    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${MCC_LICENSE_FILE}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:/home/${SEED_NODE_USER}/mirantis.lic"
    if [ -z "${MCC_VERSION}" ]; then
        export MCC_VERSION
        MCC_VERSION="$(${ssh_cmd} cat mcc_version)"
    fi

    # Keep state: MCC_VERSION
    echo "export MCC_VERSION=${MCC_VERSION}" > "${mcc_version_file}"
}

function setup_bootstrap_cluster {
    _print_header "${FUNCNAME[0]}"
    # shellcheck source=/dev/null
    [ -f "${mcc_version_file}" ] && source "${mcc_version_file}"

    local ssh_cmd="${ssh_bin} -i ${SSH_PRIVATE_KEY_PATH} ${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}"
    local bootstrap_env_file_name="bootstrap.env"
    local bootstrap_env_file="${work_dir}/${bootstrap_env_file_name}"
    local remote_proxy_cert_file=""
    local network_pxe_mask
    network_pxe_mask="$(echo "${NETWORK_PXE_SUBNET}" | awk -F "/" '{print $2}')"
    if { [ -n "${HTTP_PROXY}" ] || [ -n "${HTTPS_PROXY}" ] ;} && [ -n "${PROXY_CA_CERTIFICATE_PATH}" ]; then
        remote_proxy_cert_file="/home/${SEED_NODE_USER}/$(basename "${PROXY_CA_CERTIFICATE_PATH}")"
    fi

    # Note: bootstrap script requires KAAS_CDN_REGION, not MCC_CDN_REGION
    cat << EOF > "${bootstrap_env_file}"
export KAAS_RELEASE_YAML="/home/${SEED_NODE_USER}/kaas-bootstrap/releases/kaas/${MCC_VERSION}.yaml"
export CLUSTER_RELEASES_DIR="/home/${SEED_NODE_USER}/kaas-bootstrap/releases/cluster"
export KAAS_CDN_REGION="${MCC_CDN_REGION}"

export HTTPS_PROXY=${HTTPS_PROXY}
export HTTP_PROXY="${HTTP_PROXY}"
export NO_PROXY="${NO_PROXY}"
export PROXY_CA_CERTIFICATE_PATH="${remote_proxy_cert_file}"

export KAAS_BM_ENABLED="true"
export KAAS_BM_PXE_BRIDGE=${SEED_NODE_PXE_BRIDGE}
export KAAS_BM_PXE_IP=${NETWORK_PXE_BRIDGE_IP}
export KAAS_BM_PXE_MASK=${network_pxe_mask}
export KAAS_BOOTSTRAP_DEBUG="${MCC_DEMO_DEBUG}"
EOF

    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${bootstrap_env_file}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:/home/${SEED_NODE_USER}/kaas-bootstrap/${bootstrap_env_file_name}"

    ${ssh_cmd} "/home/${SEED_NODE_USER}/kaas-bootstrap/bootstrap.sh" bootstrapv2
}

function _set_bootstrap_vars {
    ssh_cmd="${ssh_bin} -i ${SSH_PRIVATE_KEY_PATH} ${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}"
    kubectl_file_var="KUBECONFIG=/home/${SEED_NODE_USER}/.kube/kind-config-clusterapi"
    remote_kubectl_cmd="${ssh_cmd} ${kubectl_file_var} /home/${SEED_NODE_USER}/kaas-bootstrap/bin/kubectl"
    remote_container_cloud_cmd="${ssh_cmd} ${kubectl_file_var} /home/${SEED_NODE_USER}/kaas-bootstrap/container-cloud"
    remote_kind_cmd="${ssh_cmd} /home/${SEED_NODE_USER}/kaas-bootstrap/bin/kind"
}

function _set_mgmt_vars {
    ssh_cmd="${ssh_bin} -i ${SSH_PRIVATE_KEY_PATH} ${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}"
    kubectl_file_var="KUBECONFIG=/home/${SEED_NODE_USER}/kaas-bootstrap/kubeconfig-${MCC_MGMT_CLUSTER_NAME}"
    remote_kubectl_cmd="${ssh_cmd} ${kubectl_file_var} /home/${SEED_NODE_USER}/kaas-bootstrap/bin/kubectl"
    remote_container_cloud_cmd="${ssh_cmd} ${kubectl_file_var} /home/${SEED_NODE_USER}/kaas-bootstrap/container-cloud"
}

function _set_child_vars {
    ssh_cmd="${ssh_bin} -i ${SSH_PRIVATE_KEY_PATH} ${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}"
    kubectl_file_var="KUBECONFIG=/home/${SEED_NODE_USER}/kaas-bootstrap/kubeconfig-${MCC_CHILD_CLUSTER_NAME}"
    remote_kubectl_cmd="${ssh_cmd} ${kubectl_file_var} /home/${SEED_NODE_USER}/kaas-bootstrap/bin/kubectl"
    remote_container_cloud_cmd="${ssh_cmd} ${kubectl_file_var} /home/${SEED_NODE_USER}/kaas-bootstrap/container-cloud"
}

function _set_templates_dir_vars {
    # shellcheck source=/dev/null
    [ -f "${mcc_version_file}" ] && source "${mcc_version_file}"
    if [ -z "${MCC_VERSION}" ]; then
        echo "Error: MCC_VERSION is not set. Unable to set templates vars"
        exit 1
    fi

    mgmt_templates_work_dir="${work_dir}/templates/management"
    mgmt_templates_local_dir="${script_dir}/templates/${MCC_VERSION%-rc}/management/"
    mgmt_templates_remote_dir="/home/${SEED_NODE_USER}/kaas-bootstrap/templates/bm"

    child_templates_work_dir="${work_dir}/templates/child/"
    child_templates_local_dir="${script_dir}/templates/${MCC_VERSION%-rc}/child/"
    child_templates_remote_dir="/home/${SEED_NODE_USER}/kaas-bootstrap/templates/bm/child"
}

function deploy_mgmt_cluster {
    _print_header "${FUNCNAME[0]}"
    _set_bootstrap_vars
    _set_templates_dir_vars

    echo "Creating management cluster objects"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/bootstrapregion.yaml.template"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/serviceusers.yaml.template"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/sshkey.yaml.template"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/cluster.yaml.template"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/metallbconfig.yaml.template"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/ipam-objects.yaml.template"

    # wait for VBMC crd
    echo "Waiting for vbmcs crd"
    _wait_for_object_status "crds" "vbmcs.metal3.io" "" ".status.conditions[].status" "True" 15 "plain"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/vbmc.yaml.template"

    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/baremetalhostprofiles.yaml.template"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/baremetalhosts.yaml.template"
    ${remote_kubectl_cmd} apply -f "${mgmt_templates_remote_dir}/machines.yaml.template"

    # wait for ironic start, so provisioning artifacts are downloaded
    echo "Waiting for Ironic deployment"
    _wait_for_object_status "deployment" "ironic" "kaas" ".status.readyReplicas" "1" "${IRONIC_DEPLOYMENT_TIMEOUT}" "plain"

    # wait for bmh
    echo "Waiting for Baremetal hosts provisioning"
    local bmh_names
    bmh_names=$(${remote_kubectl_cmd} get bmh -o jsonpath='{.items[*].metadata.name}')
    _wait_for_objects_statuses "bmh" "${bmh_names}" "" ".status.provisioning.state" "available,provisioned" "${BMH_READINESS_TIMEOUT}"

    # start deployment
    echo "Starting MCC management cluster deployment"
    ${remote_container_cloud_cmd} bootstrap approve all

    wait_for_mgmt_cluster

    cleanup_bootstrap_cluster
}

function apply_coredns_hack {
    _print_header "${FUNCNAME[0]}"
    _set_child_vars
    _set_templates_dir_vars
    # Patch Coredns configmap
    local hack_dir="${child_templates_work_dir}/hack"
    local cm_file="${hack_dir}/coredns.cm.yaml"
    local remote_cm_file="${child_templates_remote_dir}/coredns.cm.yaml"
    local cm_content_file="${hack_dir}/coredns.cm.tmp"

    export cm_hack_value coredns_cm_content
    # Get current config and insert hack for hosts substitution
    ${remote_kubectl_cmd} -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' \
        | sed 's/^/    /' | awk 'NR==2{print "\{\{ cm_hack_value \}\}"}1' > "${cm_content_file}"
    # Update hosts
    cm_hack_value="$(render_template < "${hack_dir}/coredns.cm.hosts")"
    # Update configmap content value
    coredns_cm_content="$(render_template < "${cm_content_file}")"
    # Update configmap template
    render_template < "${hack_dir}/coredns.cm.template" > "${cm_file}"
    # Copy template to seed node and apply
    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${cm_file}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${remote_cm_file}"
    ${remote_kubectl_cmd} apply -f "${remote_cm_file}"
    unset cm_hack_value coredns_cm_content

    # Note: CoreDNS config is reloaded automatically
}

function deploy_child_cluster {
    _print_header "${FUNCNAME[0]}"
    _set_mgmt_vars
    _set_templates_dir_vars

    echo "Creating child cluster objects"
    ${remote_kubectl_cmd} get namespace "${MCC_CHILD_CLUSTER_NAMESPACE}" || \
        ${remote_kubectl_cmd} create namespace "${MCC_CHILD_CLUSTER_NAMESPACE}"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/sshkey.yaml.template"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/cluster.yaml.template"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/metallbconfig.yaml.template"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/ipam-objects.yaml.template"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/baremetalhostprofiles.yaml.template"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/baremetalhosts.yaml.template"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/machines.yaml.template"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/kaascephcluster.yaml.template"

    echo "MCC child cluster deployment has been started"

    # wait for bmh
    echo "Waiting for Baremetal hosts provisioning"
    local bmh_names
    bmh_names=$(${remote_kubectl_cmd} -n "${MCC_CHILD_CLUSTER_NAMESPACE}" get bmh -o jsonpath='{.items[*].metadata.name}')
    _wait_for_objects_statuses "bmh" "${bmh_names}" "${MCC_CHILD_CLUSTER_NAMESPACE}" ".status.provisioning.state" "available,provisioned" "${BMH_READINESS_TIMEOUT}"

    echo "Waiting for child cluster deployment"
    wait_for_child_cluster

    echo "Waiting for Ceph"
    _wait_for_object_status kaascephcluster "ceph-${MCC_CHILD_CLUSTER_NAME}" "${MCC_CHILD_CLUSTER_NAMESPACE}" ".status.shortClusterInfo.state" \
        "Ready" "${CHILD_CEPH_CLUSTER_TIMEOUT}" "plain"
    echo "Ceph cluster is ready"

    echo "Child cluster deployment has been finished successfully"
}

function deploy_openstack {
    _print_header "${FUNCNAME[0]}"
    _set_templates_dir_vars
    _set_child_vars

    ${ssh_cmd} "KUBECTL_BIN=/home/${SEED_NODE_USER}/kaas-bootstrap/bin/kubectl \
        ${kubectl_file_var}" "${child_templates_remote_dir}/certs/create_secrets.sh"
    ${remote_kubectl_cmd} apply -f "${child_templates_remote_dir}/osdpl.yaml.template"

    echo "Waiting for Openstack"
    _wait_for_object_status openstackdeploymentstatus osh-dev openstack ".status.osdpl.state" "APPLIED" "${OSDPL_APPLIED_TIMEOUT}" "plain"
    # Wait till all the Openstack components will be ready
    _wait_for_object_status openstackdeploymentstatus osh-dev openstack ".status.health.*.*.status" '^Ready( Ready)*$' "${OPENSTACK_READINESS_TIMEOUT}" "regex"
    echo "Openstack Deployment has been completed"

    # Note: custom Openstack hostnames have to be resolved inside child cluster,
    # otherwise the Openstack endpoints are not accessible.
    # If user adds Openstack endpoints to the DNS, the hack is not needed
    if [[ "${APPLY_COREDNS_HACK}" =~ [Tt]rue ]]; then
        apply_coredns_hack
    fi

    local c_y_file="${work_dir}/cloud.yaml"
    ${remote_kubectl_cmd} -n openstack-external get secrets openstack-identity-credentials \
        -o jsonpath='{.data.clouds\\.yaml}' | base64 -d > "${c_y_file}"

    echo "Openstack deployment has been finished successfully"
    echo "Please add following line to your /etc/hosts configuration to access Openstack Web UI"
    echo "${NETWORK_LCM_METALLB_OPENSTACK_ADDRESS} \
        keystone.${MCC_OPENSTACK_PUBLIC_DOMAIN} \
        horizon.${MCC_OPENSTACK_PUBLIC_DOMAIN} \
        nova.${MCC_OPENSTACK_PUBLIC_DOMAIN} \
        novncproxy.${MCC_OPENSTACK_PUBLIC_DOMAIN}"
    echo "Openstack Web UI: https://horizon.${MCC_OPENSTACK_PUBLIC_DOMAIN}"
    echo "Openstack credentials are saved into ${c_y_file} on local machine"
}

function wait_for_mgmt_cluster {
    _set_bootstrap_vars
    # wait for cluster readiness
    _wait_for_object_status cluster "${MCC_MGMT_CLUSTER_NAME}" "" ".status.providerStatus.ready" "true"\
        "${MGMT_CLUSTER_READINESS_TIMEOUT}" "plain"

    local k_f_name_local="${work_dir}/kubeconfig-${MCC_MGMT_CLUSTER_NAME}"
    local k_f_name_remote="/home/${SEED_NODE_USER}/kaas-bootstrap/kubeconfig-${MCC_MGMT_CLUSTER_NAME}"
    ${remote_container_cloud_cmd} get cluster-kubeconfig \
        --cluster-name="${MCC_MGMT_CLUSTER_NAME}" --kubeconfig-output="${k_f_name_remote}"
    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${k_f_name_remote}" "${k_f_name_local}"

    echo "Management cluster kubeconfig is saved localy to ${k_f_name_local}"
}

function wait_for_child_cluster {
    _set_mgmt_vars
    _wait_for_object_status cluster "${MCC_CHILD_CLUSTER_NAME}" "${MCC_CHILD_CLUSTER_NAMESPACE}" ".status.providerStatus.ready" "true" \
        "${CHILD_CLUSTER_READINESS_TIMEOUT}" "plain"

    local k_f_name_local="${work_dir}/kubeconfig-${MCC_CHILD_CLUSTER_NAME}"
    local k_f_name_remote="/home/${SEED_NODE_USER}/kaas-bootstrap/kubeconfig-${MCC_CHILD_CLUSTER_NAME}"
    ${remote_kubectl_cmd} -n "${MCC_CHILD_CLUSTER_NAMESPACE}" get secret "${MCC_CHILD_CLUSTER_NAME}-kubeconfig" \
        -o jsonpath='{.data.admin\\.conf}' | base64 -d | tee "${k_f_name_local}"
    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${k_f_name_local}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${k_f_name_remote}"

    echo "Child cluster kubeconfig is saved localy to ${k_f_name_local}"
}

function _wait_for_objects_statuses {
    if [ $# -ne 6 ]; then
        echo "Error: _wait_for_objects_statuses requires exactly 6 arguments"
        exit 1
    fi

    local obj_type="${1}"
    local obj_names="${2}"
    local obj_namespace="${3}"
    if [ -n "${obj_namespace}" ]; then
        obj_namespace="-n ${obj_namespace}"
    fi
    local obj_status_path="${4}"
    # Delimited by ,
    local obj_expected_statuses_pattern
    obj_expected_statuses_pattern="^($(echo "${5}" | tr "," "|"))$"
    local num_attepts=${6}

    while [ "${num_attepts}" -ne 0 ]; do
        local all_ready=true
        for obj_name in ${obj_names}; do
            set +e
            status="$(${remote_kubectl_cmd} "${obj_namespace}" get "${obj_type}" "${obj_name}" -o jsonpath="{${obj_status_path}}")"
            set -e
            echo "${obj_type} ${obj_name} status: ${status}. Expected status: ${obj_expected_statuses_pattern}"
            if [[ ! "${status}" =~ ${obj_expected_statuses_pattern} ]]; then
                all_ready=false
            fi
        done

        if [ "${all_ready}" == "true" ]; then
            echo "All ${obj_type}s are ready"
            break
        fi

        num_attepts=$((num_attepts-1))
        echo "Left attemtps: ${num_attepts}"
        if [ ${num_attepts} -eq 0 ]; then
            echo "Error: timeout waiting for ${obj_type}s to be available"
            exit 1
        fi
        sleep 60
    done
}

function _wait_for_object_status {
    if ! [ $# -eq 7 ]; then
        echo "Error: _wait_for_object_status requires exactly 7 arguments"
        exit 1
    fi

    local obj_type="${1}"
    local obj_name="${2}"
    local obj_namespace="${3}"
    if [ -n "${obj_namespace}" ]; then
        obj_namespace="-n ${obj_namespace}"
    fi
    local obj_status_path="${4}"
    local obj_expected_status="${5}"
    local num_attepts=${6}
    local compare_mode=${7}

    while [ "${num_attepts}" -ne 0 ]; do
        set +e
        status="$(${remote_kubectl_cmd} "${obj_namespace}" get "${obj_type}" "${obj_name}" -o jsonpath="{${obj_status_path}}")"
        set -e
        echo "${obj_type} ${obj_name} status: ${status}. Expected status: ${obj_expected_status}"
        if [ "${compare_mode}" == 'regex' ]; then
            if [[ "${status}" =~ ${obj_expected_status} ]]; then
                break
            fi
        else
            if [ "${status}" == "${obj_expected_status}" ]; then
                break
            fi
        fi

        num_attepts=$((num_attepts-1))
        echo "Left attemtps: ${num_attepts}"
        if [ "${num_attepts}" -eq 0 ]; then
            echo "Error: timeout waiting for ${obj_type} ${obj_name} status"
            exit 1
        fi
        sleep 60
    done

    echo "${obj_type} ${obj_name} is ready"
}

function cleanup {
    echo "Starting cleanup"
    if ! [ -f "${GOVC_BIN}" ]; then
        echo "Error: govc binary is not found. Cleanup is not possible"
        exit 1
    fi
    _set_vsphere_vm_vars

    local mgmt_cluster_vms child_cluster_vms seed_vm
    mgmt_cluster_vms=$(${GOVC_BIN} ls "${mgmt_folder}")
    child_cluster_vms=$(${GOVC_BIN} ls "${child_folder}")
    seed_vm=$(${GOVC_BIN} ls "${seed_folder}")

    # shellcheck disable=SC2116
    for vm in $(echo "${mgmt_cluster_vms}" "${child_cluster_vms}" "${seed_vm}"); do
        ${GOVC_BIN} vm.power -off -force "${vm}"
        # Note: all disks are deleted with VM automatically
        ${GOVC_BIN} vm.destroy "${vm}"
    done

    local seed_disk_name="${seed_base_name}/${seed_base_name}.vmdk"
    # Ensure seed disk is removed
    if ${GOVC_BIN} datastore.ls -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${seed_disk_name}"; then
        ${GOVC_BIN} datastore.rm -ds="${VSPHERE_DATASTORE_MGMT_CLUSTER}" "${seed_disk_name}"
    fi

    rm -rf "${work_dir}"

    echo "Cleanup has been finished successfully"
}

function collect_logs() {
    if ! [ $# -eq 1 ]; then
        echo "Error: ${FUNCNAME[0]} requires exactly 1 argument"
        exit 1
    fi
    local seed_node_ssh_key_path mgmt_kubeconfig_path
    seed_node_ssh_key_path="/home/${SEED_NODE_USER}/.ssh/$(basename "${SSH_PRIVATE_KEY_PATH}")"
    mgmt_kubeconfig_path="/home/${SEED_NODE_USER}/kaas-bootstrap/kubeconfig-${MCC_MGMT_CLUSTER_NAME}"
    # Copy SSH_PRIVATE_KEY_PATH to seed node
    ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${SSH_PRIVATE_KEY_PATH}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${seed_node_ssh_key_path}"

    if [ "$1" == 'mgmt' ]; then
        _set_mgmt_vars
        local log_dir="/home/${SEED_NODE_USER}/mgmt_logs"
        ${ssh_cmd} "test -d ${log_dir} && rm -rf ${log_dir} || true"
        ${remote_container_cloud_cmd} collect logs --cluster-name "${MCC_MGMT_CLUSTER_NAME}" --cluster-namespace default \
            --key-file "${seed_node_ssh_key_path}" --management-kubeconfig "${mgmt_kubeconfig_path}" --output-dir "${log_dir}" --extended
        ${ssh_cmd} "chmod -R +r ${log_dir}; tar czf ${log_dir}.tgz ${log_dir}"
        ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${log_dir}.tgz" "${work_dir}/"
    elif [ "$1" == 'child' ]; then
        _set_child_vars
        local log_dir="/home/${SEED_NODE_USER}/child_logs"
        ${ssh_cmd} "test -d ${log_dir} && rm -rf ${log_dir} || true"
        ${remote_container_cloud_cmd} collect logs --cluster-name "${MCC_CHILD_CLUSTER_NAME}" --cluster-namespace "${MCC_CHILD_CLUSTER_NAMESPACE}" \
            --key-file "${seed_node_ssh_key_path}" --management-kubeconfig "${mgmt_kubeconfig_path}" --output-dir "${log_dir}" --extended
        ${ssh_cmd} "chmod -R +r ${log_dir}; tar czf ${log_dir}.tgz ${log_dir}"
        ${scp_bin} -i "${SSH_PRIVATE_KEY_PATH}" "${SEED_NODE_USER}@${NETWORK_LCM_SEED_IP}:${log_dir}.tgz" "${work_dir}/"
    else
        echo "${FUNCNAME[0]} takes only 'mgmt' or 'child' values for its parameter"
        exit 1
    fi
}

function cleanup_bootstrap_cluster {
    _set_bootstrap_vars
    ${remote_kind_cmd} delete cluster --name clusterapi
}

function main {
    local arg
    if [ $# -ne 0 ]; then
        arg="${1}"
        shift
    fi

    if [ -f "${ENV_FILE}" ]; then
        # shellcheck source=/dev/null
        chmod +x "${ENV_FILE}" && source "${ENV_FILE}"
    fi

    if [[ "${MCC_DEMO_DEBUG}" =~ [Tt]rue ]]; then
        set -x
    fi

    case "${arg}" in
        -h|help)
            usage
            exit 0
            ;;
        cleanup)
            verify_binaries
            set_vars
            ensure_govc_lib
            verify_vsphere_objects
            cleanup
            exit 0
            ;;
        cleanup_bootstrap_cluster)
            verify_binaries
            set_vars
            cleanup_bootstrap_cluster
            exit 0
            ;;
        create_seed_vm)
            verify_binaries
            set_vars
            ensure_govc_lib
            verify_vsphere_objects
            verify_mcc_vars
            prepare_ssh_key
            create_seed_vm
            wait_for_seed_ssh_available
            setup_seed
            exit 0
            ;;
        setup_bootstrap_cluster)
            verify_binaries
            set_vars
            verify_mcc_vars
            setup_bootstrap_cluster
            exit 0
            ;;
        create_mgmt_cluster_vms)
            verify_binaries
            set_vars
            if [[ "${SKIP_VSPHERE_VMS_CREATION}" =~ [Tt]rue ]]; then
                echo "Skipping create_mgmt_cluster_vms action: SKIP_VSPHERE_VMS_CREATION=True"
                exit 0
            fi
            ensure_govc_lib
            verify_vsphere_objects
            verify_mcc_vars
            create_mgmt_cluster_vms
            exit 0
            ;;
        create_child_cluster_vms)
            verify_binaries
            set_vars
            if [[ "${SKIP_VSPHERE_VMS_CREATION}" =~ [Tt]rue ]]; then
                echo "Skipping create_child_cluster_vms action: SKIP_VSPHERE_VMS_CREATION=True"
                exit 0
            fi
            ensure_govc_lib
            verify_vsphere_objects
            verify_mcc_vars
            create_child_cluster_vms
            exit 0
            ;;
        prepare_mgmt_cluster_templates)
            verify_binaries
            set_vars
            ensure_govc_lib
            prepare_mgmt_cluster_templates
            exit 0
            ;;
        prepare_child_cluster_templates)
            verify_binaries
            set_vars
            ensure_govc_lib
            prepare_child_cluster_templates
            exit 0
            ;;
        deploy_mgmt_cluster)
            verify_binaries
            set_vars
            deploy_mgmt_cluster
            exit 0
            ;;
        deploy_child_cluster)
            verify_binaries
            set_vars
            deploy_child_cluster
            exit 0
            ;;
        deploy_openstack)
            verify_binaries
            set_vars
            deploy_openstack
            exit 0
            ;;
        apply_coredns_hack)
            set_vars
            apply_coredns_hack
            exit 0
            ;;
        collect_mgmt_cluster_logs)
            verify_binaries
            set_vars
            collect_logs mgmt
            exit 0
            ;;
        collect_child_cluster_logs)
            verify_binaries
            set_vars
            collect_logs child
            exit 0
            ;;
        collect_logs)
            verify_binaries
            set_vars
            collect_logs mgmt
            collect_logs child
            exit 0
            ;;
        all)
            verify_binaries
            set_vars
            ensure_govc_lib
            verify_vsphere_objects

            verify_mcc_vars

            prepare_ssh_key

            if ! [[ "${SKIP_VSPHERE_VMS_CREATION}" =~ [Tt]rue ]]; then
                if ! [[ "${SKIP_SEED_NODE_CREATION}" =~ [Tt]rue ]]; then
                    create_seed_vm
                fi
                create_mgmt_cluster_vms
                create_child_cluster_vms
            fi

            wait_for_seed_ssh_available

            if ! [[ "${SKIP_SEED_NODE_SETUP}" =~ [Tt]rue ]]; then
                setup_seed
            fi

            prepare_mgmt_cluster_templates

            setup_bootstrap_cluster

            prepare_child_cluster_templates

            deploy_mgmt_cluster

            deploy_child_cluster

            deploy_openstack

            echo "MCC installation has been finished successfully"
            exit 0
            ;;
        *)
            echo "Wrong option is passed"
            usage
            exit 1
            ;;
    esac
}

main "$@"
