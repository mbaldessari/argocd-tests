# ArgoCD Race Condition Testing Suite

This directory contains a complete testing suite for the ArgoCD
`InvalidSpecError` race condition that occurs during controller startup.

## The Problem

Applications can get permanently stuck with `InvalidSpecError: Application referencing project X which does not exist` even when the AppProject exists.
This happens due to a race condition during ArgoCD controller startup:

1. `appInformer` and `projInformer` start concurrently in `Run()`
1. `appInformer` completes its initial List first
1. The `NamespaceIndex` indexer fires for each Application
1. Indexer calls `getAppProj()` → reads from empty `projInformer` cache
1. `setAppCondition()` PATCHes `InvalidSpecError` directly to API server
1. Once set, `alreadyAttemptedSync()` prevents retry → app never self-heals

## Quick Start

### 1. Install ArgoCD with Custom Image

```bash
cd /path/to/argo-cd
./install-custom-argocd-k8s.sh
```

These scripts install ArgoCD using the custom image
`quay.io/rhn_support_mbaldess/argocd:v3.3.6_delay200` which contains an added
delay (via the `add-proj-delay.patch` patch) to trigger the race condition.

### 2. Test the Race Condition

```bash
# Test that the race condition is fixed
./race-reproducer.sh
# Should NOT reproduce race with fixed image

# To test against unfixed ArgoCD, modify the install scripts
# to use the standard image and run race-reproducer.sh
```

### 3. Change to a fixed image to test the fix

Just tweak the image to fixed one (e.g. tag `v3.3.6_informerfix`) to verify the
issue is gone.
