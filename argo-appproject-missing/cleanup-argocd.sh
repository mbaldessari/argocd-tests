#!/bin/bash
# Cleanup ArgoCD installation and test resources
#
# This script removes ArgoCD installation and any test resources
# created by the race reproducer scripts.

set -e

ARGOCD_NAMESPACE=${ARGOCD_NAMESPACE:-argocd}
FORCE=${FORCE:-false}

echo "=== ArgoCD Cleanup Script ==="
echo "Namespace: $ARGOCD_NAMESPACE"
echo

# Check which platform we're on
if oc version --client >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
    PLATFORM="openshift"
    CLI="oc"
elif kubectl cluster-info >/dev/null 2>&1; then
    PLATFORM="kubernetes"
    CLI="kubectl"
else
    echo "ERROR: Cannot connect to cluster (tried both 'oc' and 'kubectl')"
    exit 1
fi

echo "Detected platform: $PLATFORM"
echo "Using CLI: $CLI"
echo

# Function to confirm action
confirm_action() {
    if [[ "$FORCE" != "true" ]]; then
        echo "WARNING: This will DELETE the following:"
        echo "   - ArgoCD instance in namespace '$ARGOCD_NAMESPACE'"
        echo "   - All test Applications and AppProjects"
        echo "   - The '$ARGOCD_NAMESPACE' namespace (if empty)"
        echo
        read -p "Continue? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
}

# Step 1: Cleanup race reproducer test resources
echo "=== Step 1: Cleaning up test resources ==="

echo "Removing race test Applications..."
$CLI delete applications -n "$ARGOCD_NAMESPACE" -l "race-test=true" --ignore-not-found=true

echo "Removing race test AppProjects..."
$CLI delete appprojects -n "$ARGOCD_NAMESPACE" race-test-project --ignore-not-found=true

echo "Test resources cleaned up"
echo

# Step 2: Remove ArgoCD instance
echo "=== Step 2: Removing ArgoCD instance ==="

if $CLI get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    echo "Found namespace '$ARGOCD_NAMESPACE'"

    confirm_action

    if [[ "$PLATFORM" == "openshift" ]]; then
        # OpenShift: Delete ArgoCD CR
        if $CLI get argocd argocd -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
            echo "Deleting ArgoCD custom resource..."
            $CLI delete argocd argocd -n "$ARGOCD_NAMESPACE"

            echo "Waiting for ArgoCD resources to be removed..."
            # Wait for pods to be deleted
            timeout=120
            deadline=$(($(date +%s) + timeout))
            while [[ $(date +%s) -lt $deadline ]]; do
                if ! $CLI get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/part-of=argocd --no-headers 2>/dev/null | grep -q .; then
                    break
                fi
                echo -n "."
                sleep 5
            done
            echo
        else
            echo "ArgoCD custom resource not found"
        fi

    else
        # Kubernetes: Delete all ArgoCD resources
        echo "Deleting all ArgoCD resources..."

        # Try to delete using labels first
        $CLI delete all,cm,secret,sa,role,rolebinding,clusterrole,clusterrolebinding -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/part-of=argocd --ignore-not-found=true

        # Delete specific resources that might remain
        $CLI delete crd -l app.kubernetes.io/part-of=argocd --ignore-not-found=true

        echo "Waiting for resources to be removed..."
        sleep 10
    fi

    echo "ArgoCD instance removed"
else
    echo "Namespace '$ARGOCD_NAMESPACE' not found"
fi

echo

# Step 3: Remove namespace if empty
echo "=== Step 3: Checking namespace ==="

if $CLI get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    resource_count=$($CLI get all -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "$resource_count" -eq 0 ]]; then
        echo "Namespace '$ARGOCD_NAMESPACE' is empty, removing it..."
        $CLI delete namespace "$ARGOCD_NAMESPACE"
        echo "Namespace removed"
    else
        echo "Namespace '$ARGOCD_NAMESPACE' contains other resources, keeping it:"
        $CLI get all -n "$ARGOCD_NAMESPACE" --no-headers | head -5
        if [[ "$resource_count" -gt 5 ]]; then
            echo "... and $((resource_count - 5)) more resources"
        fi
    fi
else
    echo "Namespace '$ARGOCD_NAMESPACE' already removed"
fi

echo

# Step 4: Cleanup operator (OpenShift only, optional)
if [[ "$PLATFORM" == "openshift" ]]; then
    echo "=== Step 4: OpenShift GitOps Operator ==="
    echo "WARNING: OpenShift GitOps Operator is left installed (might be used by other instances)"
    echo "To remove it manually:"
    echo "  $CLI delete subscription openshift-gitops-operator -n openshift-operators"
    echo "  $CLI delete csv \$($CLI get csv -n openshift-operators -o name | grep gitops) -n openshift-operators"
    echo
fi

# Summary
echo "Cleanup completed!"
echo
echo "Summary:"
echo "- Removed ArgoCD instance from namespace '$ARGOCD_NAMESPACE'"
echo "- Removed all race test resources"
if [[ "$resource_count" -eq 0 ]]; then
    echo "- Removed namespace '$ARGOCD_NAMESPACE'"
else
    echo "- Kept namespace '$ARGOCD_NAMESPACE' (contains other resources)"
fi

echo
echo "To reinstall:"
if [[ "$PLATFORM" == "openshift" ]]; then
    echo "./hack/install-custom-argocd.sh"
else
    echo "./hack/install-custom-argocd-k8s.sh"
fi