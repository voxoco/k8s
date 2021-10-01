# Kubernetes Manifests

#### Multi-Region, fully redundant, geographically distributed telephony platform.

## Overview

Slides [click here](https://vibrant-easley-d0491e.netlify.app)

Demo video [click here](https://www.youtube.com/watch?v=MZDJuwR31KI)

Interactive diagram view [click here](https://isoflow.io/project/cknuw4pyddjjq0738cnikqcbv)

![Image](https://isoflow.io/project/image/cknuw4pyddjjq0738cnikqcbv)

This project assumes you have the following installed/configured
* gcloud
* kubectl
* External IP in GCP (used for External HTTP(S) global LB)
* External IP's in GCP (used for Kamailio/Rtpengine)

`install.sh` 
----------
This takes care of the install process when starting from scratch and/or when adding new clusters/regions.
* Fresh install deployed in 3 regions and/or adding additional regions
* Automatic firewall rules for both SIP/RTP
* 2 Node Pools per cluster (1 - external, 2 - everything else)
* Handling of google-managed SSL certs
* Global HTTP(S) Multi-Cluster-Ingress Load balancer (handles websocket/WebRTC and all other HTTP traffic)
* Auto-assigning of Static IP's to nodes in the `external` Node Pool via `kube-client`
* Enables the necessary API's in GCP for [MCS](https://cloud.google.com/kubernetes-engine/docs/how-to/multi-cluster-services), [MCI](https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-ingress), [Hub memberships](https://cloud.google.com/anthos/multicluster-management/connect/registering-a-cluster?cloudshell=true)
* Handling of [Config cluster setup](https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-ingress#config_cluster_design) setup

`manifests/`
---------
Contains all services to be deployed. Each region/cluster needs it's own directory like `manifests/us-east1` as it contains information for that specific cluster. *Naming the directory the region/cluster is important*

`manifests/config-cluster.yaml`
---------
This only gets deployed to the [Config Cluster](https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-ingress#config_cluster_design) which is determined by the first region/cluster being deployed using the `fresh install`.


`secrets/secrets.yaml`
---------
There are `secrets` referenced in the manifests. Be sure to create the necessary secrets yaml in the secrets dir before running. Searching through the manifests will help determine the keys/values required.

## Install

Run `./install.sh` with options below
```
Usage: ./install.sh [option...]" >&2

-p, --project-id         Your google cloud project ID (required)"
-r, --regions            Specify the region(s) seperated by a space. (optional - defaults to 'us-central1 us-east1 us-east4')"
-s, --ssl-domains        Specify the domains to enable for google-managed SSL (optional)"
-f, --fresh-install      Specify 'yes' or 'no' (optional - defaults to 'no')"

Examples:
3 regions (fresh):       ./install.sh --project-id 'my-project' --ssl-domains 'api.myapp.com api2.myapp.com' --fresh-install 'yes'
Custom regions (fresh):  ./install.sh --project-id 'my-project' --regions 'us-west1 us-central1 us-east1' --ssl-domains 'api.myapp.com api2.myapp.com' --fresh-install 'yes'
Add a region to cluster: ./install.sh --project-id 'my-project' --regions 'us-west1'
```




