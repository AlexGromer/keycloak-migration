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

**Host-loopback caveat (rootless Docker only).** A rootless dockerd's `--network=host` is the
daemon's *own* network namespace, **not** the machine's — so a database at `127.0.0.1`/`localhost`
is NOT reachable through it. The tool detects this exact case (rootless + docker + a loopback DB
host) and automatically rewrites the connection to `host.docker.internal` on the default bridge via
`--add-host=host.docker.internal:host-gateway`. A database on a routable address (a different host)
is unaffected. Rootless Podman does not need this.

## Database connection (`--db-url`, `--db-port`, `--db-schema`)

- `--db-port` — the DB port (default 5432).
- `--db-url postgres://[user[:pass]@]host[:port]/dbname[?currentSchema=S]` — a full connection
  string. Discrete `--db-host/--db-port/--db-name/--db-user/--db-schema` override it. Prefer
  `PROFILE_DB_PASSWORD` / `--env-file` (0600) over a password in the URL (a URL password leaks via
  `ps` and shell history — the tool warns).
- `--db-schema S` — for Keycloak tables in a **non-public** PostgreSQL schema (default `public`).

## Validation status

- **Rootless Podman:** live-validated — non-root pg-client (`id -u`=1000), `psql`/`pg_dump`/
  `pg_restore` work, dumps land caller-owned via `--userns=keep-id`, full dump→restore round-trip.
- **Rootless Docker:** the detection + host-loopback rewrite are covered by hermetic tests
  (`tests/test_container_runtime.sh`); a live run needs the rootless daemon set up as above (it
  requires the one-time root prerequisites). The image/non-root guarantees are engine-independent.
