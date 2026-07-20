# Keycloak Migration — Quickstart

Migrates a Keycloak database from **16.x** up to **26.6.3** (or **25.0.6**), in place, including in
air-gapped and sovereign-OS environments.

---

## Contents

1. [What this tool actually does](#1-what-this-tool-actually-does)
2. [What you need before you start](#2-what-you-need-before-you-start)
3. [Configuration — three ways in](#3-configuration--three-ways-in)
4. [Every parameter](#4-every-parameter)
5. [Images — three ways to get them](#5-images--three-ways-to-get-them)
6. [Try it safely first](#6-try-it-safely-first)
7. [The real migration, step by step](#7-the-real-migration-step-by-step)
8. [Verify the result](#8-verify-the-result)
9. [Rollback](#9-rollback)
10. [When it goes wrong](#10-when-it-goes-wrong)

---

## 1. What this tool actually does

Keycloak migrates its own database — **on startup**. There is no offline migration tool, and no SQL
script that does it: the work happens in two layers *inside a booting Keycloak*.

| Layer | What runs | Recorded in |
|---|---|---|
| **L1** | Liquibase schema changesets | `DATABASECHANGELOG` |
| **L2** | `RealmMigration` — the model upgrade | `MIGRATION_MODEL` |

L2 only ever runs inside a live server. That is why this tool **boots a real Keycloak container of
each version in turn** against your database, waits for it to finish migrating, and then removes it.
That is the whole idea; everything else is safety around it.

You cannot jump straight from 16 to 26 — Keycloak's migrations are cumulative. The chain is:

```
target 26:   16.x  →  24.0.5  →  26.6.3
target 25:   16.x  →  25.0.6
```

Keycloak **26.6.0** and **26.6.1** are refused outright: they carry migration-breaking defects
(upstream #48438, #47908).

**What the tool checks after every hop**, before it lets the next one start:

- **L1** — Liquibase reported the changesets applied.
- **L2** — `MIGRATION_MODEL` in the database now says the new version. This is the authority. Not the
  container's exit code, not an HTTP probe — the database.
- **L3** — your data is still there: realm and user counts unchanged, client and role counts not
  *shrunk* (a migration adds default clients and roles; it never removes yours).

Any of those failing stops the migration. A backup is taken before each hop, and nothing is restored
without you saying so.

---

## 2. What you need before you start

**On the machine you run this from:**

| | Why |
|---|---|
| `bash` 4+ | the tool |
| `docker` or `podman` | it boots a Keycloak container per hop |
| `psql`, `pg_dump`, `pg_restore` | backups, and reading the migration state out of the database |
| Network access to the database | from *this host*, not from inside a container |
| Free disk on the work dir | one backup per hop, and they are all kept |

The tool **measures** the disk it needs (table data × 1.2 × number of hops) rather than demanding a
fixed amount. It will tell you the number before it starts.

**Your Keycloak must be stopped** for the migration. It is a single-writer operation: two Keycloaks
against one database during a schema migration will fight over the Liquibase lock.

**PostgreSQL 14+** is required for Keycloak 26.

Nothing is written until you pass `--go`. Without it, every command is printed and nothing runs.

---

## 3. Configuration — three ways in

Pick whichever suits you. They all end in the same place.

### (a) Flags

Everything on the command line. Good for a one-off, and for CI.

```bash
export PROFILE_DB_PASSWORD='...'

scripts/migrate_oneshot.sh \
    --target 26 --os astra \
    --db-host 10.0.0.5 --db-port 5432 --db-name keycloak --db-user keycloak \
    --source pull --image-ns ghcr.io/alexgromer/keycloak-migration \
    --work-dir /var/lib/kcwork \
    --go
```

### (b) An env file — the password stays out of your shell history

```bash
cp config/kc-migration.env.example /etc/kc-migration.env
$EDITOR /etc/kc-migration.env
chmod 600 /etc/kc-migration.env          # required: the tool refuses to read it otherwise

scripts/migrate_oneshot.sh --env-file /etc/kc-migration.env --go
```

Not one flag. Every setting, including the password, comes from the file. Flags still override it if
you pass any.

`config/kc-migration.env.example` documents every key.

### (c) The wizard — be asked

```bash
scripts/migrate_oneshot.sh --wizard
```

Eight questions, with auto-discovery of what it can find. It writes `profiles/<name>.yaml` and then
migrates with it.

### Reusing a configuration

Any of the three produces a profile. To run it again — same settings, no re-typing:

```bash
scripts/migrate_oneshot.sh --profile <name> --go
```

---

## 4. Every parameter

### Target and source version

| Flag | Env | Default | Meaning |
|---|---|---|---|
| `--target` | `KC_TARGET` | `26` | Target **major**: `25` or `26`. The hop chain follows from it. |
| `--current` | `KC_CURRENT` | `16.1.1` | Where you are now. Only a hint — the tool reads the real version out of `MIGRATION_MODEL` and skips hops the database has already passed. |

### Database

| Flag | Env | Default |
|---|---|---|
| `--db-host` | `KC_DB_HOST` | `localhost` |
| `--db-port` | `KC_DB_PORT` | `5432` |
| `--db-name` | `KC_DB_NAME` | `keycloak` |
| `--db-user` | `KC_DB_USER` | `keycloak` |
| — | `PROFILE_DB_PASSWORD` | *(required for `--go`)* |

The password is env-only, never a flag — a flag would put it in the process table where any user on
the box can read it.

### Images

| Flag | Env | Default | Meaning |
|---|---|---|---|
| `--os` | `KC_OS` | `astra` | Which sovereign base the images are built on: `astra` or `redos`. |
| `--source` | `KC_SOURCE` | `pull` | `pull` \| `bundle` \| `preloaded` — see §5. |
| `--image-ns` | `KC_IMAGE_NS` | *(our GHCR)* | Registry + repository. Images are then `<ns>:<os>-<version>`. |
| `--image-ref-template` | `KC_IMAGE_REF_TEMPLATE` | — | Your own naming. `{version}` is replaced per hop. Overrides `--image-ns`. |
| `--bundle` | `KC_BUNDLE` | — | Path to the offline `.tar.xz` (with `--source bundle`). |
| `--network` | `KC_NETWORK` | `host` | Container network. `host` reaches a database on the host; use a bridge if the database is in one. |

### Safety

| Flag | Meaning |
|---|---|
| *(none)* | **Dry run.** Prints every command, changes nothing. This is the default. |
| `--go` | Actually do it. |
| `--work-dir DIR` | Where backups, logs and state live. **A work dir you supply is never deleted.** Point it somewhere roomy. |
| `--apply-indexes` | Create the indexes Keycloak skips on large tables — see below. |
| `--skip-preflight` | Skip the pre-migration checks. You are on your own. |
| `--kill-stale` | Kill a hung migration process from an earlier attempt instead of refusing to start. |
| `--force-unlock` | Release a Liquibase lock left behind by a crashed migration. |
| `--no-resume` | Ignore checkpoints from a previous attempt and redo every step. |

### Environment-only settings

| Variable | Meaning |
|---|---|
| `PROFILE_APPLY_SKIPPED_INDEXES=true` | Same as `--apply-indexes`. |
| `PROFILE_VERIFY_BACKUP_RESTORE=true` | **Prove** each backup restores — restore it into a scratch database and compare row counts — instead of just checking the file parses. Costs a full restore's time and disk. Worth it before a production migration. |
| `PROFILE_KC_ADMIN_USER` / `PROFILE_KC_ADMIN_PASSWORD` | Only used by `verify`, to exercise the Admin API afterwards. |
| `CONTAINER_RUNTIME=docker\|podman` | Autodetected when unset. |

### About `--apply-indexes`

Above roughly **300,000 rows**, Keycloak *refuses to build an index during startup* — it would block
the boot — and writes the `CREATE INDEX` statement to its log instead.

The migration then **succeeds, with indexes missing.** Nothing fails. The database is simply slow
afterwards, and the reason is a log line nobody read.

The preflight will name any table over the threshold. If it does, pass `--apply-indexes`: the
statements are applied `CONCURRENTLY` after each hop, so no table is locked. (Without the flag they
are still captured, to `<work-dir>/skipped_indexes_<version>.sql`, for you to apply by hand.)

---

## 5. Images — three ways to get them

Each hop needs a Keycloak container image of that exact version. **They do not have to be ours.**

### (a) From a registry — including your own

```bash
--source pull --image-ns registry.corp.local/keycloak/kc-migration
```

resolves to `registry.corp.local/keycloak/kc-migration:astra-26.6.3` and so on per hop. Log in to the
registry first (`docker login`); the tool does not handle credentials.

### (b) From your registry, under *your* naming

If your registry already holds Keycloak images and they are **not** named `<os>-<version>`, describe
them instead of renaming them:

```bash
--source pull --image-ref-template 'registry.corp.local/keycloak:{version}'
```

`{version}` is replaced per hop → `registry.corp.local/keycloak:24.0.5`,
`registry.corp.local/keycloak:26.6.3`. Anything your runtime can pull works.

### (c) Images already on the host

If they are loaded into Docker/Podman already — air-gapped host, images shipped separately, whatever:

```bash
--source preloaded --image-ref-template 'kc:{version}'
```

Nothing is fetched. The tool asserts each image is present and fails loudly if one is not.

### (d) From our air-gap bundle

```bash
--source bundle --bundle /opt/dist/kc-astra-bundle.tar.xz
```

The bundle is a `tar.xz` of one `docker save` tarball per hop. Build one with:

```bash
scripts/build_matrix.sh --build          # builds the per-hop images
scripts/build_bundle.sh --os astra --go  # packs them, with a checksum
```

> The sovereign images are built **from your own licensed Astra/RED OS base**. The recipes
> (`containerfiles/`) ship with this tool; the base images never do. See `docs/AIRGAP.md`.

---

## 6. Try it safely first

Two ways, in increasing order of confidence.

**Dry run** — against your real settings, changing nothing:

```bash
scripts/migrate_oneshot.sh --env-file /etc/kc-migration.env
```

No `--go`. It prints the hop chain, the images it would use, the disk it needs, and every command it
would run. It touches nothing.

**The harness** — a full migration against a *synthetic* database, on a throwaway PostgreSQL:

```bash
scripts/harness/run_migration_harness.sh --go
```

It stands up its own PostgreSQL, boots a Keycloak 16, **seeds realms, users and clients**, runs the
entire hop chain, and checks L1, L2 and data integrity after each one. Nothing of yours is touched.
This is how you find out the tool works here before you point it at production.

---

## 7. The real migration, step by step

```bash
# 1. Stop your Keycloak. It is a single-writer operation.
systemctl stop keycloak        # or: docker compose down, kubectl scale --replicas=0, ...

# 2. Dry run. Read what it says.
scripts/migrate_oneshot.sh --env-file /etc/kc-migration.env

# 3. Go.
scripts/migrate_oneshot.sh --env-file /etc/kc-migration.env --work-dir /var/lib/kcwork --go
```

What happens, per hop:

| | Step | If it fails |
|---|---|---|
| 1 | **Reconcile** — read the real version from `MIGRATION_MODEL`; skip hops already applied | — |
| 2 | **Preflight** — disk (measured), database reachable, version, large tables | Stops before touching anything |
| 3 | **Baseline** — count realms, users, clients, roles (once, before any hop) | — |
| 4 | **Backup** — `pg_dump` before *this* hop | Stops |
| 5 | **Boot** the Keycloak container of this version | Stops; container logs are printed |
| 6 | **Wait** — watch the database until `MIGRATION_MODEL` advances | Stops on timeout |
| 7 | **L2 gate** — confirm `MIGRATION_MODEL` says the new version | Stops, **offers rollback** |
| 8 | **L3 gate** — confirm the data survived | Stops, **offers rollback** |
| 9 | **Indexes** — capture (and with `--apply-indexes`, create) any Keycloak skipped | Warns |
| 10 | **Remove** the container, so the next hop has the database to itself | — |

Then the next hop, from step 4.

Rollback is **never** automatic. It is offered when the database itself says the hop did not apply,
and the default answer is no. Nothing gets restored while you are not looking.

**If you Ctrl-C mid-run:** the tool puts back the Keycloak it stopped, releases its lock, and tells
you how to check where the database ended up.

---

## 8. Verify the result

The migration deliberately leaves **no running Keycloak** — the last container is removed so it
cannot hold the Liquibase lock. To check the result:

```bash
scripts/migrate_keycloak_v3.sh verify --profile <name>
```

This boots **the same image that performed the migration** against the migrated database, with
health enabled, and:

- confirms `MIGRATION_MODEL` is at the target version,
- confirms the data invariants still hold,
- waits for `/health/ready`,
- runs the Admin API smoke tests — realms, clients, users, token issuance,
- removes the container.

The Admin API part needs `PROFILE_KC_ADMIN_USER` and `PROFILE_KC_ADMIN_PASSWORD`. Without them
`verify` still checks the database and readiness, and tells you exactly what it could **not** check.

> Verify with the image you migrated with, not a stock Keycloak of the same version — otherwise you
> are testing a different artifact than the one you are about to run.

Once it passes, start Keycloak normally on the target version, against the same database.

---

## 9. Rollback

A backup is taken **before every hop** and kept in `<work-dir>/backups/`.

```bash
scripts/migrate_keycloak_v3.sh rollback --profile <name>
```

It takes a safety copy of the current state first, restores the last pre-hop backup, and clears the
checkpoints for the hop it undid — so a later resume does not skip the migration it now has to redo.

To be certain a backup will restore *before* you rely on it:

```bash
PROFILE_VERIFY_BACKUP_RESTORE=true scripts/migrate_oneshot.sh --env-file ... --go
```

Each backup is then restored into a scratch database and its row counts compared with the source. A
backup you have never restored is a hope, not a backup.

---

## 10. When it goes wrong

| Symptom | What it means | Do this |
|---|---|---|
| `Another migration is ALREADY RUNNING (PID n)` | A previous attempt is still alive. Two runs fight over the container name and kill each other's containers mid-migration. | `kill <pid>`, or re-run with `--kill-stale` |
| `Liquibase changelog lock is HELD` | A migration crashed while holding it. Every later Keycloak now blocks on it. | Confirm nothing is running, then `--force-unlock` |
| `MIGRATION_MODEL did not advance` | The hop did not apply. The database is where it was before it started. | Read the container logs it printed. The backup is in `<work-dir>/backups/`. |
| `DATA INTEGRITY VIOLATED` | The schema migrated; rows that should have survived did not. | **Stop.** Do not continue. Roll back, and report it. |
| `Insufficient backup space: X < Y` | Measured, not guessed: table data × 1.2 × hops. | `--work-dir` somewhere roomier |
| `preloaded: image not present locally` | The image is not loaded under the name the tool expects. | `docker images`, then point `--image-ref-template` at the real name |
| `it holds a database password` | Your `--env-file` is world-readable. | `chmod 600` |
| Health check says 404 | Nothing is wrong. Keycloak only serves `/health` with `KC_HEALTH_ENABLED=true` (and from KC 25 on port 9000). It is **not** a migration failure and never blocks one. | Use `verify` for a real check |

**Where things are:** `<work-dir>/` holds the state file, the container logs (`kc_startup_*.log`),
any captured `skipped_indexes_*.sql`, and `backups/` with one dump per hop.

**Resume:** a failed migration can simply be re-run. It reads the real state out of the database and
carries on from where it actually is — not from where a journal claims it got to.
