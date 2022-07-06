#!/bin/bash
# Assumes gcloud and kubectl is already installed
# THE CLUSTER NAME WILL BE THE NAME OF THE REGION AND CLUSTER ITSELF

displayHelp() {
  echo "Usage: $0 [option...]" >&2
  echo
  echo "   -p, --project-id         Your google cloud project ID (optional - defaults to current project)"
  echo "   -r, --region             Specify the region to deploy the cluster. (optional - default is us-east1)"
  echo "   -s, --ssl-domains        Specify the domains to enable for google-managed SSL (optional)"
  echo "   -m, --machine-type       Specify the machine type (optional - default is c2-standard-4)"
  echo "   -n, --namespace          Specify the namespace to deploy into (optional - default is production)"
  echo
  echo "   Example:"
  echo "   Create new cluster:      $0 --project-id my-project --ssl-domains 'api.myapp.com api2.myapp.com' --region us-central1 --machine-type n1-standard-2"
  echo "   Create staging cluster:  $0 -r us-west1 -n staging -m n2-standard-8"
  echo
  exit 1
}

addFirewallRules() {
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
}

createCerts() {
  echo "Creating google-managed SSL for $1"
  gcloud compute ssl-certificates create managed-certs --domains=$1 --global
}

createCluster() {
  echo "Creating cluster..."
  # First make sure we delete any old hub memberships by that name
  gcloud container hub memberships delete --quiet $REGION
  # Remove any kubeconfig clusters by that cluster name
  kubectl config delete-context $REGION

  # Create the cluster
  gcloud beta container --project "$PROJECT_ID" clusters create "$REGION" --zone "$ZONE" --no-enable-basic-auth --cluster-version "1.23" --release-channel "None" --machine-type "$MACHINE_TYPE" --image-type "COS_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --max-pods-per-node "110" --num-nodes "1" --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM --enable-ip-alias --network "projects/$PROJECT_ID/global/networks/default" --subnetwork "projects/$PROJECT_ID/regions/$REGION/subnetworks/default" --no-enable-intra-node-visibility --default-max-pods-per-node "110" --enable-autoscaling --min-nodes "1" --max-nodes "4" --enable-dataplane-v2 --no-enable-master-authorized-networks --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --autoscaling-profile optimize-utilization --workload-pool "$PROJECT_ID.svc.id.goog" --enable-shielded-nodes --node-locations "$ZONE" --cluster-dns clouddns --cluster-dns-scope vpc --cluster-dns-domain $REGION
  # Add the external-rtp node pool to the cluster
  gcloud beta container --project "$PROJECT_ID" node-pools create "external-rtp" --cluster "$REGION" --zone "$ZONE" --machine-type "$MACHINE_TYPE" --image-type "UBUNTU_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "1" --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --tags "external-rtp" --enable-autoscaling --min-nodes "1" --max-nodes "2" --node-locations "$ZONE"
  # Add the external-sip node pool to the cluster
  gcloud beta container --project "$PROJECT_ID" node-pools create "external-sip" --cluster "$REGION" --zone "$ZONE" --machine-type "$MACHINE_TYPE" --image-type "UBUNTU_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "1" --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --tags "external-sip" --node-locations "$ZONE"

  # Create GKE Multi Cluster Service stuff
  gcloud services enable gkehub.googleapis.com multiclusterservicediscovery.googleapis.com dns.googleapis.com trafficdirector.googleapis.com cloudresourcemanager.googleapis.com --project $PROJECT_ID
  gcloud container hub multi-cluster-services enable --project $PROJECT_ID
  gcloud container hub memberships register $REGION --gke-cluster "$ZONE/$REGION" --enable-workload-identity
  gcloud projects add-iam-policy-binding $PROJECT_ID --member "serviceAccount:$PROJECT_ID.svc.id.goog[gke-mcs/gke-mcs-importer]" --role "roles/compute.networkViewer"

  # Get cluster context and rename it to the cluster name
  gcloud container clusters get-credentials $REGION --zone=$ZONE
  kubectl config rename-context gke_"$PROJECT_ID"_"$ZONE"_"$REGION" $REGION
}

