#!/bin/bash
# Assumes gcloud is already installed
# MAKE SURE CLUSTER NAMES MATCH THE NAME OF A REGION. HUB MEMBERSHIPS AND MCS DEPEND ON IT

displayHelp() {
  echo "Usage: $0 [option...]" >&2
  echo
  echo "   -p, --project-id         Your google cloud project ID (required)"
  echo "   -r, --regions            Specify the region(s) seperated by a space. (optional - defaults to 'us-central1 us-east1 us-east4')"
  echo "   -s, --ssl-domains        Specify the domains to enable for google-managed SSL (optional)"
  echo "   -f, --fresh-install      Specify 'yes' or 'no' (optional - defaults to 'no')"
  echo
  echo "   Examples:"
  echo "   3 regions (fresh):       $0 --project-id 'my-project' --ssl-domains 'api.myapp.com api2.myapp.com' --fresh-install 'yes'"
  echo "   Custom regions (fresh):  $0 --project-id 'my-project' --regions 'us-west1 us-central1 us-east1' --ssl-domains 'api.myapp.com api2.myapp.com' --fresh-install 'yes'"
  echo "   Add a region to cluster: $0 --project-id 'my-project' --regions 'us-west1'"
  echo
  exit 1
}

# Get args
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -p|--project-id) PROJECT_ID="$2"; shift ;;
    -r|--regions) REGIONS="$2"; shift ;;
    -s|--ssl-domains) SSL_DOMAINS="$2"; shift ;;
    -f|--fresh-install) FRESH_INSTALL="$2"; shift ;;
    -h|--help) displayHelp; exit 0 ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Globals
CONFIG_REGION=""

if [ -z "$PROJECT_ID" ]; then
  echo "No project id specified"
  exit 1;
fi

# Set default regions if none specified
if [ -z "$REGIONS" ]; then
  REGIONS="us-central1 us-east1 us-east4"
fi

if [ -z "$FRESH_INSTALL" ]; then
  echo "Setting fresh install to no"
  FRESH_INSTALL="no"
fi

# Check if we need a config cluster or not
if [ "$FRESH_INSTALL" == "yes" ]; then
  # Pick the first region to be the config cluster
  CONFIG_REGION=${REGIONS%% *}
  echo "Setting config region as $CONFIG_REGION"
fi

# Create google managed cert
# Global ssl certs are not supported via kubernetes resource yet for MultiClusterIngress
if [ -z "$SSL_DOMAINS" ]; then
  echo "No domains specified for SSL. Continuing.."
else
  for DOMAIN in ${SSL_DOMAINS}; do
    echo "Creating google-managed SSL for $DOMAIN"
    gcloud compute ssl-certificates create managed-certs --domains=$DOMAIN --global
  done
fi

# Create firewall rules for external-sip and external-udp tagged Node Pool(s)
FIREWALL_SIP_EXISTS=$(gcloud compute firewall-rules list --format=json | grep "external-sip")
if [ -z "$FIREWALL_SIP_EXISTS" ]; then
  echo "Creating external-sip firewall rule"
  gcloud compute firewall-rules create "external-sip" --allow=tcp:5060,tcp:5029,udp:5060 --description="Allow SIP related traffic" --direction=INGRESS --source-ranges="0.0.0.0/0" --target-tags="external-sip"
else
  echo "external-sip firewall rule already exists"
fi

FIREWALL_RTP_EXISTS=$(gcloud compute firewall-rules list --format=json | grep "external-rtp")
if [ -z "$FIREWALL_RTP_EXISTS" ]; then
  echo "Creating external-rtp firewall rule"
  gcloud compute firewall-rules create "external-rtp" --allow=udp:10000-60000 --description="Allow RTP related traffic" --direction=INGRESS --source-ranges="0.0.0.0/0" --target-tags="external-rtp"
else
  echo "external-rtp firewall rule already exists"
fi

