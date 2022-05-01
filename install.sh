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
    -m|--machine-type) MACHINE_TYPE="$2"; shift ;;
    -h|--help) displayHelp; exit 0 ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Globals
CONFIG_REGION=""
NAMESPACE=production

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

# Set machine type
if [ -z "$MACHINE_TYPE" ]; then
  MACHINE_TYPE="c2-standard-4"
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
  ZONE="$REGION-b"

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

  echo "Sleeping 5 seconds..."
  sleep 5

  # Create cluster
  gcloud beta container --project "$PROJECT_ID" clusters create "$REGION" --zone "$ZONE" --no-enable-basic-auth --cluster-version "1.22" --release-channel "None" --machine-type "$MACHINE_TYPE" --image-type "COS_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --max-pods-per-node "110" --num-nodes "1" --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM --enable-ip-alias --network "projects/$PROJECT_ID/global/networks/default" --subnetwork "projects/$PROJECT_ID/regions/$REGION/subnetworks/default" --no-enable-intra-node-visibility --default-max-pods-per-node "110" --enable-autoscaling --min-nodes "1" --max-nodes "4" --enable-dataplane-v2 --no-enable-master-authorized-networks --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --autoscaling-profile optimize-utilization --workload-pool "$PROJECT_ID.svc.id.goog" --enable-shielded-nodes --node-locations "$ZONE" --cluster-dns clouddns --cluster-dns-scope vpc --cluster-dns-domain $REGION
  gcloud beta container --project "$PROJECT_ID" node-pools create "external" --cluster "$REGION" --zone "$ZONE" --machine-type "$MACHINE_TYPE" --image-type "UBUNTU_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "1" --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --tags "external-rtp","external-sip" --node-locations "$ZONE"

  # Create GKE Multi Cluster Service stuff
  gcloud services enable gkehub.googleapis.com multiclusterservicediscovery.googleapis.com dns.googleapis.com trafficdirector.googleapis.com cloudresourcemanager.googleapis.com --project $PROJECT_ID
  gcloud container hub multi-cluster-services enable --project $PROJECT_ID
  gcloud container hub memberships register $REGION --gke-cluster "$ZONE/$REGION" --enable-workload-identity
  gcloud projects add-iam-policy-binding $PROJECT_ID --member "serviceAccount:$PROJECT_ID.svc.id.goog[gke-mcs/gke-mcs-importer]" --role "roles/compute.networkViewer"
  gcloud container hub multi-cluster-services describe

  echo "Sleeping 5 seconds..."
  sleep 5

  # Get cluster context and rename it
  gcloud container clusters get-credentials $REGION --zone=$ZONE
  kubectl config rename-context gke_"$PROJECT_ID"_"$ZONE"_"$REGION" $REGION

  # deploy pre-reqs (order is important)
  kubectl apply -f base/namespace
  kubectl apply -f base/rbac
  ./secrets.sh $NAMESPACE
  kubectl apply -f base/pdb.yaml

  if [ "$FRESH_INSTALL" == "yes" ]; then

    # Get the subnet of the current region (which will be unique)
    SUBNET=$(gcloud compute networks subnets describe default --region=$REGION | grep "gatewayAddress" | awk -F '.' '{print $2}')
    SERVER_ID=\"$SUBNET\"

    # Get any other region besides myself (for kamailio dmq)
    for DMQ_REGION in ${REGIONS}; do
      if [ "$DMQ_REGION" != "$REGION" ]; then
        DMQ_HOST=$DMQ_REGION
        break
      fi
    done

    # Build NATS gateways
    GATEWAYS='['
    for GATEWAY in ${REGIONS}; do
      OBJ="{name: \"$GATEWAY\", url: \"nats://nats-0.nats.$NAMESPACE.svc.$GATEWAY:7522\"}"
      if [ ${#GATEWAYS} -le 2 ]; then
        GATEWAYS="$GATEWAYS$OBJ"
      else
        GATEWAYS="$GATEWAYS,$OBJ"
      fi
    done
    GATEWAYS="$GATEWAYS]"

    # Create cluster-details ConfigMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-details
  namespace: $NAMESPACE
data:
  projectId: $PROJECT_ID
  serverId: $SERVER_ID
  clusterName: $REGION
  zone: $ZONE
  regions: $REGIONS
  kamailioDmq: kamailio.$NAMESPACE.svc.$DMQ_HOST:5061
  natsGateways: $GATEWAYS
EOF

  fi

  # Set kubeconfig
  kubectl config use $REGION
  echo "kubeconfig set to $REGION"

  # Deploy NATS (because everything needs it)
  kubectl apply -f base/nats
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-0 --timeout=300s
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-1 --timeout=300s
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-2 --timeout=300s

  # Check if config cluster
  if [ "$CONFIG_REGION" == "$REGION" ] && [ "$FRESH_INSTALL" == "yes" ]; then
    gcloud beta container hub ingress enable --config-membership=$REGION

    echo "Sleeping 10 seconds..."
    sleep 10

    # Deploy MultiClusterService, MultiClusterIngress
    kubectl apply -f base/ingress
  fi

  # Deploy db
  kubectl apply -f base/db
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=db-0 --timeout=300s
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=db-1 --timeout=300s

  # Deploy all other services (order is important)
  kubectl apply -f base/kube-client
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=available deploy/kube-client --timeout=300s

  kubectl apply -f base/jobs
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=available deploy/jobs --timeout=300s

  kubectl apply -f base/omnia-api

  kubectl apply -f base/rtpengine
  sleep 10
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l component=rtpengine --timeout=300s

  kubectl apply -f base/asterisk
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=available deploy/ast --timeout=300s

  kubectl apply -f base/kamailio

  echo "Cluster $REGION complete"

done
