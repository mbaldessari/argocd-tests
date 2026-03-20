#!/bin/bash
set -xe -o pipefail
source funcs

echo "Deleting argo selfheal-bug-repro app and transient-ns namespace"
oc delete application.argoproj.io -n openshift-gitops selfheal-bug-repro || /bin/true
oc delete ns transient-ns || /bin/true

oc apply -f 00-argocd-setup/argocd-with-fix.yaml

set +e
wait_for_pods
set -e

echo "Success: All pods are Running or Succeeded. Creating the application now"

oc apply -f 02-application.yaml

sleep 10

echo "Application should be in failed state:"
kubectl get application.argoproj.io -n openshift-gitops selfheal-bug-repro -o jsonpath='{"Sync: "}{.status.sync.status}{" | Health: "}{.status.health.status}{"\n"}'

echo ""
echo "Now we create the namespace and observe the app will recover on its own:"
oc apply -f 03-create-namespace.yaml

echo "ArgoCD status:"
kubectl get application.argoproj.io -n openshift-gitops selfheal-bug-repro -o jsonpath='{"Sync: "}{.status.sync.status}{" | Health: "}{.status.health.status}{"\n"}'

sleep 10
echo "ArgoCD status (2):"
kubectl get application.argoproj.io -n openshift-gitops selfheal-bug-repro -o jsonpath='{"Sync: "}{.status.sync.status}{" | Health: "}{.status.health.status}{"\n"}'
