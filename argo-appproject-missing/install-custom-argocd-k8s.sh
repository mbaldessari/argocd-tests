#!/bin/bash
# Install ArgoCD with custom image on vanilla Kubernetes cluster
#
# This script installs ArgoCD using the custom image quay.io/rhn_support_mbaldess/argocd:v3.3.6_pristine
# which contains the fix for the InvalidSpecError race condition.

set -e

ARGOCD_NAMESPACE="argocd"
CUSTOM_IMAGE="quay.io/rhn_support_mbaldess/argocd"
CUSTOM_VERSION="v3.3.6_delay200"
#CUSTOM_VERSION="v3.3.6_pristine"
#CUSTOM_VERSION="v3.3.6_akosfix_delay200"
ARGOCD_MANIFESTS_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
# Use standard Redis image (reverted from Red Hat due to entrypoint issues)
REDIS_IMAGE="redis:7.2.4-alpine"

echo "=== Installing ArgoCD with Custom Image (Kubernetes) ==="
echo "Namespace: $ARGOCD_NAMESPACE"
echo "Custom Image: $CUSTOM_IMAGE:$CUSTOM_VERSION"
echo

# Check if we can talk to the cluster
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to Kubernetes cluster."
    exit 1
fi

echo "Connected to Kubernetes cluster: $(kubectl cluster-info | head -1)"

# Detect if this is OpenShift
IS_OPENSHIFT="false"
if oc version --client >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
    IS_OPENSHIFT="true"
    echo "WARNING: OpenShift detected. Consider using './hack/install-custom-argocd.sh' instead for better OpenShift integration."
    echo "Continuing with Kubernetes-style installation with OpenShift compatibility fixes..."
fi

echo

# Step 1: Create ArgoCD namespace
echo "=== Step 1: Creating ArgoCD namespace ==="

if kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace $ARGOCD_NAMESPACE already exists"
else
    echo "Creating namespace $ARGOCD_NAMESPACE..."
    kubectl create namespace "$ARGOCD_NAMESPACE"
fi

echo

# Step 2: Install ArgoCD with custom image
echo "=== Step 2: Installing ArgoCD with custom image ==="

echo "Downloading ArgoCD manifests..."
curl -sSL "$ARGOCD_MANIFESTS_URL" > /tmp/argocd-install.yaml

echo "Patching manifests to use custom images..."
# Replace all argoproj/argocd images with our custom image
sed -i.bak "s|image: quay.io/argoproj/argocd:.*|image: $CUSTOM_IMAGE:$CUSTOM_VERSION|g" /tmp/argocd-install.yaml

# Replace Redis images with standard Redis
echo "Using standard Redis image: $REDIS_IMAGE"
sed -i "s|image: redis:.*|image: $REDIS_IMAGE|g" /tmp/argocd-install.yaml
sed -i "s|image: quay.io/redis/redis:.*|image: $REDIS_IMAGE|g" /tmp/argocd-install.yaml

# Handle OpenShift Security Context Constraints
if [[ "$IS_OPENSHIFT" == "true" ]]; then
    echo "Applying OpenShift security context fixes..."

    # Remove securityContext constraints that conflict with OpenShift
    # This removes runAsUser, runAsGroup, and fsGroup specifications
    python3 -c "
import yaml
import sys

# Read the manifests
with open('/tmp/argocd-install.yaml', 'r') as f:
    docs = list(yaml.safe_load_all(f))

# Patch deployments to remove problematic securityContext
for doc in docs:
    if not doc:
        continue

    if doc.get('kind') == 'Deployment':
        deployment_name = doc.get('metadata', {}).get('name', '')

        # Remove pod-level securityContext
        pod_spec = doc.get('spec', {}).get('template', {}).get('spec', {})
        if 'securityContext' in pod_spec:
            # Keep only what's needed, remove user/group settings
            sc = pod_spec['securityContext']
            # Remove runAsUser, runAsGroup, fsGroup for OpenShift compatibility
            for key in ['runAsUser', 'runAsGroup', 'fsGroup', 'runAsNonRoot']:
                sc.pop(key, None)
            print(f'Cleaned securityContext for {deployment_name}')

        # Remove container-level securityContext that might conflict
        containers = pod_spec.get('containers', [])
        for container in containers:
            if 'securityContext' in container:
                sc = container['securityContext']
                for key in ['runAsUser', 'runAsGroup']:
                    sc.pop(key, None)
                # If securityContext is now empty, remove it
                if not sc:
                    container.pop('securityContext')

        # Also check initContainers
        init_containers = pod_spec.get('initContainers', [])
        for container in init_containers:
            if 'securityContext' in container:
                sc = container['securityContext']
                for key in ['runAsUser', 'runAsGroup']:
                    sc.pop(key, None)
                if not sc:
                    container.pop('securityContext')

# Write back the manifests
with open('/tmp/argocd-install.yaml', 'w') as f:
    yaml.dump_all(docs, f, default_flow_style=False)

print('Applied OpenShift security context fixes')
"
fi

echo "Applying patched manifests..."
kubectl apply -n "$ARGOCD_NAMESPACE" -f /tmp/argocd-install.yaml --server-side --force-conflicts

