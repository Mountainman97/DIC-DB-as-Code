# 8 – Pipelines

The scripts have no dependency on a specific CI system. Any system that can run a Bash step on a Linux
agent with network access to the SQL Server can use them. This document describes the recommended
pipeline design and the shipped examples in [`toolkit/examples/pipelines/`](../toolkit/examples/pipelines):

| File | System | Copy to |
|---|---|---|
| [`azure-pipelines.yml`](../toolkit/examples/pipelines/azure-pipelines.yml) | Azure DevOps Services / Server | `azure-pipelines.yml` |
| [`gitlab-ci.yml`](../toolkit/examples/pipelines/gitlab-ci.yml) | GitLab CI | `.gitlab-ci.yml` |
| [`github-actions.yml`](../toolkit/examples/pipelines/github-actions.yml) | GitHub Actions | `.github/workflows/db.yml` |

## 8.1 Agent / runner requirements

- Linux with SqlPackage, sqlcmd and the .NET SDK ([1 – Installation](01-installation.md)) – or a container
  image with these tools (e.g. built from [`lab/tools/Dockerfile`](../lab/tools/Dockerfile)).
- Network access to the SQL Server instances (typically a **self-hosted** agent inside the hospital
  network; hosted cloud agents usually cannot reach them).
- The toolkit in the checkout: as Git submodule under `tools/dic-db-as-code` (enable submodule checkout)
  or as a copied folder.
- `DB_PASSWORD` as a secret variable, mapped into the environment of each step that connects to a
  database. Use one secret per environment (`DB_PASSWORD_TEST`, `DB_PASSWORD_PROD`, …) and map the right
  one to `DB_PASSWORD`.
- Approvals for deployment stages via the means of the respective system (Azure DevOps Environments,
  GitLab `when: manual` / protected environments, GitHub Environments with required reviewers).

## 8.2 Recommended stage design

```
 ┌───────┐   ┌────────────────────────────────┐   ┌──────────┐   ┌──────────────────────────────────┐
 │ Build │──▶│ Preview (TEST)                 │──▶│ Approval │──▶│ Deploy (TEST)                    │
 │       │   │ db-diff.sh → artifact          │   │          │   │ [db-backup.sh run --              │
 │ db-   │   │ db-data-apply.sh --dry-run     │   │ reviewer │   │   renames → diff → apply → data] │
 │ build │   │ rename scripts listed          │   │ checks   │   └───────────────┬──────────────────┘
 └───────┘   └────────────────────────────────┘   │ preview  │                   ▼
                                                  └──────────┘          same for PROD
```

1. **Build** – `db-build.sh` compiles each SQL project into a DACPAC and publishes it as a pipeline
   artifact. A failing build stops everything (syntax errors, unresolved references).
2. **Preview** – `db-diff.sh` generates change script, deployment report and metadata against the
   target; `db-data-apply.sh --dry-run` lists inserted/updated/deleted rows per table. Both are published
   as artifacts for the reviewer. Nothing is changed.
3. **Approval** – a person checks the preview (data-loss alerts, drops, unexpected row changes).
4. **Deploy** – in **one** job, in this order:
   1. `db-apply-renames.sh` – data-preserving renames,
   2. `db-diff.sh` – generate the change script *now* (the state after the renames),
   3. `db-apply-diff.sh` – execute exactly this script, record it in the history table,
   4. `db-data-apply.sh` – apply configuration data.

   Optionally wrap these four steps in `db-backup.sh run` so that a failure in any of them restores all
   databases ([6 – Backup](06-backup.md)).
5. **Repeat for PROD** with `config/prod.env`, its own approval and its own secret.

Why generate the change script again in the deploy job? A change script is only valid for the state of
the target at generation time. Between preview and approval, renames have not run yet (the preview shows
renamed objects as drop/create) and someone may have changed the target. Generating it right before
execution avoids both problems; the preview remains the basis for the review. If you prefer to execute
the *exact* reviewed file, generate it in the preview, pass it as artifact and call `db-apply-diff.sh`
with it – the script then refuses to run if it does not match the target database and server, and you
should not use rename scripts in the same release.

