# DIC-DB-as-Code lab

Local Docker test environment for the toolkit: three SQL Server 2022 instances (DIZPROD with test data,
empty DIZTEST and DIZDEV) and a Linux tools container (DIZTOOLS) with sqlpackage, sqlcmd, the .NET SDK and
the toolkit on the `PATH`.

```bash
docker compose up -d --build
docker exec -it DIZTOOLS bash      # work in /workspace
```

| Instance | Host port | Login | Password |
|---|---|---|---|
| DIZPROD | `localhost,14331` | `sa` | `DizProd_2026!` |
| DIZTEST | `localhost,14332` | `sa` | `DizTest_2026!` |
| DIZDEV  | `localhost,14333` | `sa` | `DizDev_2026!` |

Full walkthrough: **[docs/09-lab.md](../docs/09-lab.md)**

| Path | Content |
|---|---|
| `docker-compose.yml` | Services, ports, volumes |
| `.env` | SA passwords (local testing only) |
| `init/prod/` | Seed scripts for DIZPROD (`DIZ_NET`, `DIZ_NET_stage`, `conf`/`pc` tables) |
| `tools/Dockerfile` | Tools container image (also usable as CI image) |
| `workspace/` | Simulated database repository, mounted as `/workspace` (`config/*.env`, `testdata/`) |
