variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "Kubeconfig context to use (defaults to current-context if not specified)"
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "home-k3s"
}

variable "github_owner" {
  description = "GitHub organization or user"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name"
  type        = string
}

variable "github_repository_url" {
  description = "Full GitHub repository URL"
  type        = string
}

variable "github_username" {
  description = "GitHub username for authentication"
  type        = string
  default     = "git"
}

variable "github_token" {
  description = "GitHub personal access token"
  type        = string
  sensitive   = true
}

variable "flux_target_path" {
  description = "Path in Git repository where Flux manifests will be stored"
  type        = string
  default     = "cluster/k3s/flux-system"
}

variable "flux_version" {
  description = "Flux version to install"
  type        = string
  default     = "latest"
}
