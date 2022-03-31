#!/bin/bash

# Get args
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -p|--project-id) PROJECT_ID="$2"; shift ;;
    -r|--region) REGION="$2"; shift ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Globals
NAMESPACE=staging

if [ -z "$PROJECT_ID" ]; then
  echo "No project id specified. Please run with: '-p project-id'"
  exit 1;
fi

# Set default regions if none specified
if [ -z "$REGION" ]; then
  REGION="us-west2"
fi

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

echo "Sleeping 5 seconds..."
sleep 5

# Create cluster
gcloud beta container --project "$PROJECT_ID" clusters create "$REGION" --zone "$ZONE" --no-enable-basic-auth --cluster-version "1.21" --release-channel "None" --machine-type "c2-standard-4" --image-type "COS_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --max-pods-per-node "110" --num-nodes "1"  --enable-ip-alias --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM,WORKLOAD --network "projects/$PROJECT_ID/global/networks/default" --subnetwork "projects/$PROJECT_ID/regions/$REGION/subnetworks/default" --no-enable-intra-node-visibility --default-max-pods-per-node "110" --enable-autoscaling --autoscaling-profile optimize-utilization --min-nodes "1" --max-nodes "4" --enable-dataplane-v2 --no-enable-master-authorized-networks --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --workload-pool "$PROJECT_ID.svc.id.goog" --enable-vertical-pod-autoscaling --enable-shielded-nodes --node-locations "$ZONE" --cluster-dns clouddns --cluster-dns-scope vpc --cluster-dns-domain $REGION
gcloud beta container --project "$PROJECT_ID" node-pools create "external" --cluster "$REGION" --zone "$ZONE" --machine-type "c2-standard-4" --image-type "UBUNTU_CONTAINERD" --disk-type "pd-ssd" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "1" --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --tags "external-rtp","external-sip" --node-locations "$ZONE"

echo "Sleeping 5 seconds..."
sleep 5

# Get cluster context and rename it
gcloud container clusters get-credentials $REGION --zone=$ZONE
kubectl config rename-context gke_"$PROJECT_ID"_"$ZONE"_"$REGION" $REGION

# deploy pre-reqs (order is important)
kubectl apply -k staging/namespace
kubectl apply -k staging/rbac
./secrets.sh $NAMESPACE
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
  regions: $REGION
  kamailioDmq: kamailio.$NAMESPACE.svc.$REGION:5061
  natsGateways: "[{\"name\": \"$REGION\", \"url\": \"nats://nats:7522\"}]"
EOF

# Set kubeconfig
kubectl config use $REGION
echo "kubeconfig set to $REGION"

# Deploy NATS (because everything needs it)
kubectl apply -k staging/nats
sleep 2
kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-0 --timeout=300s
kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-1 --timeout=300s
kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=nats-2 --timeout=300s

# Deploy Ingress
kubectl apply -k staging/ingress

# Deploy db
kubectl apply -k staging/db
sleep 2
kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=db-0 --timeout=300s
kubectl -n $NAMESPACE wait --for=condition=ready pod -l statefulset.kubernetes.io/pod-name=db-1 --timeout=300s

# Deploy all other services (order is important)
kubectl apply -k staging/kube-client
sleep 2
kubectl -n $NAMESPACE wait --for=condition=available deploy/kube-client --timeout=300s

kubectl apply -k staging/jobs
sleep 2
kubectl -n $NAMESPACE wait --for=condition=available deploy/jobs --timeout=300s

kubectl apply -k staging/omnia-api

kubectl apply -k staging/rtpengine
sleep 10
kubectl -n $NAMESPACE wait --for=condition=ready pod -l component=rtpengine --timeout=300s

kubectl apply -k staging/asterisk
sleep 2
kubectl -n $NAMESPACE wait --for=condition=available deploy/ast --timeout=300s

kubectl apply -k staging/kamailio

echo "Cluster $REGION complete"