applySecrets() {
  echo "Applying secrets..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: api-auth-secret
  namespace: $1
type: Opaque
stringData:
  authSecret: $(gcloud secrets versions access latest --secret=api-auth-secret | grep -m1 "")

---

apiVersion: v1
kind: Secret
metadata:
  name: google-service-account
  namespace: $1
type: Opaque
stringData:
  key.json: |
    $(gcloud secrets versions access latest --secret=google-service-account | grep -m1 "")

---

apiVersion: v1
kind: Secret
metadata:
  name: nats-url
  namespace: $1
type: Opaque
stringData:
  connectionString: $(gcloud secrets versions access latest --secret=nats-url)
  user: $(gcloud secrets versions access latest --secret=nats-url | cut -d ':' -f2 | awk -F// '{print $2}')
  pass: $(gcloud secrets versions access latest --secret=nats-url | cut -d ':' -f3 | cut -d '@' -f1)

---

apiVersion: v1
kind: Secret
metadata:
  name: regcred
  namespace: $1
stringData:
  .dockerconfigjson: |
    $(gcloud secrets versions access latest --secret=regcred | grep -m1 "")
type: kubernetes.io/dockerconfigjson

---

apiVersion: v1
kind: Secret
metadata:
  name: mysql-url
  namespace: $1
type: Opaque
stringData:
  connectionString: $(gcloud secrets versions access latest --secret=mysql-url | grep -m1 "")

---

apiVersion: v1
kind: Secret
metadata:
  name: gcloud-mysql-url
  namespace: $1
type: Opaque
stringData:
  connectionString: $(gcloud secrets versions access latest --secret=gcloud-mysql-url | grep -m1 "")

---

apiVersion: v1
kind: Secret
metadata:
  name: aws
  namespace: $1
type: Opaque
stringData:
  accessKey: $(gcloud secrets versions access latest --secret=aws | cut -d':' -f1)
  secretAccessKey: $(gcloud secrets versions access latest --secret=aws | cut -d':' -f2)

---

apiVersion: v1
kind: Secret
metadata:
  name: mysql-root-pw
  namespace: $1
type: Opaque
stringData:
  pw: $(gcloud secrets versions access latest --secret=mysql-root-pw | grep -m1 "")

---

apiVersion: v1
kind: Secret
metadata:
  name: apiban-key
  namespace: $1
type: Opaque
stringData:
  key: $(gcloud secrets versions access latest --secret=apiban-key | grep -m1 "")

---

apiVersion: v1
kind: Secret
metadata:
  name: prometheus-password
  namespace: $1
type: Opaque
stringData:
  key: $(gcloud secrets versions access latest --secret=prometheus-password | grep -m1 "")
EOF
}

deployResources() {
  echo "Deploying resources..."
  
  # deploy pre-reqs (order is important)
  $1/namespace
  $1/rbac
  applySecrets "$NAMESPACE"
  kubectl apply -f base/pdb.yaml

  # Get the subnet of the current region (which will be unique)
  SUBNET=$(gcloud compute networks subnets describe default --region=$REGION | grep "gatewayAddress" | awk -F '.' '{print $2}')
  SERVER_ID=\"$SUBNET\"

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
EOF

  # Set kubeconfig
  kubectl config use $REGION
  echo "kubeconfig set to $REGION"

  # Deploy NATS (because everything needs it)
  $1/nats
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-0 --timeout=300s
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-1 --timeout=300s
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-2 --timeout=300s

  # Check if we are deploying the CONFIG_REGION
  if [ "$CONFIG_REGION" == "1" ] && [ "$NAMESPACE" == "production" ]; then
    # Deploy ingress
    gcloud beta container hub ingress enable --config-membership=$REGION

    echo "Sleeping 10 seconds..."
    sleep 10

    # Deploy MultiClusterService, MultiClusterIngress
    kubectl apply -f base/ingress
  fi

  if [ "$NAMESPACE" == "staging" ]; then
    # Deploy ingress
    kubectl apply -k staging/ingress
  fi

  # Deploy db
  $1/db
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=db-0 --timeout=300s
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=db-1 --timeout=300s

  # Deploy all other services (order is important)
  $1/kube-client
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=available deploy/kube-client --timeout=300s

  $1/jobs
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=available deploy/jobs --timeout=300s

  $1/omnia-api

  $1/rtpengine
  sleep 10
  kubectl -n $NAMESPACE wait --for=condition=ready pod -l component=rtpengine --timeout=300s

  $1/asterisk
  sleep 2
  kubectl -n $NAMESPACE wait --for=condition=available deploy/ast --timeout=300s

  $1/kamailio
}

# Get args
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -p|--project-id) PROJECT_ID="$2"; shift ;;
    -r|--region) REGION="$2"; shift ;;
    -s|--ssl-domains) SSL_DOMAINS="$2"; shift ;;
    -m|--machine-type) MACHINE_TYPE="$2"; shift ;;
    -n|--namespace) NAMESPACE="$2"; shift ;;
    -h|--help) displayHelp; exit 0 ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Set a default project id if not set
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gcloud config get-value project)
fi

