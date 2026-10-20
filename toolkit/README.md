# Toolkit

This folder is the part of DIC-DB-as-Code that you embed in your database repository
(e.g. via `git submodule add … tools/dic-db-as-code`).

| Path | Content |
|---|---|
| `scripts/db-extract.sh` | Existing database → `.sql` files + `.sqlproj` + initial DACPAC |
| `scripts/db-build.sh` | SQL project → DACPAC |
| `scripts/db-provision-dev.sh` | Create/update a database from the repository |
| `scripts/db-diff.sh` | Target vs. repository → change script + report + metadata |
| `scripts/db-apply-diff.sh` | Execute one verified change script |
| `scripts/db-new-rename.sh` | Create a rename script from a template |
| `scripts/db-apply-renames.sh` | Execute rename scripts on the database named in the file name |
| `scripts/db-backup.sh` | Optional backup/snapshot, restore on failure, drop on success |
| `scripts/db-data-init.sh` | Set up configuration-data versioning |
| `scripts/db-data-refresh.sh` | Re-export versioned data from a database |
| `scripts/db-data-apply.sh` | Apply versioned data to a database |
| `scripts/lib/` | Shared helpers (`common.sh`, `backup.sh`, `data.sh`, `data-export.sql`) |
| `config/` | Publish profiles (`default.publish.xml`, `dev.publish.xml`), `example.env` |
| `templates/` | `.sqlproj` templates, rename script templates |
| `examples/pipelines/` | Azure DevOps, GitLab CI, GitHub Actions |

Documentation: [../docs/](../docs) – start with [concepts](../docs/02-concepts.md).
