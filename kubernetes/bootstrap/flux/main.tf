resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "github_repository_deploy_key" "flux" {
  title      = "Flux (${var.cluster_name})"
  repository = var.github_repository
  key        = tls_private_key.flux.public_key_openssh
  read_only  = false
}

resource "flux_bootstrap_git" "this" {
  depends_on = [github_repository_deploy_key.flux]

  path               = var.flux_target_path
  embedded_manifests = true
  interval           = "1m"
  version            = var.flux_version
}
