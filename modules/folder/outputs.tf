# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "folders" {
  description = "The folders' resource names (folders/N), by display name."
  value       = { for k, f in google_folder.folder : k => f.name }
}
