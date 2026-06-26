# Air-gapped distribution — Keycloak × sovereign-OS images

This tool ships as **recipes (public)** + **images (private)**. You build the Keycloak
hop images FROM your **licensed** Astra SE / RED OS bases on a connected host, then carry
the resulting tarballs (or pull from a private registry) into the air-gapped contour.

> **Licence boundary:** sovereign base images are operator-supplied and must never be
> committed to the repo. Built images live only in a **private** GHCR / Release / offline
> media. The repo holds only Containerfiles, `build_matrix.sh`, and this runbook.

## 0. Configure (edit one file)

```bash
cp config/images.conf.example config/images.conf   # config/images.conf is gitignored
```
Edit `config/images.conf`:
- **Build bases:** `ASTRA_BASE`, `ASTRA_BASE_KC16`, `REDOS_BASE`, `REDOS_BASE_KC16`.
- **Registry/output:** `GHCR_IMAGE`, `OUT_DIR`.
- **Use a pre-built / branded Keycloak instead of building a cell:**
  `USE_IMAGE_<os>_<ver_underscored>="registry.local/kk-branded:26.6.3-astra"`.

Precedence: ambient env < `config/images.conf` < CLI flag.

## 1. Plan (dry-run — mutates nothing)

```bash
scripts/build_matrix.sh                 # prints the 8-cell plan
scripts/build_matrix.sh --publish       # plan including GHCR push lines
```

## 2. Build + export (connected host with bases)

```bash
cr login <your-sovereign-registry>      # podman/docker login, out-of-band
scripts/build_matrix.sh --build         # build all cells -> dist/kc-<os>-<ver>.tar (+ .sha256)
# matrix: {16.1.1,24.0.5,25.0.6,26.6.3} × {astra,redos}; KC16=JDK11/WildFly, rest=JDK21/Quarkus
```
Each cell builds FROM the configured base (or, with `USE_IMAGE_*`, pulls + retags a
branded image), saves to a tar, and writes a `.sha256`.

## 3. Transfer

Copy `dist/*.tar` + `dist/*.tar.sha256` (or the `*.tar.xz*` from the CI workflow) onto
offline media. **Verify on the air-gapped side before loading:**
```bash
sha256sum -c kc-astra-26.6.3.tar.sha256
```

## 4. Consume — maps to existing acquisition modes (no new runtime code)

The migration tool / harness already supports these via `scripts/lib/distribution_handler.sh`.

### a) Offline tar load (`acquisition=load`)
```bash
export PROFILE_KC_DISTRIBUTION_MODE=container
export PROFILE_CONTAINER_ACQUISITION=load
export PROFILE_CONTAINER_IMAGE_TAR=/media/kc-astra-26.6.3.tar
export PROFILE_CONTAINER_IMAGE_REF="ghcr.io/<owner>/<repo>:astra-{version}"
```
`dist_container` runs `cr load -i $PROFILE_CONTAINER_IMAGE_TAR` then verifies
`cr image inspect`. **The `PROFILE_CONTAINER_IMAGE_REF` here MUST match the tag baked at
build** (`ghcr.io/<owner>/<repo>:<os>-<version>`), or the post-load inspect fails.

### b) Pull from private GHCR (`acquisition=pull`)
```bash
cr login ghcr.io                        # out-of-band
export PROFILE_CONTAINER_ACQUISITION=pull
export PROFILE_CONTAINER_IMAGE_REF="ghcr.io/<owner>/<repo>:astra-{version}"
```

### c) Already loaded locally (`acquisition=preloaded`)
```bash
export PROFILE_CONTAINER_ACQUISITION=preloaded
```

> Tip: the same `config/images.conf` values feed the consume side — export `GHCR_IMAGE`
> as `PROFILE_CONTAINER_IMAGE_REF="<GHCR_IMAGE>:<os>-{version}"` so build, publish and
> runtime read one source of truth.

## 5. CI alternative (operator infra)

`/.github/workflows/build-images.yml` (`workflow_dispatch`, `runs-on: [self-hosted, sovereign]`)
runs steps 2–3 + publishes to **private** GHCR and attaches `*.tar.xz` + `.sha256` to a
**private** Release. Register a self-hosted runner labelled `sovereign` in your contour;
set GHCR package visibility to private in org settings.