## 8.3 Multiple databases

Process referenced databases first and use the same order everywhere:

```bash
for DB in DIZ_NET DIZ_NET_stage; do
  $T/db-build.sh --project database/$DB --output artifacts/$DB.dacpac
done
# deploy job
$T/db-apply-renames.sh --env-file config/test.env --dir renames --yes      # all databases at once
for DB in DIZ_NET DIZ_NET_stage; do
  SCRIPT=$($T/db-diff.sh --env-file config/test.env -d $DB --dacpac artifacts/$DB.dacpac)
  $T/db-apply-diff.sh --env-file config/test.env -d $DB --script "$SCRIPT" --yes
done
$T/db-data-apply.sh --env-file config/test.env -d DIZ_NET --yes
```

`db-build.sh` copies referenced DACPACs next to the output, so `artifacts/` contains everything
SqlPackage needs.

## 8.4 Feature-branch DEV databases

On every pull/merge request, provision or update a DEV database named after the request:

```bash
$T/db-provision-dev.sh --env-file config/dev.env -d DIZ_NET_DEV_${MR_ID} \
    --dacpac artifacts/DIZ_NET.dacpac --if-exists update \
    --renames renames --data data/DIZ_NET
```

Add a cleanup job that drops the database when the request is merged or closed (e.g.
`sqlcmd … -Q "DROP DATABASE [DIZ_NET_DEV_${MR_ID}]"`). Do not add DEV databases to
`PROTECTED_DATABASES`.

## 8.5 Scheduled drift checks

A nightly pipeline can detect manual changes in TEST/PROD:

```bash
$T/db-diff.sh --env-file config/prod.env -d DIZ_NET --dacpac artifacts/DIZ_NET.dacpac \
    --skip-empty --fail-on-changes           # exit 3 → schema drift
$T/db-data-apply.sh --env-file config/prod.env -d DIZ_NET --dry-run   # shows row differences
```

Treat exit code 3 as "warning" (e.g. `continueOnError` in Azure DevOps, `allow_failure: exit_codes: 3`
in GitLab) and notify the team.

## 8.6 The examples in detail

### Azure DevOps

- Stages `Build` → `Preview_Test` → `Deploy_Test` (deployment job on the environment `TEST`; configure
  the approval on the environment).
- Variable group `diz-db` provides the secret `DB_PASSWORD`; it is mapped with `env: DB_PASSWORD: $(DB_PASSWORD)`.
- `checkout: self` with `submodules: true` fetches the toolkit.
- The deploy step wraps renames, diff, apply and data in `db-backup.sh run --mode snapshot`.
- Add a `Deploy_Prod` stage by copying `Deploy_Test` and replacing `test` with `prod`.

### GitLab CI

- Stages `build` → `preview` → `deploy`; the DACPAC is passed as job artifact.
- `GIT_SUBMODULE_STRATEGY: recursive` fetches the toolkit.
- `deploy:test` is `when: manual` – use protected environments to restrict who may run it.
- `provision:dev` creates/updates `DIZ_NET_DEV_<MR IID>` for every merge request.
- `DB_PASSWORD` is a masked, protected CI/CD variable.

### GitHub Actions

- Jobs `preview` → `deploy` on a self-hosted Linux runner.
- `actions/checkout@v4` with `submodules: recursive`.
- The `deploy` job uses the environment `test`; configure required reviewers there.
- `DB_PASSWORD` comes from repository or environment secrets.

## 8.7 Audit trail

For each deployment the following evidence exists:

- the Git commit and pull request (what was intended and who approved it),
- the preview artifacts: change script, deployment report, `.meta` (target, commit, checksums),
- the pipeline log including `db-data-apply.sh` row counts,
- the history table in each target database (which script ran when, by whom, with which checksum).

Optionally commit approved change scripts to `deploy/diffs/` for a long-term record.

Next: [9 – Lab walkthrough](09-lab.md)
