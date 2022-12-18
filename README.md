## Multi-region Kubernetes VoIP deployment

:white_check_mark: Easy to deploy

:white_check_mark: Multi region

:white_check_mark: Globally distributed

:white_check_mark: Scalable

:white_check_mark: Single global ingress

:white_check_mark: Auto-clustering

## Overview

[Slides](https://vibrant-easley-d0491e.netlify.app)

[Demo video](https://www.youtube.com/watch?v=MZDJuwR31KI)

[Astricon 2021 presentation](https://www.youtube.com/watch?v=vgOIIdYovZk&list=PLighc-2vlRgQTRb0PQCfFMDHuWjoUAKg4&index=3)

[Interactive Diagram](https://isoflow.io/project/cknuw4pyddjjq0738cnikqcbv)

![Image](./Architecture.png)

This project assumes you have the following installed/configured
* gcloud SDK and a project setup in gcloud
* kubectl
* External IP in GCP (used for External HTTP(S) global LB)
* External IP's in GCP (used for Kamailio/Rtpengine)
* Secrets already created in [Secret Manager](https://console.cloud.google.com/security/secret-manager) (refer to `up` for the naming convention)


`up` 
----------
This takes care of the whole install process.
* Create any google managed certs provided via command line args
* Create firewall rules for both `external-sip` and `external-rtp` traffic (both node pools)
* Obtain the MultiClusterIngress config cluster (since there can only be one)
* Create a cluster with a default node-pool and a node-pool with the `external-sip` and `external-rtp` network tags
* Deploy all resources in this repository to the cluster. Resources that depend on other clusters have DNS entries as env vars within each manifest file (E.g. NATS, Kamailio, db). These env vars are used to to have each new cluster be aware of the other clusters in other regions. There is no real limit to the amount of clusters that can be deployed globally as long as the DNS records are added to the appropriate manifest files.
* Deploys monitoring via prometheus and graphana (currently using Grafana Cloud but can use any self hosted deployment)

#### What you get
* Automatic firewall rules for both SIP/RTP
* 3 Node Pools (1 - default, 2 - external-rtp, 3 - external-sip)
* Handling of google-managed SSL certs
* Global HTTP(S) Multi-Cluster-Ingress Load balancer (handles websocket/WebRTC and all other HTTP traffic)
* Auto-assigning of Static IP's to nodes in the `external-rtp` and `external-sip` Node Pools via `kube-client`
* Enables the necessary API's in GCP for [MCS](https://cloud.google.com/kubernetes-engine/docs/how-to/multi-cluster-services), [MCI](https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-ingress), [Hub memberships](https://cloud.google.com/anthos/multicluster-management/connect/registering-a-cluster?cloudshell=true)
* Handling of [Config cluster setup](https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-ingress#config_cluster_design) setup

`./`
---------
Contains all production manifests to be deployed in a production environment. `./up`

`./ingress`
---------
This only gets deployed to the [Config Cluster](https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-ingress#config_cluster_design) which is determined in the install script automatically.

## Install example

Run `./up` with options below
```
Usage: ./up [options...]

-p, --project-id         Your google cloud project ID (optional - defaults to current project)
-r, --region             Specify the region to deploy the cluster. (optional - default is us-east1)
-m, --machine-type       Specify the machine type (optional - default is c2-standard-4)
-q, --quiet              Specify the quiet flag for non-interacive (optional - default interactive mode)

Example:
New cluster:             ./up -p my-project -r us-central1 -m n1-standard-2 -q yes
Interactive mode:        ./up
```
