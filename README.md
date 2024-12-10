Virtualised MCC/MOSK for on-premise self-evaluation
===================================================

Introduction
============
Project is developed for demo purposes on
[MCC](<https://docs.mirantis.com/container-cloud/latest/overview.html>)
and [MOSK](https://docs.mirantis.com/mosk/latest/overview.html)
products on top of Vsphere infrastrcutre.

Pre-requesities
===============

Network configuration
---------------------
Demo environment setup requires two dedicated networks assigned for the
deployment:

* <b>LCM network</b>. Used for MCC cluster setup (including machines provisioning)
  and also to access the MCC services. From MCC standpoint it is used as
  public network to download MCC artifacts,
  so it should have access to the internet or to the proxy (if used).

* <b>Openstack network</b>. Used to access Virtual machines created on top of
  deployed Openstack cluster. Network should be routable in your infrastructure,
  so you can access the Openstack VMs.

**_NOTE:_** Vsphere networks must be configured with following network policies:

* Promiscuous mode: Accept
* MAC address changes: Accept
* Forged transmits: Accept

User permissions
----------------

Vsphere user manages full installation of MCC product onto your infrastructure
and requires following privileges:

* Datastore
* Distributed switch
* Folder
* Global
* Host local operations
* Network
* Resource
* Scheduled task
* Sessions
* Storage views
* Tasks
* Virtual machine

Seed node
---------
Seed or bootstrap node is an initial node in MCC deployment which holds
bootstrap cluster and MCC configuration. It is mandatory to prepare
this seed node from the Ubuntu 22.04 image.
You can download official Ubuntu 22.04 `vmdk` image
from following [download page](https://cloud-images.ubuntu.com/releases/22.04/release/).
You can upload the image directly to dedicated Vsphere datastore and provide path
to it via `VSPHERE_VMDK_IMAGE_DATASTORE_PATH` variable or you can download
the image locally and provide it via `VSPHERE_VMDK_IMAGE_LOCAL_PATH` variable.

The alternative (and less-preferred) way is to use existing
VM template of Ubuntu 22.04 with cloud-init installed of the latest version.
The VM template can be provided via `VSPHERE_VM_TEMPLATE` variable.
Please specify full path to template to unique identify it in your Vsphere cluster.

Get started
===========

Environment variables
---------------------

Run following command to get detailed information about the script
and the available commands and parameters:

```./deploy.sh help```

Minimal mandatory parameters
----------------------------

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

Proxy settings
--------------

```
HTTP_PROXY="<http proxy url>"
HTTPS_PROXY="<https proxy url>"
NO_PROXY="<comma-separated list of no proxy hosts>" # should include vsphere fqdn and IP
PROXY_CA_CERTIFICATE_PATH="<path>/<to>/certificate.pem" # in case of MITM proxy
```

Deploy MCC environment
----------------------

MCC environment deployment includes:

* seed node setup
* creating and provisioning for management and child cluster machines
* deployment of MCC management cluster
* deployment of MCC child cluster:
  * ceph deployment
  * openstack deployment

Each stage can be run separately. See `./deploy.sh help` for details.

To deploy whole env with one command:

```./deploy.sh all```

