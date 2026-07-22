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

**Backups/restores work via STREAMING — no bind mount.** The pg-client streams single-file archives
through its std streams (`pg_dump` writes to stdout → *the caller's shell* writes the file;
`pg_restore` and `psql -f` read their input file from stdin). The container touches no host file, so
nothing depends on uid mapping — a **non-root (uid 1000)** container produces **caller-owned** dumps
under rootless Docker, rootless Podman, and rootful docker/podman identically. This is the default
backup format (`-Fc`), so the standard autonomous migration backs up fine under rootless Docker.

**Rootless Docker — two things to plan around (rootless Podman has neither):**

1. **A host-local DB is not reachable.** The rootless daemon runs with `--disable-host-loopback`
   (the default) in its own network namespace, so a database at `127.0.0.1`/`localhost` *on the
   machine* is unreachable — even via `host.docker.internal`. Give the tool a DB it can reach from
   the rootless network: a **routable address** (a different host), or a **container on the same
   rootless network** (`--db-host <container-name>` with `PROFILE_PG_CLIENT_NETWORK=<that-network>` /
   `PROFILE_KC_RUN_NETWORK=<that-network>`). The tool still rewrites a loopback host to
   `host.docker.internal` on the bridge — a best-effort that only helps if the daemon was started
   *with* host-loopback enabled.

2. **Parallel directory dumps (`-Fd`, opt-in) can't stream.** With `parallel_jobs > 1` the backup
   switches to the directory format, which writes many files and needs the bind mount — and a
   non-root container can't write it under rootless Docker (uid 1000 maps to an unwritable subuid;
   Docker has no `--userns=keep-id`). The **default single-file backup is unaffected** (it streams).
   For parallel dumps under rootless Docker, make the work-dir writable by the mapped subuid, or use
   rootless Podman (which handles `-Fd` via `--userns=keep-id`).

## Database connection (`--db-url`, `--db-port`, `--db-schema`)

- `--db-port` — the DB port (default 5432).
- `--db-url postgres://[user[:pass]@]host[:port]/dbname[?currentSchema=S]` — a full connection
  string. Discrete `--db-host/--db-port/--db-name/--db-user/--db-schema` override it. Prefer
  `PROFILE_DB_PASSWORD` / `--env-file` (0600) over a password in the URL (a URL password leaks via
  `ps` and shell history — the tool warns).
- `--db-schema S` — for Keycloak tables in a **non-public** PostgreSQL schema (default `public`).

## Validation status

- **Rootless Podman** — live-validated end to end: non-root pg-client (`id -u`=1000), streaming
  `pg_dump` + `pg_restore` round-trip, dumps **caller-owned**; also handles the parallel `-Fd` format
  via `--userns=keep-id`. Podman is the ALSE / RED OS default.
- **Rootless Docker** — live-validated: `cr_is_rootless` detection, non-root pg-client (uid 1000), a
  **containerized DB reached by name**, and **`pg_dump`/`pg_restore` of the default single-file
  format via streaming** (`rc=0`, dump caller-owned, full restore round-trip). The two caveats above
  apply (a host-local DB is unreachable; the opt-in parallel `-Fd` format can't stream). Detection,
  the loopback rewrite, and the stream/mount split are covered by hermetic tests
  (`tests/test_container_runtime.sh`). The image/non-root guarantees are engine-independent.

Net: the **default autonomous migration runs fully rootless on both engines**; only the opt-in
parallel-dump format is Podman-only under rootless Docker.