# Loop through clusters
for REGION in ${REGIONS}; do

  echo "Starting deployment of cluster $REGION"

  # Set zone for cluster
  ZONE="$REGION-c"

  # Check if cluster exists yet (just a sanity check)
  EXISTS=$(gcloud container clusters list | grep "$REGION")
  if [ -z "$EXISTS" ]; then
    echo "$REGION cluster does not exist yet"
  else
    echo "$REGION cluster already exists. Please run again and choose another region"
    exit
  fi

  # First make sure we delete any old hub memberships by that name
  gcloud container hub memberships delete --quiet $REGION
  # Remove any kubeconfig clusters by that cluster name
  kubectl config delete-context $REGION

  echo "Sleeping 10 seconds..."
  sleep 10

  # Create cluster
  gcloud beta container --project "$PROJECT_ID" clusters create "$REGION" --zone "$ZONE" --no-enable-basic-auth --cluster-version "1.20" --release-channel "None" --machine-type "c2-standard-4" --image-type "COS_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "1" --enable-stackdriver-kubernetes --enable-ip-alias --network "projects/$PROJECT_ID/global/networks/default" --subnetwork "projects/$PROJECT_ID/regions/$REGION/subnetworks/default" --default-max-pods-per-node "110" --enable-autoscaling --min-nodes "1" --max-nodes "4" --no-enable-master-authorized-networks --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --workload-pool "$PROJECT_ID.svc.id.goog" --enable-shielded-nodes --node-locations "$ZONE"
  gcloud beta container --project "$PROJECT_ID" node-pools create "external" --cluster "$REGION" --zone "$ZONE" --machine-type "c2-standard-4" --image-type "COS_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "1" --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --tags "external-rtp","external-sip" --node-locations "$ZONE"

  # Create GKE Multi Cluster Service stuff
  gcloud services enable gkehub.googleapis.com multiclusterservicediscovery.googleapis.com dns.googleapis.com trafficdirector.googleapis.com cloudresourcemanager.googleapis.com --project $PROJECT_ID
  gcloud alpha container hub multi-cluster-services enable --project $PROJECT_ID
  gcloud container hub memberships register $REGION --gke-cluster "$ZONE/$REGION" --enable-workload-identity
  gcloud projects add-iam-policy-binding $PROJECT_ID --member "serviceAccount:$PROJECT_ID.svc.id.goog[gke-mcs/gke-mcs-importer]" --role "roles/compute.networkViewer"
  gcloud alpha container hub multi-cluster-services describe

  echo "Sleeping 10 seconds..."
  sleep 10

  # Get cluster context and rename it
  gcloud container clusters get-credentials $REGION --zone=$ZONE
  kubectl config rename-context gke_"$PROJECT_ID"_"$ZONE"_"$REGION" $REGION

  # deploy pre-reqs (order is important)
  kubectl apply -f manifests/namespace.yaml
  kubectl apply -f manifests/rbac.yaml
  kubectl apply -f secrets/secrets.yaml

  # Create ConfigMap with cluster details
  kubectl apply -f manifests/$REGION/cluster-details.yaml

  # Create ConfigMap with the project id (used by prometheus)
  echo "
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: gcp-project
    namespace: voip
  data:
    projectId: $PROJECT_ID" | kubectl apply -f -

  echo "Sleeping 10 seconds..."
  sleep 10

  # Set kubeconfig
  kubectl config use $REGION
  echo "kubeconfig set to $REGION"

  # Deploy NATS (because everything needs it)
  kubectl apply -f manifests/nats.yaml

  echo "Sleeping 2 minutes..."
  sleep 120

  # Check if config cluster
  if [ "$CONFIG_REGION" == "$REGION" ] && [ "$FRESH_INSTALL" == "yes" ]; then
    gcloud alpha container hub ingress enable --config-membership=projects/$PROJECT_ID/locations/global/memberships/$REGION

    echo "Sleeping 10 seconds..."
    sleep 10

    # Deploy MultiClusterService, MultiClusterIngress
    kubectl apply -f manifests/config-cluster.yaml
  fi

  echo "Sleeping 20 seconds..."
  sleep 20

  # Deploy region specific stuff
  kubectl apply -f manifests/$REGION/kamailio-dmq.yaml

  # Deploy innodb-cluster
  kubectl apply -f manifests/innodb-cluster.yaml

  # Since the db relies on MCS and GCP takes 5 minutes to sync Service Exports between the fleet of clusters we need to wait
  echo "Sleeping 6 minutes to give db time to come up"
  sleep 360

  # Deploy all other services (order is important)
  kubectl apply -f manifests/kube-client.yaml

  echo "Sleeping 2 minutes..."
  sleep 120

  kubectl apply -f manifests/jobs.yaml

  echo "Sleeping 1 minute to make sure jobs and kube-client have settled (since their a dependency for rtpengine/kamailio)"
  sleep 60

  kubectl apply -f manifests/omnia-api.yaml
  kubectl apply -f manifests/rtpengine.yaml
  kubectl apply -f manifests/asterisk.yaml
  kubectl apply -f manifests/kamailio.yaml
  kubectl apply -f manifests/prometheus.yaml

  echo "Cluster $REGION complete"

done
