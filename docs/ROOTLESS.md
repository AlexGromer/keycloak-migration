# Rootless & non-root operation

The tool is designed to run with **no root anywhere**:

1. **Non-root inside every container.** The Keycloak hop images and the sovereign pg-client image
   both run as **uid 1000** (`USER 1000`) — `psql`/`pg_dump`/`pg_restore` and the migrating Keycloak
   server are unprivileged processes inside the container.
2. **Rootless container engine.** The tool runs under a **rootless** Docker or Podman daemon (no
   root on the host either). It auto-detects rootless (`cr_is_rootless`) and adapts networking and
   file-ownership accordingly. Rootful engines keep working byte-identically — nothing here changes
   the rootful path.

On the sovereign targets (ALSE / RED OS) **Podman is the default engine and is rootless-native** —
this is the recommended, zero-setup path.

## Engines

### Podman (rootless-native — recommended)

Podman needs no daemon and no setup to run rootless. Point the tool at it:

```
export CONTAINER_RUNTIME=podman
```

`--network=host` under rootless Podman shares the host network namespace, so a host-local database at
`127.0.0.1` is reachable as-is. For a bind-mounted backup directory the tool adds `--userns=keep-id`
so the non-root container writes dumps that are **owned by you** and readable back.

### Docker (rootless)

Rootful Docker is unaffected. To run rootless Docker (a separate per-user daemon on its own socket —
it does **not** touch or replace the system rootful daemon):

```
# prerequisites (once, needs root): uidmap, slirp4netns, fuse-overlayfs, rootlesskit,
# and a subuid/subgid range for your user
sudo apt-get install -y uidmap slirp4netns fuse-overlayfs rootlesskit    # Debian/Astra
sudo dnf install -y shadow-utils slirp4netns fuse-overlayfs rootlesskit  # RED OS/RHEL
grep "^$USER:" /etc/subuid /etc/subgid   # must show a range; if empty: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"

# install + start the rootless daemon (ships with docker; on Debian it is under contrib)
dockerd-rootless-setuptool.sh install        # or: /usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh install
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock   # or: docker context use rootless
export CONTAINER_RUNTIME=docker
```

**Rootless Docker — two limitations to plan around (rootless Podman has neither):**

1. **A host-local DB is not reachable.** The rootless daemon runs with `--disable-host-loopback`
   (the default) in its own network namespace, so a database at `127.0.0.1`/`localhost` *on the
   machine* is unreachable — even via `host.docker.internal`. Give the tool a DB it can reach from
   the rootless network: a **routable address** (a different host), or a **container on the same
   rootless network** (`--db-host <container-name>` with `PROFILE_PG_CLIENT_NETWORK=<that-network>` /
   `PROFILE_KC_RUN_NETWORK=<that-network>`). The tool still rewrites a loopback host to
   `host.docker.internal` on the bridge — a best-effort that only helps when the daemon was started
   *with* host-loopback enabled.

2. **Backups/restores (bind-mount writes) fail.** The pg-client runs non-root (uid 1000), which
   rootless Docker maps to an unwritable subuid, so `pg_dump`/`pg_restore` cannot write the backup
   into the work-dir (`Permission denied`). Docker has no equivalent of Podman's `--userns=keep-id`
   (which maps the container uid back to you). Read-only work (`psql` queries) is fine. **For a full
   rootless migration — which backs up before every hop — use rootless Podman.**

## Database connection (`--db-url`, `--db-port`, `--db-schema`)

- `--db-port` — the DB port (default 5432).
- `--db-url postgres://[user[:pass]@]host[:port]/dbname[?currentSchema=S]` — a full connection
  string. Discrete `--db-host/--db-port/--db-name/--db-user/--db-schema` override it. Prefer
  `PROFILE_DB_PASSWORD` / `--env-file` (0600) over a password in the URL (a URL password leaks via
  `ps` and shell history — the tool warns).
- `--db-schema S` — for Keycloak tables in a **non-public** PostgreSQL schema (default `public`).

## Validation status

- **Rootless Podman** — live-validated end to end: non-root pg-client (`id -u`=1000), `psql` +
  `pg_dump` + `pg_restore` all work, dumps land **caller-owned** via `--userns=keep-id`, full
  dump→restore round-trip. **This is the supported full-autonomy rootless path** (and Podman is the
  ALSE / RED OS default).
- **Rootless Docker** — live-run: detection works (`cr_is_rootless` sees `name=rootless`), the
  pg-client runs non-root (uid 1000), and `psql` reaches a **containerized** DB by name. Its two
  limitations above are real (bind-mount writes fail; a host-local DB is unreachable), so rootless
  Docker fits read-only/verify or a containerized/routable DB with backups delegated to Podman.
  Detection + the loopback rewrite are also covered by hermetic tests
  (`tests/test_container_runtime.sh`). The image/non-root guarantees are engine-independent.
