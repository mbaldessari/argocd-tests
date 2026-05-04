#!/bin/bash
# Real-world reproducer for ArgoCD InvalidSpecError race condition
#
# This script reproduces the race where Applications get InvalidSpecError
# during controller startup even when the referenced AppProject exists.
# The race occurs when appInformer processes Applications before
# projInformer has synced its cache.

set -e

NAMESPACE=${ARGOCD_NAMESPACE:-argocd}
#PROJECT_NAME="race-test-project"
PROJECT_NAME="default"
APP_PREFIX="race-test-app"
NUM_APPS=5
MAX_ATTEMPTS=10
ATTEMPT=1

echo "=== ArgoCD Race Condition Reproducer ==="
echo "Namespace: $NAMESPACE"
echo "Project: $PROJECT_NAME"
echo "Apps: $NUM_APPS ($APP_PREFIX-1 to $APP_PREFIX-$NUM_APPS)"
echo "Max attempts: $MAX_ATTEMPTS"
echo

# Check if ArgoCD is running
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: ArgoCD namespace '$NAMESPACE' not found"
    exit 1
fi

if ! kubectl get deployment -n "$NAMESPACE" argocd-applicationset-controller >/dev/null 2>&1; then
    echo "ERROR: ArgoCD application controller not found in namespace '$NAMESPACE'"
    exit 1
fi

# Function to clean up test resources
cleanup() {
    #echo "Cleaning up test resources..."
    #kubectl delete applications -n "$NAMESPACE" -l "race-test=true" --ignore-not-found=true
    #kubectl delete appprojects -n "$NAMESPACE" "$PROJECT_NAME" --ignore-not-found=true
    echo "Cleanup complete"
}

# Function to create test AppProject
create_project() {
    echo "Creating AppProject '$PROJECT_NAME'..."
    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $PROJECT_NAME
  namespace: $NAMESPACE
spec:
  sourceRepos:
  - '*'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: ''
    kind: '*'
EOF
}

# Function to create test Applications
create_applications() {
    echo "Creating $NUM_APPS Applications referencing project '$PROJECT_NAME'..."
    for i in $(seq 1 $NUM_APPS); do
        cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_PREFIX-$i
  namespace: $NAMESPACE
  labels:
    race-test: "true"
spec:
  project: $PROJECT_NAME
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    path: guestbook
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
    done
    echo "Applications created"
}

# Function to restart ArgoCD controller
restart_controller() {
    echo "Restarting ArgoCD application controller to trigger startup race..."
    kubectl delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=argocd-application-controller

    # Wait for controller to be ready
    echo "Waiting for controller to be ready..."
    kubectl wait --for=condition=ready pod -n "$NAMESPACE" -l app.kubernetes.io/name=argocd-application-controller --timeout=60s

    # Give it a moment to start processing
    sleep 5
}

# Function to check for race condition
check_race_condition() {
    echo "Checking for InvalidSpecError race condition..."
    local found_race=false

    for i in $(seq 1 $NUM_APPS); do
        local app_name="$APP_PREFIX-$i"
        local conditions=$(kubectl get application -n "$NAMESPACE" "$app_name" -o jsonpath='{.status.conditions[?(@.type=="InvalidSpecError")]}' 2>/dev/null || echo "")

        if [[ -n "$conditions" ]]; then
            local message=$(kubectl get application -n "$NAMESPACE" "$app_name" -o jsonpath='{.status.conditions[?(@.type=="InvalidSpecError")].message}' 2>/dev/null || echo "")
            if [[ "$message" == *"project $PROJECT_NAME which does not exist"* ]]; then
                echo "RACE CONDITION DETECTED!"
                echo "Application: $app_name"
                echo "Message: $message"
                echo
                echo "This proves the race condition:"
                echo "1. AppProject '$PROJECT_NAME' exists:"
                kubectl get appproject -n "$NAMESPACE" "$PROJECT_NAME" --no-headers 2>/dev/null || echo "   ERROR: Project not found!"
                echo "2. But Application got InvalidSpecError saying project doesn't exist"
                echo "3. This happens when appInformer processes apps before projInformer cache is synced"
                echo
                found_race=true
            fi
        fi
    done

    if [[ "$found_race" == "true" ]]; then
        return 0
    else
        echo "No race condition detected in attempt $ATTEMPT"
        return 1
    fi
}

create_namespaces() {
    for i in $(seq 500); do
        oc create namespace bandini-${i}
        oc label namespace bandini-${i} foo=bar
    done
}

# Function to show current application statuses
show_app_status() {
    echo "Current Application statuses:"
    for i in $(seq 1 $NUM_APPS); do
        local app_name="$APP_PREFIX-$i"
        echo -n "  $app_name: "
        local health=$(kubectl get application -n "$NAMESPACE" "$app_name" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        local sync=$(kubectl get application -n "$NAMESPACE" "$app_name" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        local conditions=$(kubectl get application -n "$NAMESPACE" "$app_name" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
        echo "Health=$health Sync=$sync Conditions=[$conditions]"
    done
    echo
}

# Main reproduction loop
main() {
    echo "Starting race condition reproduction..."
    echo

    # Cleanup any existing test resources
    cleanup
    echo
    oc delete namespaces -l foo=bar
    #create_namespaces

    while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
        echo "=== Attempt $ATTEMPT/$MAX_ATTEMPTS ==="

        # Create fresh resources
        create_project
        create_applications
        echo

        # Wait a moment for resources to be created
        sleep 2

        # Restart controller to trigger race
        restart_controller
        echo

        # Check for race condition
        if check_race_condition; then
            echo
            show_app_status
            echo "SUCCESS: Race condition reproduced on attempt $ATTEMPT!"
            echo
            echo "To see the fix in action, apply the HasSynced() guard patch and run this script again."
            echo "With the fix, Applications should not get InvalidSpecError for existing projects."
            exit 0
        fi

        show_app_status

        # Cleanup for next attempt
        cleanup
        echo

        ((ATTEMPT++))

        if [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; then
            echo "Waiting 3 seconds before next attempt..."
            sleep 3
        fi
    done

    echo "Failed to reproduce race condition after $MAX_ATTEMPTS attempts."
    echo "The race condition is timing-dependent and may require more attempts."
    echo
    echo "To increase chances of reproducing:"
    echo "1. Run on a cluster with higher API latency"
    echo "2. Increase NUM_APPS to make appInformer List take longer"
    echo "3. Add artificial delay to projInformer startup (see hack/add-proj-delay.patch)"
    exit 1
}

# Handle Ctrl+C
trap cleanup EXIT

# Run main function
main