# Set a default machine type if it isn't set
if [ -z "$MACHINE_TYPE" ]; then
  MACHINE_TYPE="c2-standard-4"
fi

# Set a default namespace if it isn't set
if [ -z "$NAMESPACE" ]; then
  NAMESPACE="production"
fi

# Set a default region if it isn't set
if [ -z "$REGION" ]; then
  REGION="us-east1"
fi

# Set the default zone if it isn't set
if [ -z "$ZONE" ]; then
  ZONE="$REGION-b"
fi


# Sanity check to make sure namespace is set to 'production' or 'staging' before deploying
if [ "$NAMESPACE" != "production" ] && [ "$NAMESPACE" != "staging" ]; then
  echo "Namespace must be either 'production' or 'staging'"
  displayHelp
  exit 1;
fi

# Sanity check to make sure the cluster doesn't already exist
CLUSTER_EXISTS=$(gcloud container clusters list --format=json | grep "$REGION")
if [ -n "$CLUSTER_EXISTS" ]; then
  echo "Cluster $REGION already exists"
  displayHelp
  exit 1
fi

# Create google managed certs
DOMAINCOUNT=0
# Loop through the SSL_DOMAINS and create certs for each one
for DOMAIN in $SSL_DOMAINS; do DOMAINCOUNT=$((DOMAINCOUNT+1)) ; done
if [ $DOMAINCOUNT -gt 0 ]; then
  for DOMAIN in $SSL_DOMAINS; do createCerts "$DOMAIN" ; done
fi

# Figure out which cluster is the config region for multi cluster ingress using gcloud
CONFIG_REGION=0
if [ "$NAMESPACE" == "production" ]; then
  MCISTATUS=$(gcloud container fleet ingress describe --format 'get(state.state.code)')
  if [ "$MCISTATUS" == "OK" ]; then
    echo "Config cluster already exists"
  else
    echo "Need to create config cluster"
    CONFIG_REGION=1
  fi
fi

# Ask for confirmation before continuing
echo "Creating cluster $REGION in $ZONE with machine type $MACHINE_TYPE and namespace $NAMESPACE under project-id $PROJECT_ID ..."
read -p "Continue (y/n)? " choice
case "$choice" in
  y|Y ) echo "Continuing";;
  n|N ) echo "Exiting"; exit 1 ;;
  * ) echo "Invalid. Exiting"; exit 1 ;;
esac

# Create firewall rules for external-sip and external-udp tagged Node Pool(s)
addFirewallRules

# Create the cluster
createCluster

# Deploy resources depending on the namespace
if [ "$NAMESPACE" == "production" ]; then
  deployResources "kubectl apply -f base"
elif [ "$NAMESPACE" == "staging" ]; then
  deployResources "kubectl apply -k staging"
else
  echo "Invalid namespace. Exiting"
  exit 1
fi

echo "DONE DEPLOYING $REGION"