# Handle OpenShift SCC permissions
if [[ "$IS_OPENSHIFT" == "true" ]]; then
    echo "Configuring OpenShift Security Context Constraints..."

    # Wait a moment for service accounts to be created
    sleep 5

    # Grant anyuid SCC to ArgoCD service accounts to allow containers to run
    # This is needed because standard ArgoCD images may not follow OpenShift's default security constraints
    ARGOCD_SERVICE_ACCOUNTS=(
        "argocd-application-controller"
        "argocd-dex-server"
        "argocd-redis"
        "argocd-repo-server"
        "argocd-server"
    )

    for sa in "${ARGOCD_SERVICE_ACCOUNTS[@]}"; do
        if kubectl get serviceaccount "$sa" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
            echo "Granting anyuid SCC to service account $sa..."
            oc adm policy add-scc-to-user anyuid "system:serviceaccount:$ARGOCD_NAMESPACE:$sa" >/dev/null 2>&1 || {
                echo "WARNING: Failed to grant SCC to $sa (may not have cluster-admin privileges)"
            }
        else
            echo "WARNING: Service account $sa not found, will be created later"
        fi
    done

    # Also try to grant to default service account as fallback
    if kubectl get serviceaccount default -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        echo "Granting anyuid SCC to default service account as fallback..."
        oc adm policy add-scc-to-user anyuid "system:serviceaccount:$ARGOCD_NAMESPACE:default" >/dev/null 2>&1 || {
            echo "WARNING: Failed to grant SCC to default SA (may not have cluster-admin privileges)"
        }
    fi

    echo "OpenShift SCC configuration completed"
    echo "   If pods still fail to start, ensure you have cluster-admin privileges"
    echo "   or ask your OpenShift admin to grant 'anyuid' SCC to ArgoCD service accounts"
fi

echo "Ensuring all required secrets exist..."

# Wait for initial secrets to be created
timeout=60
deadline=$(($(date +%s) + timeout))
while [[ $(date +%s) -lt $deadline ]]; do
    if kubectl get secret argocd-secret -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        break
    fi
    echo "Waiting for argocd-secret to be created..."
    sleep 2
done

# 1. Fix argocd-secret (add server.secretkey if missing)
if kubectl get secret argocd-secret -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    echo "Checking argocd-secret..."
    if kubectl get secret argocd-secret -n "$ARGOCD_NAMESPACE" -o jsonpath='{.data.server\.secretkey}' >/dev/null 2>&1; then
        echo "server.secretkey already exists in argocd-secret"
    else
        echo "Adding server.secretkey to argocd-secret..."
        SERVER_SECRET_KEY=$(openssl rand -base64 32)
        kubectl patch secret argocd-secret -n "$ARGOCD_NAMESPACE" --type='json' \
            -p="[{\"op\": \"add\", \"path\": \"/data/server.secretkey\", \"value\": \"$(echo -n "$SERVER_SECRET_KEY" | base64 -w 0)\"}]"
        echo "Added server.secretkey to argocd-secret"
    fi
else
    echo "ERROR: argocd-secret not found, ArgoCD installation may have failed"
    kubectl get secrets -n "$ARGOCD_NAMESPACE"
    exit 1
fi

# 2. Create argocd-redis secret if missing
if ! kubectl get secret argocd-redis -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    echo "Creating missing argocd-redis secret..."
    # Generate Redis auth with default password
    kubectl create secret generic argocd-redis -n "$ARGOCD_NAMESPACE" \
        --from-literal=auth="test123" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "Created argocd-redis secret"
else
    echo "argocd-redis secret already exists"
fi

# 3. Create argocd-redis-ha-haproxy secret if missing (used by some configurations)
if ! kubectl get secret argocd-redis-ha-haproxy -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    echo "Creating argocd-redis-ha-haproxy secret..."
    kubectl create secret generic argocd-redis-ha-haproxy -n "$ARGOCD_NAMESPACE" \
        --from-literal=auth="test123" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "Created argocd-redis-ha-haproxy secret"
else
    echo "argocd-redis-ha-haproxy secret already exists"
fi

# 4. Restart components that might need the new secrets
echo "Restarting ArgoCD components to pick up updated secrets..."
kubectl delete pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-server || true
kubectl delete pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-dex-server || true
kubectl delete pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server || true

echo "Waiting for pods to restart..."
sleep 10

echo "Using standard Redis image: $REDIS_IMAGE"
echo "Standard Redis image provides good compatibility"

echo "Waiting for ArgoCD components to be ready..."
# Wait for all deployments to be available
for deployment in argocd-server argocd-application-controller argocd-repo-server argocd-dex-server argocd-redis; do
    if kubectl get deployment "$deployment" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        echo "Waiting for deployment/$deployment to be ready..."
        kubectl wait --for=condition=available --timeout=600s deployment/"$deployment" -n "$ARGOCD_NAMESPACE" || {
            echo "WARNING: Deployment $deployment failed to become ready, checking status..."
            kubectl get deployment "$deployment" -n "$ARGOCD_NAMESPACE" -o wide
            kubectl describe deployment "$deployment" -n "$ARGOCD_NAMESPACE" | tail -10
        }
    else
        echo "WARNING: Deployment $deployment not found"
    fi
