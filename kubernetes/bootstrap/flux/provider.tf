terraform {
  required_version = ">= 1.8.0"

  required_providers {
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.7.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.11.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3.0"
    }
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

provider "kubectl" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

provider "flux" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kubeconfig_context
  }
  git = {
    url = var.github_repository_url
    http = {
      username = var.github_username
      password = var.github_token
    }
  }
}

provider "github" {
  owner = var.github_owner
  token = var.github_token
}
