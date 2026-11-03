# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "org_id" {
  description = "The organization's numeric ID."
  value       = data.google_organization.org.org_id
}

output "folders" {
  description = "The folders' resource names (folders/N), by display name."
  value       = { for k, f in google_folder.folder : k => f.name }
}
