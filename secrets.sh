#!/bin/bash

### Make sure you pass a namespace as the first argument

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: api-auth-secret
  namespace: $1
type: Opaque
stringData:
  authSecret: $(gcloud secrets versions access latest --secret=api-auth-secret)

---

apiVersion: v1
kind: Secret
metadata:
  name: google-service-account
  namespace: $1
type: Opaque
stringData:
  key.json: |
    $(gcloud secrets versions access latest --secret=google-service-account)

---

apiVersion: v1
kind: Secret
metadata:
  name: nats-url
  namespace: $1
type: Opaque
stringData:
  connectionString: nats://$(gcloud secrets versions access latest --secret=nats-url)@nats:4222
  user: $(gcloud secrets versions access latest --secret=nats-url | cut -d':' -f1)
  pass: $(gcloud secrets versions access latest --secret=nats-url | cut -d':' -f2)

---

apiVersion: v1
kind: Secret
metadata:
  name: regcred
  namespace: $1
stringData:
  .dockerconfigjson: |
    $(gcloud secrets versions access latest --secret=regcred)
type: kubernetes.io/dockerconfigjson

---

apiVersion: v1
kind: Secret
metadata:
  name: mysql-url
  namespace: $1
type: Opaque
stringData:
  connectionString: mysql://$(gcloud secrets versions access latest --secret=mysql-url)@mysql:3306/main

---

apiVersion: v1
kind: Secret
metadata:
  name: gcloud-mysql-url
  namespace: $1
type: Opaque
stringData:
  connectionString: mysql://$(gcloud secrets versions access latest --secret=gcloud-mysql-url)@10.18.16.3:3306/main

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
  pw: $(gcloud secrets versions access latest --secret=mysql-root-pw)

---

apiVersion: v1
kind: Secret
metadata:
  name: apiban-key
  namespace: $1
type: Opaque
stringData:
  key: $(gcloud secrets versions access latest --secret=apiban-key)
EOF