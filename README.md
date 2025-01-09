# TryMOSK for on-premise self-evaluation

This project is developed for demo purposes on
[Mirantis Container Cloud (MCC)](https://docs.mirantis.com/container-cloud/latest/overview.html)
and
[Mirantis OpenStack for Kubernetes (MOSK)](https://docs.mirantis.com/mosk/latest/overview.html)
products on top of the vSphere infrastructure.

## Requirements

The project contains scripts for automated deployment of an MCC management cluster
MOSK managed cluster. The workflow of scripts is as follows:

- Create subfolders in the provided `VSPHERE_FOLDER` for VM placement.
- Create the MCC seed VM with the bootstrap cluster and minimal set of components
  that require the following resources: 8 CPUs, 16 GB of RAM, 30 GiB disk.
- Create 3 VMs for a management cluster that requires the following resources:
   - 8 CPUs
   - 32 GB of RAM
   - Single 150 GiB disk
   - Attach to Life-Cycle Management (LCM) network
- Create 6 VMs for a managed cluster containing 3 control plane and 3 worker nodes
  that requires the following resources:
  - 8 CPUs and 24 GB RAM for control plane nodes
  - 8 CPUs and 16 GB RAM for worker nodes
  - 2 disks: 80 GiB for root partition and 40 GiB for Ceph storage
  - 2 networks: LCM and OpenStack
- Manage MCC and MOSK cluster deployment.
- Save deployment artifacts.
- Provide access to the deployed environments.

> Note: You can change VM parameters using the related environment variables. For details, run:
>
> ```./deploy.sh help```

### Network configuration

Demo environment setup requires two dedicated networks assigned for the project deployment:

- **LCM network**: used for MCC cluster setup (including machines provisioning)
  and for access to the MCC services. From MCC standpoint, this network is used as
  public network to download MCC artifacts, so it must have access to the Internet
  or to the proxy (if used).

- **Openstack network**: used to access virtual machines created on top of
  deployed OpenStack cluster. This network must be routable in your infrastructure
  so that you can access OpenStack VMs.

You must provide a subnet range and gateway for each of these networks, for example:

```
VSPHERE_NETWORK_LCM="/<datacenter>/network/<lcm network name>"
NETWORK_LCM_SUBNET=172.16.10.0/24
NETWORK_LCM_GATEWAY=172.16.10.1
NETWORK_LCM_RANGE=172.16.10.2-172.16.10.100

VSPHERE_NETWORK_OPENSTACK="/<datacenter>/network/<openstack network name>"
NETWORK_OPENSTACK_SUBNET=172.16.20.0/24
NETWORK_OPENSTACK_GATEWAY=172.16.20.1
NETWORK_OPENSTACK_RANGE=172.16.20.2-172.16.20.100
```

> Note: vSphere networks must be configured with following network policies:
>
> - Promiscuous mode: Accept
> - MAC address changes: Accept
> - Forged transmits: Accept

### vSphere access

The deployment script requires the vSphere user to access vSphere API.
The user manages full MCC installation onto your infrastructure
and requires the following privileges:

- Datastore
- Distributed switch
- Folder
- Global
- Host local operations
- Network
- Resource
- Scheduled task
- Sessions
- Storage views
- Tasks
- Virtual machine

## Prerequisites

The deloyment script requires following utils to be installed on the machine
where the script will be executed:

- `curl`
- `jq`
- `python3`
- `ssh`, `scp`, `ssh-keygen`
- `tar`
- `virtualenv`
- `govc` (installed automatically if not present)

### Seed node

The seed or bootstrap node is an initial node in the MCC deployment that contains the
bootstrap cluster and MCC configuration. It is mandatory to prepare this seed node
from the Ubuntu 22.04 image. You can download the official Ubuntu 22.04 `vmdk` image
from the following [page](https://cloud-images.ubuntu.com/releases/22.04/release/).

You can upload the image directly to the dedicated vSphere datastore and provide
its path using the `VSPHERE_VMDK_IMAGE_DATASTORE_PATH` variable or you can download
the image locally and provide it using the `VSPHERE_VMDK_IMAGE_LOCAL_PATH` variable.

Not recommended: as an alternative, you can use an existing VM template of Ubuntu 22.04
with the latest version of `cloud-init` installed. You can provide the VM template
using the `VSPHERE_VM_TEMPLATE` variable. Ensure to specify the full path to the template
to uniquely identify it in your vSphere cluster.

## Get started

### Environment variables

Run the following command to obtain detailed information about the script along with
available commands and parameters:

```./deploy.sh help```

#### Minimal mandatory parameters

```
VSPHERE_SERVER="<fqdn or ip>"
VSPHERE_USERNAME="<username>"
VSPHERE_PASSWORD="<password>"
VSPHERE_DATACENTER="<datacenter>"
VSPHERE_DATASTORE="/<datacenter>/datastore/<datastore name>"
VSPHERE_RESOURCE_POOL="/<datacenter>/host/<vsphere cluster name>/Resources/<resource pool name>"
VSPHERE_VMDK_IMAGE_DATASTORE_PATH="<folder>/ubuntu-22.04-server-cloudimg-amd64.vmdk"
VSPHERE_FOLDER="/<datacenter>/vm/<folder name>/mcc"
VSPHERE_SERVER_INSECURE="true"

VSPHERE_NETWORK_LCM="/<datacenter>/network/<lcm network name>"
NETWORK_LCM_SUBNET=172.16.10.0/24
NETWORK_LCM_GATEWAY=172.16.10.1
NETWORK_LCM_RANGE=172.16.10.2-172.16.10.100

VSPHERE_NETWORK_OPENSTACK="/<datacenter>/network/<openstack network name>"
NETWORK_OPENSTACK_SUBNET=172.16.20.0/24
NETWORK_OPENSTACK_GATEWAY=172.16.20.1
NETWORK_OPENSTACK_RANGE=172.16.20.2-172.16.20.100

NTP_SERVERS=us.pool.ntp.org,pool.ntp.org
NAMESERVERS=8.8.8.8,8.8.4.4
```

#### Variables for proxy settings

```
HTTP_PROXY="<http proxy url>"
HTTPS_PROXY="<https proxy url>"
NO_PROXY="<comma-separated list of no proxy hosts>" # should include vsphere fqdn and IP
PROXY_CA_CERTIFICATE_PATH="<path>/<to>/certificate.pem" # in case of MITM proxy
```

### Deploy the MCC environment

To deploy the whole environment using a single command:

```./deploy.sh all```

The deployment stages of the MCC environment are as follows:

1. Set up the seed node
1. Prepare the bootstrap cluster
1. Create and provision management and managed cluster machines
1. Deploy the MCC management cluster:
   1. Set up the host operating system
   1. Set up Kubernetes
   1. Deploy MCC controllers
1. Deploy the MCC managed cluster:
   1. Set up the host operating system
   1. Set up Kubernetes
   1. Deploy Ceph
   1. Deploy OpenStack

## Cleanup

The deployment script can clean up the created vSphere objects used by
the deployed environment. During cleanup, the following items are removed:

- All VMs in `seed`, `management`, and `managed` folders inside the provided
  `VSPHERE_FOLDER`
- All disks attached to VMs including the copy of the `vmdk` image for the seed node

To clean up the created vSphere objects:

```./deploy.sh cleanup```
