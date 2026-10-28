output "flux_deploy_key" {
  description = "Public SSH key for Flux deploy key"
  value       = tls_private_key.flux.public_key_openssh
}
