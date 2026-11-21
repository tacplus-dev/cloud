# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

# The stacks pin the exact versions (stacks/*/versions.tf and their lock files); a module states what it works with.
terraform {
  required_version = ">= 1.13.2"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.9.0, < 9.0.0"
      # google.quotas: the quota preferences', its calls counted against the dev project (#90).
      configuration_aliases = [google.quotas]
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.4.0, < 4.0.0"
    }
  }
}