done

echo "Checking pod status..."
kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/part-of=argocd

# Check for any crashlooping or failed pods
echo "Checking for any failed pods after secret fixes..."
sleep 5  # Give pods time to restart
kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/part-of=argocd

FAILED_PODS=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/part-of=argocd --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null || echo "")
if [[ -n "$FAILED_PODS" ]]; then
    echo "WARNING: Found failed/pending pods. Showing details:"

    # Show current secrets for debugging
    echo "=== Available secrets ==="
    kubectl get secrets -n "$ARGOCD_NAMESPACE" | grep -E "(argocd|redis)"
    echo

    for pod in $FAILED_PODS; do
        pod_name=$(echo "$pod" | cut -d'/' -f2)
        echo "=== Details for $pod_name ==="
        kubectl describe pod "$pod_name" -n "$ARGOCD_NAMESPACE" | tail -15
        echo "=== Logs for $pod_name ==="
        kubectl logs "$pod_name" -n "$ARGOCD_NAMESPACE" --tail=20 2>/dev/null || echo "Could not get logs for $pod_name"
        echo
    done

    echo "If issues persist, check:"
    echo "1. Secret contents: kubectl get secret argocd-redis -n $ARGOCD_NAMESPACE -o yaml"
    echo "2. Pod events: kubectl get events -n $ARGOCD_NAMESPACE --sort-by='.lastTimestamp'"
    echo "3. Restart all pods: kubectl delete pods -n $ARGOCD_NAMESPACE -l app.kubernetes.io/part-of=argocd"

    if [[ "$IS_OPENSHIFT" == "true" ]]; then
        echo
        echo "OpenShift-specific troubleshooting:"
        echo "4. Check SCC permissions: oc get scc anyuid -o yaml | grep users"
        echo "5. Grant SCC manually: oc adm policy add-scc-to-user anyuid system:serviceaccount:$ARGOCD_NAMESPACE:<sa-name>"
        echo "6. Use OpenShift GitOps instead: ./hack/install-custom-argocd.sh"
    fi
else
    echo "All ArgoCD pods are running"
fi

echo

# Step 3: Get ArgoCD access information
echo "=== Step 3: ArgoCD Access Information ==="

echo "Getting admin password..."
ADMIN_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n "$ARGOCD_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [[ -n "$ADMIN_PASSWORD" ]]; then
    echo "Admin username: admin"
    echo "Admin password: $ADMIN_PASSWORD"
else
    echo "WARNING: Admin password not found in argocd-initial-admin-secret"
fi

echo "Setting up port forwarding to access ArgoCD server..."
echo "Run this command in another terminal to access ArgoCD:"
echo "kubectl port-forward svc/argocd-server -n $ARGOCD_NAMESPACE 8080:80"
echo "Then open: http://localhost:8080"
echo

# Step 4: Verify custom image
echo "=== Step 4: Verifying Custom Image ==="

echo "Checking deployments for custom image..."
for deployment in argocd-application-controller argocd-server argocd-repo-server; do
    if kubectl get deployment "$deployment" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        image=$(kubectl get deployment "$deployment" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
        echo "Deployment: $deployment"
        echo "Image: $image"
        if [[ "$image" == "$CUSTOM_IMAGE:$CUSTOM_VERSION" ]]; then
            echo "Custom image confirmed!"
        else
            echo "WARNING: Expected $CUSTOM_IMAGE:$CUSTOM_VERSION, got $image"
        fi
        echo
    fi
done

# Step 5: Final status
echo "=== Step 5: Final Status ==="

echo "ArgoCD resources in namespace $ARGOCD_NAMESPACE:"
kubectl get all -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/part-of=argocd

echo

# Success summary
echo "SUCCESS! ArgoCD installation completed."
echo
echo "Summary:"
echo "- Custom ArgoCD Image: $CUSTOM_IMAGE:$CUSTOM_VERSION"
echo "- Redis Image: $REDIS_IMAGE"
echo "- Namespace: $ARGOCD_NAMESPACE"
if [[ -n "$ADMIN_PASSWORD" ]]; then
    echo "- Admin Login: admin / $ADMIN_PASSWORD"
fi
echo
echo "To access ArgoCD:"
echo "1. kubectl port-forward svc/argocd-server -n $ARGOCD_NAMESPACE 8080:80"
echo "2. Open http://localhost:8080"
echo "3. Login with admin / $ADMIN_PASSWORD"
echo
echo "To test the race condition fix:"
echo "1. cd /path/to/argo-cd"
echo "2. ARGOCD_NAMESPACE=$ARGOCD_NAMESPACE ./hack/race-reproducer.sh"
echo
echo "To uninstall:"
echo "kubectl delete -n $ARGOCD_NAMESPACE -f /tmp/argocd-install.yaml"
echo "kubectl delete namespace $ARGOCD_NAMESPACE"

# Cleanup
rm -f /tmp/argocd-install.yaml /tmp/argocd-install.yaml.bak
