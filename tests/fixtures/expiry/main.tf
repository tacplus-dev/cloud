# Memberships with expiries, as stacks/gitlab/main.tf writes them: one a line.
members = {
  "tacplus-dev/build:far-bot"     = { access_level = "reporter", expires_at = "2027-10-15" }
  "tacplus-dev/build:soon-bot"    = { access_level = "reporter", expires_at = "2027-09-15" }
  "tacplus-dev/build:expired-bot" = { access_level = "reporter", expires_at = "2027-08-31" }
}
