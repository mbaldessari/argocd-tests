ArgoCD Application with selfHeal enabled.
Point repoURL to wherever you host the 01-app-manifests/ directory
(a git repo, or use a local path if using argocd-server --repo-server).

REPRODUCTION STEPS:

1. Make sure the "transient-ns" namespace does NOT exist
1. Apply this Application: kubectl apply -f 02-application.yaml
1. ArgoCD will attempt to sync and FAIL (namespace doesn't exist)
1. Now create the namespace: kubectl apply -f 03-create-namespace.yaml
1. BUG: ArgoCD never retries — stuck with SyncError "failed previous sync attempt"
1. FIX: With the fix, selfHeal retries after backoff and the sync succeeds
