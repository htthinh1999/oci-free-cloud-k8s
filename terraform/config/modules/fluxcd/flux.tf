provider "github" {
  owner = var.gh_org
  token = var.gh_token
}

resource "helm_release" "flux_operator" {
  depends_on = [kubernetes_namespace.flux_system]

  name       = "flux-operator"
  namespace  = kubernetes_namespace.flux_system.id
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  wait       = true

  # No resources block previously - real usage (~186Mi observed) was
  # unaccounted for on the node. Best-effort key (top-level `resources`,
  # the common convention for a single-Deployment chart) - not verified
  # against the chart's values.yaml (network-blocked from the sandbox that
  # authored this), so confirm with `helm show values` before relying on it.
  values = [<<YAML
resources:
  requests:
    cpu: 10m
    memory: 192Mi
  limits:
    memory: 384Mi
YAML
  ]
}

resource "kubernetes_secret" "git_auth" {
  depends_on = [kubernetes_namespace.flux_system]

  metadata {
    name      = "flux-instance-config"
    namespace = kubernetes_namespace.flux_system.id
  }

  data = {
    username                = null
    password                = null
    githubAppID             = "${var.github_app_id}"
    githubAppInstallationID = "${var.github_app_installation_id}"
    githubAppPrivateKey     = "${var.github_app_pem}"
  }

  type = "Opaque"
}

// Configure the Flux instance.
resource "helm_release" "flux_instance" {
  depends_on = [helm_release.flux_operator]

  name       = "flux"
  namespace  = kubernetes_namespace.flux_system.id
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-instance"

  values = [<<YAML
instance:
  distribution:
    version: ${var.flux_version}
    registry: ${var.flux_registry}
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-automation-controller
    - image-reflector-controller
  sync:
    kind: GitRepository
    url: ${var.git_url}
    path: gitops/core
    ref: "refs/heads/main"
    provider: github
    pullSecret: flux-instance-config
  # None of the 6 core controllers had a resources block, so ~500Mi of real
  # combined memory usage was unaccounted for on the node. FluxInstance
  # exposes Kustomize-style strategic-merge patches for exactly this -
  # verified live against the deployed FluxInstance CR (spec.kustomize.patches
  # already existed, empty). Sized from each controller's observed usage.
  kustomize:
    patches:
      - target:
          kind: Deployment
          name: source-controller
        patch: |
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: source-controller
          spec:
            template:
              spec:
                containers:
                  - name: manager
                    resources:
                      requests:
                        cpu: 10m
                        memory: 128Mi
                      limits:
                        memory: 256Mi
      - target:
          kind: Deployment
          name: kustomize-controller
        patch: |
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: kustomize-controller
          spec:
            template:
              spec:
                containers:
                  - name: manager
                    resources:
                      requests:
                        cpu: 10m
                        memory: 192Mi
                      limits:
                        memory: 384Mi
      - target:
          kind: Deployment
          name: helm-controller
        patch: |
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: helm-controller
          spec:
            template:
              spec:
                containers:
                  - name: manager
                    resources:
                      requests:
                        cpu: 10m
                        memory: 160Mi
                      limits:
                        memory: 320Mi
      - target:
          kind: Deployment
          name: notification-controller
        patch: |
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: notification-controller
          spec:
            template:
              spec:
                containers:
                  - name: manager
                    resources:
                      requests:
                        cpu: 10m
                        memory: 96Mi
                      limits:
                        memory: 192Mi
      - target:
          kind: Deployment
          name: image-automation-controller
        patch: |
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: image-automation-controller
          spec:
            template:
              spec:
                containers:
                  - name: manager
                    resources:
                      requests:
                        cpu: 5m
                        memory: 64Mi
                      limits:
                        memory: 128Mi
      - target:
          kind: Deployment
          name: image-reflector-controller
        patch: |
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: image-reflector-controller
          spec:
            template:
              spec:
                containers:
                  - name: manager
                    resources:
                      requests:
                        cpu: 10m
                        memory: 64Mi
                      limits:
                        memory: 128Mi
YAML
  ]
}
