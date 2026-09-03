# Scaffolding-from-zero reference

Full detail behind `SKILL.md`'s Phase -1. Load this file when actually
generating a Dockerfile/compose set for a repo that has none (or an
incomplete one) — not for a quick sanity check. Everything here is either
verified directly against a running Docker Engine 29.7.2 / Compose v5.5.x /
Buildx v0.36–0.37 toolchain (2026-09-03), or cited against the tool's own
docs/source with a date. `[uncertain]` marks carry into the "Explicitly
unverified" table at the bottom rather than being asserted as fact.

## Package manager → install command, cache path, prod variant

The committed lockfile is the strongest, cheapest signal in the whole phase —
it alone picks the exact frozen install command and the correct cache-mount
target. Never ask what this table already answers.

| Lockfile / signal | Frozen install command | Cache mount target | Copy/bind before install | Prod-only variant |
|---|---|---|---|---|
| `package-lock.json` / `npm-shrinkwrap.json` | `npm ci --no-audit --no-fund` | `/root/.npm` | `package.json`, `package-lock.json`, `.npmrc` | `npm ci --omit=dev` or `npm prune --omit=dev` after build |
| `yarn.lock`, no `.yarnrc.yml` (Yarn 1.x) | `yarn install --frozen-lockfile` | `/usr/local/share/.cache/yarn` | `package.json`, `yarn.lock`, `.yarnrc` | `--production=true` |
| `yarn.lock` + `.yarnrc.yml` (Berry 2+) | `yarn install --immutable` (`--frozen-lockfile` does not exist in Berry) | project-local `.yarn/cache`; or `~/.yarn/berry/cache` with `enableGlobalCache: true` | `package.json`, `yarn.lock`, `.yarnrc.yml`, `.yarn/releases` | `yarn workspaces focus --production` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile`; or the two-layer form `pnpm fetch --frozen-lockfile` then `pnpm install --offline` | `/pnpm/store` when `PNPM_HOME=/pnpm` (official image); else `$(pnpm store path)`, Linux default `~/.local/share/pnpm/store` | `package.json` + `pnpm-lock.yaml` (`pnpm fetch` needs ONLY the lockfile — the best cache key in the Node ecosystem) | `pnpm install --prod --frozen-lockfile`, or `pnpm deploy --filter=<pkg> --prod` in a workspace |
| `bun.lock` (Bun 1.2+) or `bun.lockb` | `bun install --frozen-lockfile` | `/root/.bun/install/cache` (or `BUN_INSTALL_CACHE_DIR`) | `package.json`, `bun.lock(b)` | `bun install --frozen-lockfile --production` |
| `deno.lock` | `deno install --frozen` / `deno cache <entry>` | `$DENO_DIR` (default `/root/.cache/deno`) | `deno.json(c)`, `deno.lock` | n/a (no `node_modules`) |
| `uv.lock` | `uv sync --locked --no-install-project`, then `uv sync --locked` again after `COPY`ing source | `/root/.cache/uv` + `ENV UV_LINK_MODE=copy` | BIND-mount `uv.lock` and `pyproject.toml` (uv's own documented pattern — leaves no layer at all) | `uv sync --locked --no-dev` or `ENV UV_NO_DEV=1`; add `UV_COMPILE_BYTECODE=1` |
| `poetry.lock` | `poetry install --no-root --no-interaction` | `/root/.cache/pypoetry` | `pyproject.toml`, `poetry.lock` | `poetry install --only main --no-root`; `POETRY_VIRTUALENVS_CREATE=false`, or pin the venv to `/app/.venv` and `COPY` just that dir into the runtime stage |
| `pdm.lock` | `pdm install --check --prod --no-editable` | `/root/.cache/pdm` `[uncertain]` — confirm with `pdm config cache_dir` | `pyproject.toml`, `pdm.lock` | `--prod` |
| `Pipfile.lock` | `pipenv install --deploy --system` (`--deploy` fails if the lock is stale — that *is* the frozen flag) | `/root/.cache/pipenv` `[uncertain]` | `Pipfile`, `Pipfile.lock` | `--deploy --system` without `--dev` |
| `requirements.txt` | `pip install --no-deps -r requirements.txt` if fully pinned+hashed; else `pip install -r requirements.txt` | `/root/.cache/pip` | BIND-mount `requirements.txt` (Docker's own guide does this) | a separate `requirements-dev.txt` installs only in the dev stage |
| `pyproject.toml`, no lock | `pip install .` (Nixpacks' `PipSetuptools` default) | `/root/.cache/pip` | `pyproject.toml` (+ `src` for a real build) | `--no-deps` is unsafe here — flag the missing lock in the summary |
| `environment.yml` | `micromamba install -y -f environment.yml` | `/opt/conda/pkgs` | `environment.yml` | prune with `micromamba clean -a` |
| `go.sum`, no `vendor/` | `go mod download` (+ `go build` verifies `go.sum`) | `/go/pkg/mod` **and** `/root/.cache/go-build` — mounting only the first leaves most of the speedup on the table | `go.mod`, `go.sum` | none (static binary has no runtime deps) |
| `vendor/` present | `go build -mod=vendor` | `/root/.cache/go-build` only | the vendor tree | none |
| `Cargo.lock` | `cargo build --release --locked` | `/usr/local/cargo/registry` + `/usr/local/cargo/git` + `target/`, all with `sharing=locked` | `Cargo.toml`, `Cargo.lock` (+ `cargo-chef` `recipe.json` for a deps-only layer) | none (static binary) |
| `pom.xml` | `mvn -B -e -DskipTests dependency:go-offline` then `mvn -B -DskipTests package` | `/root/.m2/repository` with `sharing=locked` | `pom.xml` (every module `pom` in a reactor build) | `-Pprod`; ship a JRE or distroless/java, never the JDK |
| gradle wrapper + `build.gradle(.kts)` | `./gradlew --no-daemon build -x test` | `/root/.gradle/caches` + `/root/.gradle/wrapper` | `build.gradle(.kts)`, `settings.gradle`, `gradle/wrapper/*` | `-x test`, JRE runtime stage |
| `Gemfile.lock` | `bundle config set --local deployment true && bundle install` | `/usr/local/bundle` | `Gemfile`, `Gemfile.lock`, `*.gemspec` | `bundle config set --local without 'development test'` |
| `composer.lock` | `composer install --no-interaction --no-scripts --prefer-dist` | `/root/.composer/cache` (or `COMPOSER_CACHE_DIR`) | `composer.json`, `composer.lock` | `--no-dev --optimize-autoloader --classmap-authoritative` |
| `packages.lock.json` / `*.csproj` | `dotnet restore --locked-mode` | `/root/.nuget/packages` | the `csproj`/`sln` files only, then `COPY . .` | `dotnet publish -c Release --no-restore` |
| apt-based image | `apt-get update && apt-get install -y --no-install-recommends ...` | `/var/cache/apt` + `/var/lib/apt/lists`, both `sharing=locked`, after `rm -f /etc/apt/apt.conf.d/docker-clean` | n/a | build-only packages stay in the builder stage only |
| alpine image | `apk add --no-cache ...` | `/var/cache/apk` | n/a | see the musl warning below |

**Cross-cutting rules the same signal drives:**
- Namespace the cache mount per manager **and** per platform: `--mount=type=cache,id=npm-$TARGETPLATFORM,target=/root/.npm` (declare `ARG TARGETPLATFORM`). Without this, a multi-arch `buildx --platform linux/amd64,linux/arm64` build has two architectures writing native binaries into one cache directory.
- `sharing=locked` for cargo/apt/maven (no internal cross-process locking); the default `shared` is fine for npm/pip/go.
- A private-registry credential (`.npmrc` token, `composer` `auth.json`, a pip `--index-url` password, a NuGet PAT) never becomes a `COPY` or an `ARG`. It becomes `RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci`.
- The install command also fixes `.dockerignore`: whatever directory the manager writes into (`node_modules`, `.venv`, `target`, `vendor`, `.yarn/unplugged`, `__pycache__`) must be excluded from the build context.
- Docker's own Python guide now bases on `dhi.io/python:3.12-dev` / `dhi.io/python:3.12` (Docker Hardened Images, free/Apache-2.0 since 2025-12-17), which run **nonroot by default** — so the `/root/.cache/...` paths above shift to the nonroot user's home on those images. Verify with `docker run --rm <base> sh -c 'echo $HOME'` rather than hardcoding `/root`.

**Failure modes verified or corroborated in this pass:**
`npm install` (not `ci`) silently re-resolves and desyncs the image from the lockfile. `yarn install --frozen-lockfile` on a Berry repo simply doesn't exist as a flag. `COPY . .` before the install invalidates the layer on every source edit — the single most common cause of "Docker is slow." An unnamespaced cache mount in a multi-arch build corrupts or cross-writes native binaries between architectures. `ENV PIP_NO_CACHE_DIR=1` together with a pip cache mount cancels the mount out — Nixpacks sets that var precisely *because* it doesn't use cache mounts; don't copy that convention once a mount exists. Alpine + Python converts a 20-second wheel install into a multi-minute source build for most of the scientific/native-extension ecosystem (PyPI ships manylinux, not musl, wheels). Cache mounts do not survive CI (see the CI section below) — teams that discover this conclude "caching is broken" when it's working as designed.

`[uncertain]`: whether corepack remains bundled-by-default in the newest 2026 Node major — verify with `corepack --version` in the chosen base image rather than assuming; the safe fallback is `npm i -g pnpm@<pin>` or the `ghcr.io/pnpm/pnpm` image.

## Framework → artifact, runtime base, production command

Decides whether the image serves HTTP at all, the *production* command (never
the dev server), the artifact path, and the runtime base. Verified against
each framework's own deployment docs, 2026-09-03.

| Framework signal | Build artifact | Runtime base | Production command | Port | Gotcha the generator must handle |
|---|---|---|---|---|---|
| `next` dep + `output: 'standalone'` | `.next/standalone` + `.next/static` + `public` | `node:<pin>-slim` | `node server.js` | 3000 | Copy **all three** — `.next/standalone` to the workdir root, `.next/static` to `./.next/static`, `public` to `./public`. `mkdir .next && chown` so the prerender/image cache is writable. `ENV PORT` + `ENV HOSTNAME=0.0.0.0`. |
| `next` dep, no `output: 'standalone'` | `.next` + full `node_modules` | `node:<pin>-slim` | `next start` | 3000 | Either add `output: 'standalone'` (preferred, say so) or ship the full prod `node_modules`. `COPY .next/standalone` on a repo without it fails the build. |
| `next` dep + monorepo | as above | `node:<pin>-slim` | `node server.js` | 3000 | `outputFileTracingRoot: path.join(__dirname, '../../')` or the standalone bundle misses hoisted deps. |
| `vite` dep, SPA framework (react w/o remix/react-router-node, vue, svelte w/o kit, preact, lit, solid, qwik) | parsed `outDir`, default `dist` | `nginx:alpine` / Caddy / DHI static | nginx (foreground) or `caddy run` | 80 | nginx **must** have `try_files $uri $uri/ /index.html;` or every deep link 404s on refresh. `VITE_*` vars are baked at build time. |
| `react-scripts` (CRA) | `build/` | `nginx:alpine` | nginx | 80 | same `try_files` rule; `REACT_APP_*` baked at build time. |
| `angular.json` | `dist/<project>/browser` (v17+) | `nginx:alpine` | nginx | 80 | verify the exact dist path from the actual build output — it moved in v17. |
| `nuxt.config` | `.output/` | `node:<pin>-slim` | `node .output/server/index.mjs` | 3000 | Nitro; `NITRO_PORT`/`PORT` and `NITRO_HOST=0.0.0.0`. Only `.output` needs to ship. |
| `@sveltejs/adapter-node` | `build/` | `node:<pin>-slim` | `node build/index.js` (or `node build`) | 3000 | production `dependencies` are externalized and must be installed in the runtime stage; devDeps bundle in. |
| `astro.config` with node adapter | `dist/` | `node:<pin>-slim` | `node ./dist/server/entry.mjs` | 4321 | with `output: 'static'` this is a pure nginx/static image instead — read the config, don't assume. |
| `nest-cli.json` | `dist/` | `node:<pin>-slim` | `node dist/main.js` | 3000 | `main.ts` must call `app.listen(port, '0.0.0.0')`. |
| express/fastify/koa, no framework config | none (or `tsc` `dist/`) | `node:<pin>-slim` | `node <entry>` from `main`/`scripts.start` | from `.listen()`, default 3000 | must bind `0.0.0.0`, not `localhost`. |
| `manage.py` + django + `wsgi.py` | collected static in `STATIC_ROOT` | `python:<pin>-slim` | `gunicorn <proj>.wsgi:application --bind 0.0.0.0:8000 --workers <n>` | 8000 | `collectstatic --noinput` at **build** time; `migrate` is a separate one-shot service; never `manage.py runserver`; `ALLOWED_HOSTS`/`DEBUG=False` from env. |
| `manage.py` + django + `asgi.py` (channels/async) | as above | `python:<pin>-slim` | `gunicorn <proj>.asgi:application -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000` | 8000 | same as above, plus a redis channel layer if `django-channels` is present. |
| `fastapi` dep (+ fastapi-cli) | none | `python:<pin>-slim` / `dhi.io/python` | `fastapi run app/main.py --port 8000` in **exec form** | 8000 | exec form is required (shell form breaks lifespan/graceful shutdown, adds a 10s Compose shutdown delay — fastapi.tiangolo.com states this); `--proxy-headers` behind a proxy; `--workers N` only for single-host Compose, one process per container under an orchestrator; never `--reload`. |
| `fastapi` dep, no fastapi-cli | none | `python:<pin>-slim` | `uvicorn app.main:app --host 0.0.0.0 --port 8000` | 8000 | same rules. |
| `flask` dep | none | `python:<pin>-slim` | `gunicorn 'app:app' --bind 0.0.0.0:8000` | 8000 (retarget from 5000) | never `flask run`; `FLASK_DEBUG` must not be set in prod. |
| `celery` dep | none | **same image** as the web service | `celery -A <app> worker -l info` | none — do not publish a port | second compose service reusing the same image with a different `command:`; a broker (redis/rabbitmq) is mandatory or the worker crash-loops; `celery beat` is a third service if a beat schedule exists. |
| `torch`/`tensorflow` in deps | none | CUDA runtime image or CPU slim | the app command | app-dependent | multi-GB image; model weights belong in a volume or cache mount, never a layer; GPU needs `deploy.resources.reservations.devices` in compose. |
| `go.mod`, no cgo | static binary | `gcr.io/distroless/static-debian12` or `scratch` | the binary as `ENTRYPOINT` | from source | build `CGO_ENABLED=0 GOOS=linux -trimpath -ldflags="-s -w"`; `scratch` needs `ca-certificates` and `/etc/passwd` copied in for TLS or a non-root UID. |
| `go.mod` **with** cgo | dynamically linked binary | `distroless/base` or `debian:<pin>-slim` | the binary | from source | `CGO_ENABLED=1`; `scratch` is **forbidden** — fails at runtime with a misleading "no such file or directory" for the binary itself. |
| `Cargo.toml` | `target/release/<bin>` | `distroless/cc` (glibc) or `scratch` (musl target) | the binary | from source | openssl needs `pkg-config`+`libssl-dev` in the builder, or switch to `rustls`; use `cargo-chef` for a deps-only layer. |
| `spring-boot-starter-*` | `target/*.jar` | `eclipse-temurin:<pin>-jre` / `distroless/java` | `java -XX:MaxRAMPercentage=75 -jar app.jar`, ideally the extracted layered jar | 8080 | ship a JRE, never the JDK; extract the layered jar so dependency layers cache separately from application classes. |
| `Microsoft.NET.Sdk.Web` | `publish/` | `mcr.microsoft.com/dotnet/aspnet:<pin>` | `dotnet App.dll` | 8080 | .NET 8+ defaults to port 8080 **and** a non-root `app` user; `EXPOSE 80` is stale. Use `ASPNETCORE_HTTP_PORTS`. Reverting to 80 forfeits non-root. |
| `laravel/framework` | `vendor/` + built assets | `php:<pin>-fpm` + nginx | php-fpm with nginx docroot `public/` | 80 | two processes → two containers (or a supervisor); `artisan migrate`/`config:cache` are one-shots; `storage/` needs a writable volume. |
| `config.ru` + rails | precompiled assets | `ruby:<pin>-slim` | `bundle exec puma -C config/puma.rb` | 3000 | `assets:precompile` at build time with a dummy `SECRET_KEY_BASE`; never `rails server` in dev mode. |
| `index.html`, no server dep | the directory itself | `nginx:alpine` / Caddy / DHI static | serve the directory | 80 | still needs `try_files` if it's a SPA. |

**Dev-command counterpart** (for the `dev` stage only, never prod): Next
`next dev` · Vite `vite --host 0.0.0.0` · CRA `react-scripts start` · Nuxt
`nuxt dev` · Django `python manage.py runserver 0.0.0.0:8000` · FastAPI
`fastapi dev` or `uvicorn app.main:app --host 0.0.0.0 --reload` · Flask
`flask run --host 0.0.0.0 --debug` · Go `air` · Rust `cargo watch -x run` ·
Spring `mvn spring-boot:run` · .NET `dotnet watch`. Every one must bind
`0.0.0.0` — the framework default is usually `localhost`, and a container
bound to localhost is unreachable from the host.

**The defining failure of naive generators**: reading `package.json`'s
`scripts` and shipping whichever one was seen first as `CMD`. `vite preview`
is a preview tool, not a production server (no gzip/brotli tuning, no caching
headers). A SPA served without `try_files` works on the homepage and 404s on
every deep-link refresh — ships to production constantly. `CGO_ENABLED`
left at its default of 1 with a `scratch` runtime exits immediately with
"no such file or directory," which reads as "my binary is missing" and is
actually "the dynamic loader is missing." Running `collectstatic`,
`assets:precompile`, `prisma generate`, or `next build` in the entrypoint
instead of the builder stage repeats the work on every container start, in
parallel across every replica. `--workers 4` inside a Kubernetes deployment
that also runs 4 replicas multiplies to 16 processes and defeats the
orchestrator's own load balancing (FastAPI's docs call this out directly).

Framework output paths are the single most version-volatile fact in this
file — Angular moved to `dist/<project>/browser` in v17, Astro/Nuxt/SvelteKit
adapters change entry paths between majors. **Verify the artifact path by
running the build, don't trust the table blindly** for a framework's newest
major. `[uncertain]`: exact 2026-major artifact paths for Angular, Astro,
Nuxt, SvelteKit.

## Backing services from client libraries, and the master signal table

The single most transferable idea in this research, straight from `fly
launch`'s own scanner source (`scanner/django.go`/`python.go`, read directly
2026-09-03) and mirrored in Nixpacks' Rust provider (`is_using_postgres` in
`src/providers/python.rs` greps for `django.db.backends.postgresql` or a
`psycopg`/`psycopg2` dependency): **a backing service must trace back to a
specific import or dependency line, never to a guess.**

| Signal | Extra compose service |
|---|---|
| `psycopg`/`pg`/`django.db.backends.postgresql` | Postgres, plus a `migrate`/release one-shot |
| `redis`/`ioredis` | Redis |
| `celery`/`sidekiq`/`bull` | a **second** compose service reusing the same image with a different `command:`, plus a mandatory broker (a worker with no broker crash-loops on startup) |
| `alembic.ini` / `migrations/` / `prisma/migrations` / `db/migrate` | a one-shot `migrate` service or an entrypoint guard — **not** baked into `CMD` (N replicas would race the schema) |
| `prisma/schema.prisma` | `prisma generate` in the **build** stage; the `datasource db` provider verbatim; `binaryTargets` must match runtime libc (alpine/musl needs `linux-musl-openssl-3.0.x`) |
| Any of `pnpm-workspace.yaml`, `turbo.json`, `nx.json`, `go.work`, Cargo `[workspace]`, or >1 root manifest of different languages | monorepo — see the build-context section below |
| `.env.example` listing `DATABASE_URL`/`REDIS_URL`/`S3_ENDPOINT` | one compose service per URL scheme, same variable name wired through `environment:` |
| An existing Dockerfile/compose file | **stop generating** — switch to the brownfield reconciliation path |

**Negative mappings — signals that must NOT produce a decision**: a `test/`
directory does not add a service; a `.github/workflows` file does not
change the Dockerfile; a README mentioning Kubernetes does not make the
agent write Kubernetes manifests; devDependencies never appear in the
runtime stage. Inventing a service with no signal ("redis because it's a web
app") produces a stack nobody trusts; missing a signal that *is* there (no
broker for a detected Celery app) is the more common and more confusing
failure — it crash-loops with an opaque connection error instead of failing
at generation time.

**Other repo-scan mistakes verified worth calling out**: ranking language by
file-extension count instead of root manifest (a repo with a root `go.mod`
and 400 `.py` helper scripts is a Go service); reading a manifest nested
inside `node_modules/`, `.venv/`, `vendor/` or a test fixture as if it were
the project root (`find . -maxdepth 3 -name package.json -not -path
'*/node_modules/*'`); stopping at the language ("it's Python" produces `CMD
python app.py` when the repo actually needed gunicorn + `collectstatic` +
Postgres); treating `.env` as something to `COPY` — `.env.example` is the
contract, `.env` is a secret, and copying it bakes credentials into a layer
that `docker history` and provenance attestations expose forever.

## Compose merge semantics — the mechanism that separates dev from prod

**Compose merges mappings key-by-key and *concatenates* sequences.** This one
fact, imported wrong from Kustomize/Helm/JSON-merge-patch (where later
documents replace), is the root cause of nearly every dev→prod leak in this
whole phase. Verified against `docs.docker.com/reference/compose-file/merge/`,
2026-09.

**Attribute-by-attribute cheat sheet:**
- **Appended (sequences)**: `dns`, `dns_search`, `expose`, `external_links`, `cap_add`, `cap_drop`, `devices`, `env_file`, `extra_hosts` (list form), `links`, `security_opt`, `tmpfs`, `group_add`, `profiles`, `networks` (list form), `depends_on` (list form).
- **Merged by unique key**: `volumes`/`secrets`/`configs` by `target`; `ports` by `{ip, target, published, protocol}`.
- **Overridden wholesale (the only three)**: `command`, `entrypoint`, `healthcheck.test`.
- **Merged key-by-key, later wins**: `build` (and therefore `build.target`/`build.context`/`build.dockerfile`), `deploy`/`deploy.resources`, `labels` (map form), `logging`, `healthcheck` (every field but `test`), `depends_on` (map form), `networks` (map form), `environment` (map form).
- **Scalars, later wins**: `image`, `restart`, `user`, `working_dir`, `init`, `pull_policy`, `platform`, `container_name`.
- `environment` as a **list** of `KEY=value` strings: behavior is ambiguous across sources — sequence-append vs. normalization to a mapping `[uncertain]`. **Decision: always emit `environment` as a mapping**, which removes the ambiguity entirely.

**Consequences that must be encoded as rules, not left to intuition:**
- Changing only the **host** port in a later file does **not** replace the mapping: `"8080:80"` then `"9090:80"` differ in `published`, so both get published. Needs `!override`.
- Changing the **volume at the same container path** *does* replace: base `foo:/work` + override `bar:/work` yields only `bar:/work` — so swapping a dev bind mount for a prod named volume at the identical `target` works with no tag. **The leak happens specifically when production declares nothing at that target.**
- Appending an argument to `command` is impossible — the whole command must be restated.

**Preferred fix — restructure, no tags needed**: put anything dev-shaped
(`volumes: ["./:/app"]`, a published DB port, `environment: {DEBUG: "1"}`)
in `compose.override.yaml` only, never the base. `build.target` is a scalar
inside a mapping, so it overwrites cleanly either direction — it's one of
the few things safe to set in either file.

**When a tag is unavoidable** (can't restructure a file you don't own, e.g.
a vendored base): drop an inherited list entirely with `volumes: !reset []`
/ `ports: !reset []`; drop one scalar/env key with `environment: {DEBUG:
!reset null}`; replace a list wholesale with `ports: !override
["127.0.0.1:8080:8080"]` (requires Compose ≥ 2.24.4). **`!reset`/`!override`
are non-standard YAML tags** — plain YAML parsers reject them, so pre-commit
`check-yaml`, Testcontainers' `ComposeContainer`, `podman-compose`, Dockge,
and IDE/Compose-LSP schema validators can all break the moment one is
introduced (docker/compose issues referenced across #11816, #11706,
#12162). Prefer restructuring; reach for the tags only when you don't own
the base file.

**Verified failure modes**: a database `ports: ["5432:5432"]` "for
convenience" in the base cannot be removed by any later file without
`!reset` — direct internet exposure on a naive deploy. A bare `!reset` (no
value) can fail schema validation; write `!reset null`/`!reset []`. Using
`!override` on Compose < 2.24.4 is an unrecognized-tag parse failure, at
deploy time, on the server. `!reset` on environment keys contributed by 3+
files is known not to work reliably (docker/compose#11816); `extends` +
YAML anchors silently ignore `!override`/`!reset` entirely
(docker/compose#11706); tags don't always survive `docker compose config`
(docker/compose#12162), so a rendered file can't always be reused as a
source. Duplicate keys within one file are silently overwritten with no
warning (docker/compose#5267). An anonymous volume for `node_modules`
(`volumes: ["./:/app", "/app/node_modules"]`) is correct in dev but persists
stale dependencies across a lockfile change until `docker compose down -v`
— and if it ever reaches the production render, it shadows the image's own
`node_modules` with an empty volume.

**Verification is the only source of truth — render, don't assert:**
```bash
docker compose config > /tmp/render-dev.yaml
docker compose -f compose.yaml -f compose.prod.yaml config > /tmp/render-prod.yaml
diff /tmp/render-dev.yaml /tmp/render-prod.yaml    # the diff IS the dev/prod separation

P="-f compose.yaml -f compose.prod.yaml"
# no bind mounts survive
docker compose $P config --format json | jq -e \
  '[.services[].volumes // [] | .[] | select(.type=="bind")] | length == 0'
# every published port with its bind address
docker compose $P config --format json | jq -r \
  '.services|to_entries[]|select(.value.ports)|.key as $s|.value.ports[]|"\($s) \(.host_ip // "0.0.0.0"):\(.published)->\(.target)"'
# no duplicate target port on a service (the append symptom)
docker compose $P config --format json | jq -r \
  '.services|to_entries[]|.key as $s|(.value.ports // []|group_by(.target)[]|select(length>1)|"DUPLICATE \($s) target \(.[0].target)")'
# no dev build target, no debug env leaking
docker compose $P config --format json | jq -r '.services|to_entries[]|"\(.key) target=\(.value.build.target // "n/a")"'
docker compose $P config | grep -Ein 'DEBUG|NODE_ENV: *development|FLASK_ENV: *development|LOG_LEVEL: *debug'
```

## Compose Watch — full failure-mode list

Compose Watch is only reachable for a service that has `build:` and lives in
the repo (a no-op for `image:`-only services like postgres/redis). Route by
signal: an in-process reloader (nodemon, `vite`, `uvicorn --reload`, `dotnet
watch`, `air`, `cargo-watch`) gets `action: sync` on the source dir; a
compiled language with no watcher binary gets `action: rebuild`; **any**
lockfile/manifest gets its own `action: rebuild` rule — this is what makes
`sync` safe, because dependency changes always go through a real build; a
config file read only at process start (`nginx.conf`, `redis.conf`,
`prometheus.yml`) gets `sync+restart`; a post-sync step (`prisma generate`,
i18n compile, `alembic upgrade`) gets `sync+exec` (Compose ≥ 2.32, else fall
back to `sync+restart`).

**Verified failure modes, ranked by how often they actually bite:**
1. **Overlap with a bind mount is the top failure.** A watch path also
   covered by `volumes:` is warned about and then **skipped entirely** —
   emitting both "for safety" gets neither mechanism working, with only a
   stderr line (`also declared by a bind mount volume, this path won't be
   monitored!`) as evidence. Choose one; propose a diff, never stack both.
2. **`node_modules` shadowing — two distinct bugs, one symptom.** With a
   bind mount, the host's `node_modules` (or its absence) masks the
   container's, so native modules compiled for the host libc/arch (bcrypt,
   sharp, esbuild, better-sqlite3, psycopg2) fail at require time. With
   watch, forgetting `ignore: [node_modules/]` pushes those same host
   modules **into** the container. Bind-mount fix: an anonymous/named
   volume at `/app/node_modules`. Watch fix: an ignore rule. Same trap for
   `.venv`, `vendor/`, `target/`, `__pycache__`, `.next`.
3. **No initial sync** (Compose < 2.29.2): watch propagated only
   post-startup events, so a container started from a stale image kept
   stale code (docker/compose#11102). Symptom: "the edit I made before
   starting watch isn't there."
4. **Inotify does not fire.** Compose Watch itself watches on the **host**
   so it's largely immune, but the watcher **inside** the container
   (nodemon, vite, webpack, `uvicorn --reload`) is not. On WSL2, edits made
   by Windows tools to files under `/mnt/c` raise no inotify events for
   Linux processes (microsoft/WSL#4739), and Docker Desktop deliberately
   does not forward inotify across the WSL2 bind-mount boundary for
   performance (docker/for-win#12898). Same on CIFS/SMB, NFS, and often
   macOS virtiofs/gRPC-FUSE. Mitigation order: move the repo into the WSL2
   ext4 filesystem (real fix) → prefer Compose Watch `sync` over a bind
   mount (sidesteps it — the daemon writes into the container's own
   filesystem) → force polling (`CHOKIDAR_USEPOLLING=1`,
   `WATCHPACK_POLLING=true`, `WATCHFILES_FORCE_POLLING=1`, `nodemon -L`),
   accepting the CPU cost.
5. **Missing binaries**: watch needs `stat`, `mkdir`, `rmdir` in the image —
   `scratch` and distroless final stages fail outright.
6. Non-root `USER` without `COPY --chown` leaves the sync target owned by
   root; every sync fails with a permission error.
7. A `rebuild` rule on a broad path (or a directory the build itself writes
   into) loops forever — rebuild rules belong on manifests/lockfiles, never
   the source tree.
8. A dev `command:` sitting in the **base** file is not ignored in
   production the way `develop:` is — this asymmetry is easy to miss.

**Detect the WSL/CIFS trap before choosing sync vs. bind mount**:
`readlink -f .` (a `/mnt/c/...` prefix means Windows-side edits raise no
inotify) and `findmnt -no FSTYPE .` (`cifs`, `9p`, `drvfs`, `nfs` all imply
polling is required).

**Prove sync actually works** rather than trusting the config: `touch
src/<file>` on the host, then `docker compose exec <svc> stat -c '%y %U %n'
/app/src/<file>` — mtime must advance and the owner must be the runtime
user. Prove the image is self-contained (not watch-dependent): `docker
compose build <svc> && docker run --rm <image> ls /app/src` must list the
source without any sync having run.

**Version floors**: alpha in Compose 2.17 (`x-develop`, ~Apr 2023); GA in
2.22.0 (Sept 2023) as top-level `develop:` + `docker compose watch`.
Per-attribute: `sync`/`rebuild` → 2.22.0; `sync+restart` → 2.23.0; `--prune`
flag → 2.29.0; `initial_sync` → 2.29.2; `restart` and `sync+exec` actions →
2.32.0. `[uncertain]`: exact minimum Compose version for the `include:`
attribute inside `develop:` (the allowlist counterpart of `ignore:`).

## Structure: multi-stage, `--target`, and when compose exists at all

**Stage order** (last `FROM` is always what a bare `docker build .`
produces — production is always last): `base` → `deps` (full install, dev
tooling included) → `dev` (FROM `deps`; watcher command; the *only* stage
that may contain nodemon/watchfiles/air/cargo-watch) → `build`
(compile/bundle) → `prod` (FROM a minimal runtime; only the artifact +
production deps; non-root; the real server command). A repo with no compile
step and no dev-only tooling (a plain script service) needs only two stages
(`base` → `prod`) — don't invent a dev stage nobody will target. A `tests/`
dir + a test runner + CI gets a `test` stage that branches off `dev` and is
built explicitly with `--target test` in CI — BuildKit only builds a
target's dependency graph, so a `test` stage no target depends on **never
runs** during `docker build --target prod`; "the tests ran during the
build" is false unless CI explicitly builds `--target test`.

**Which compose files to create at all** (this decision precedes profiles
and dev/prod split):
- A `k8s/`/Helm/`fly.toml`/`render.yaml`/ECS/Terraform manifest is present →
  Compose is **dev-only**. Create `compose.yaml` + `compose.override.yaml`.
  Do **not** create a prod compose file — the production artifact is the
  image, and its runtime config lives in the platform manifests. Generating
  a `compose.prod.yaml` here is dead configuration that will eventually be
  deployed by mistake.
- A deploy script runs `docker compose up -d` on a host, or
  Traefik/Watchtower/`restart: always` is present → Compose **is**
  production. Create `compose.yaml` (prod-safe base) + `compose.override.yaml`
  (dev) + `compose.prod.yaml` (restart policy, resource limits, logging,
  secrets, replicas).
- No deployment signal, single app, no CI → `compose.yaml` only, dev-friendly
  inline. Don't invent a three-file layout for a two-container toy.
- An existing `docker-compose.yml` (old naming) → keep the
  `docker-compose*.yml` family; renaming to `compose.yaml` breaks every
  script/README that references the old name.

**Which file gets which setting** (derived directly from the merge
constraint above — "add yes, remove no"): source bind mount, `develop.watch`,
published app port, `DEBUG=1`/`LOG_LEVEL=debug`, `build.target: dev` → always
the override/dev file, never the base. Published database/cache ports
(`5432:5432`, `6379:6379`) → dev override only; base uses `expose:` so the
port is reachable only on the Compose network. `restart`,
`deploy.resources.limits`, `logging`, `replicas`, prod `secrets` → prod file
only. Service names, `image`/`build`, `depends_on` + `condition:
service_healthy`, `healthcheck`, named volumes, networks → base file,
identical everywhere.

**Profiles are for presence, not shape.** Reach for a profile only when a
service must be **absent** in some environment — override files cannot
delete a service. adminer/pgadmin/mailpit/minio/localstack/jaeger →
`profiles: ["tools"]`; a migration/seed script → `profiles: ["migrate"]` (or
no profile, invoked with `docker compose run --rm migrate`, which
auto-enables its own profile); an e2e/playwright/cypress runner →
`profiles: ["test"]`. **Reject `profiles: ["prod"]`/`profiles: ["dev"]`
outright** — modeling environments as profiles means every command needs the
right flag, and `docker compose down` without it orphans containers.

**Invocation discipline**: more than two `-f` files, or the same chain
repeated in Makefile + CI + README → set `COMPOSE_FILE=compose.yaml:compose.prod.yaml`
(`:` separator on Linux/macOS, `;` on Windows) so there's exactly one source
of truth. A production host's deploy command must be **explicit**
(`-f compose.yaml -f compose.prod.yaml up -d`) or driven by `COMPOSE_FILE` —
a bare `docker compose up -d` there silently picks up any
`compose.override.yaml` that got shipped, which is the single most damaging
failure mode in this whole section: dev bind mounts, `DEBUG=1`, and a
database published on `0.0.0.0`, on a production host, with `up` reporting
success the entire time.

**Verified failure modes beyond the merge/profile ones already covered**:
`build: {target: dev}` left in the *base* `compose.yaml` (not the override)
builds the dev stage in production, invisible until someone reads `docker
compose config`. The same image tag used for both `target: dev` and `target:
prod` builds means the second `docker compose build` silently replaces the
first in the local store — "prod is running the dev image" with a
clean-looking Compose file. An `ARG ENV=prod` conditional mega-stage
(`RUN if [ "$ENV" = dev ]; ...`) breaks layer caching, produces an image
whose contents can't be determined from its tag, and reliably leaks dev
tooling when the ARG defaults wrong. `USER` carries across a `FROM base`
chain but **not** across a fresh `FROM <upstream-image>` — a prod stage
starting straight from the raw upstream image resets to root even if an
earlier stage was non-root.

**Verification**: enumerate stages and confirm production is last
(`awk 'toupper($1)=="FROM"{last=$0} END{print last}' Dockerfile`); confirm
which stage each environment actually builds
(`docker compose config --format json | jq -r '.services|to_entries[]|"\(.key): target=\(.value.build.target // "<none>")"'`
against both the dev and prod `-f` chains); build both and compare
(`docker image ls app --format '{{.Tag}}\t{{.Size}}'`); prove the prod image
has no dev deps/toolchain
(`docker run --rm app:prod sh -c 'command -v gcc npm pip apt-get'` — should
be empty); a full round-trip on a `profiles: ["tools"]` service
(`docker compose --profile tools up -d && docker compose --profile tools
down --remove-orphans && docker compose ps -a` — nothing left behind).

**Version floors**: multi-stage + `--target` — Docker Engine 17.05+ (2017).
`build.target` — every Compose v2 release. `profiles` — docker-compose
1.28.0 (Jan 2021). `include:` — Compose v2.20.0 (2023-07-11). Recommended
floor to assume when generating: **Docker Engine 24+ / Compose v2.24+**
unless the repo pins otherwise. `[uncertain]`: exact precedence order when
both `compose.yaml` and `docker-compose.yml` exist; exact minimum Compose
for `--profile "*"` (believed ~2.29).

## Healthcheck and startup ordering

| Signal detected | Decision | Note |
|---|---|---|
| Base is `python:*-slim`/`node:*-slim` (Debian) | curl is **not** installed | Preferred no-install Python probe: `test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status==200 else 1)"]` |
| Base is `*-alpine` | `wget` is present (busybox), curl is not | `test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8000/health"]` |
| Base is `node:*` (any variant) | no extra binary needed | `test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]` (Node 18+ has global fetch) |
| distroless / DHI runtime / `scratch` | no shell, no curl, no wget — the probe **must** be a self-contained binary in exec form | COPY a tiny static probe (`grpc_health_probe`, a 2MB Go httpget) from the builder stage, or add a `--health-check` subcommand to the app binary and `test: ["CMD", "/app", "healthcheck"]`, or omit the container `HEALTHCHECK` and probe externally |
| gRPC-only service | `grpc_health_probe -addr=:50051`, COPYed as a static binary | implement the standard gRPC Health Checking Protocol server-side first |
| `postgres:*` | `test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]`, `start_period: 30s` | must pass `-U` and `-d` — a bare `pg_isready` goes green against the *temporary* init server and the app then hits "the database system is starting up" |
| `redis:*` | `test: ["CMD", "redis-cli", "ping"]` | add `-a $${REDIS_PASSWORD}` if set, else `NOAUTH` |
| `mysql:*`/`mariadb:*` | `test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-p$${MYSQL_ROOT_PASSWORD}"]` | same temporary-init-server trap as postgres |
| `mongo:*` | `test: ["CMD","mongosh","--quiet","--eval","db.adminCommand('ping')"]` | `mongo` was renamed `mongosh` in Mongo 6+ |
| `rabbitmq:*` | `test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]` | `check_port_connectivity` for a stricter probe |
| repo has `alembic/`/`prisma/migrations/`/`db/migrate/`/`manage.py migrate` | a one-shot `migrate` service; `migrate.depends_on.db.condition: service_healthy`; `app.depends_on.migrate.condition: service_completed_successfully` | the only correct use of `service_completed_successfully`, and the ordering most naive generators omit entirely |
| no `/health` route anywhere in the source | do **not** invent one silently — either a non-lying TCP probe (`test: ["CMD","sh","-c","</dev/tcp/127.0.0.1/8000"]`) or **no** healthcheck on the app service | a probe against a route that doesn't exist is permanently unhealthy and hangs `--wait` — worse than none |
| an existing `wait-for-it.sh`/`dockerize`/`sleep` in the entrypoint | replace with `depends_on: condition: service_healthy`, propose deleting the script | the script duplicates native Compose behavior and hides failures |
| CI workflow with `sleep N` before tests | replace with `docker compose up --wait --wait-timeout 120` | the direct payoff of this whole item |

**Timing**: fast services (redis, nginx, a Go binary) —
`interval: 10s, timeout: 3s, retries: 3, start_period: 5s`. JVM/Rails/Django
with migrations, or anything loading an ML model —
`start_period: 60s`–`120s`, `start_interval: 2s`, `interval: 30s, timeout:
10s, retries: 3`. Never leave the Dockerfile defaults
(`--interval=30s --timeout=30s --retries=3 --start-period=0s`) for a
CI-facing stack — up to ~2 minutes before an unhealthy verdict, and a
slow-starting app fails its first real probes.

**Verified failure modes**: `HEALTHCHECK CMD curl -f http://localhost:8000/health`
on `python:3.13-slim` or `node:22-alpine` — curl is in **neither** — exits
127, the container never leaves `starting`, and the failure surfaces as
Compose's opaque `dependency failed to start: container X is unhealthy`,
naming the wrong problem; this is the single most common failure and it's
caused by copying a healthcheck from a tutorial written for a fat base
image. Short-form `depends_on: [db]` waits only for the container to be
*created*, not for postgres to accept connections — the classic
"connection refused on first run, works on retry" bug. `$POSTGRES_USER` in
a Compose `healthcheck.test` is interpolated by **Compose on the host**
(usually to empty) before the container sees it — must be `$$POSTGRES_USER`
to reach the container's shell. **`docker compose up --wait --exit-code-from
X` is invalid** — verified: `--wait cannot be combined with
--abort-on-container-exit, --attach or --attach-dependencies`; widely
recommended online, never works. The two forms that do:
`up --wait <deps>` then `run --rm <tests>`, or
`up --exit-code-from <svc> --abort-on-container-exit` alone. Unhealthy does
**not** trigger a restart for plain Docker/Compose — `restart:
unless-stopped` reacts to process *exit*, not health state; an
unhealthy-but-running container sits unhealthy forever. Exit code 2 is
reserved by Docker for a probe — only 0/1 are meaningful; a probe like
`curl -f ... || exit 0` that always returns 0 defeats the entire mechanism.

**Version floors**: Dockerfile `HEALTHCHECK` — Docker 1.12. `--start-interval`
— Engine 25.0+, Compose `start_interval` key needs Compose 2.20.2+.
`depends_on` long form with `condition:` was removed in Compose v3 and
restored in the Compose Specification/v2 — works in every currently
supported version. `docker compose up --wait` — Compose v2.1.1;
`--wait-timeout` added later. `condition: service_healthy` is **not**
honored by Swarm-mode `docker stack deploy` and is not the same thing as a
Kubernetes readiness probe.

## Monorepo build-context ladder, and CI cache/testcontainers

**The build-context decision ladder** (each rung only when the previous
doesn't fit): a single root lockfile with `workspace:*` deps between
packages → context **must** be the repo root (never `context: ./apps/<svc>`
— a per-package context can't see the root lockfile and silently installs a
different dependency tree than local dev); `build: {context: ., dockerfile:
apps/api/Dockerfile}` — `context` resolves relative to the Compose project
directory, `dockerfile` resolves relative to the **context**. More than one
Dockerfile sharing a context → per-service `apps/api/Dockerfile.dockerignore`
(BuildKit prefers `<dockerfile-path>.dockerignore` over the root file).
`turbo.json` + `pnpm-workspace.yaml` + >2 deployables → a `pruner` stage
(`RUN turbo prune <pkg> --docker`) splitting `out/json` (dependency identity)
from `out/full` (source) — this split is the whole point: source edits never
re-run install. 2–3 services with no shared internal code → **stop at
Compose**, one `build:` block each; introducing Bake here is
over-engineering. ≥3 images, a shared base stage, multi-platform, or CI
building all of them → `docker-bake.hcl` with a `target "_common"` +
per-service `inherits = ["_common"]` + a `group "default"`.

**A shared directory a service's build needs but that sits outside its
context**: `additional_contexts: {proto: ../../proto}` — narrower than
widening `context` to the whole tree. **Several independent sub-stacks**
(per team/domain, each with its own compose file): root `compose.yaml` with
`include: [- path: services/billing/compose.yaml]` — each included file
loads as its own project with its own project directory, so relative paths
resolve against the *included* file. **Never** `-f a.yml -f b.yml` across
directories for this — relative paths resolve against the *first* file's
directory, silently pointing builds at the wrong place; `include:` exists
specifically to fix this.

**Verified `turbo prune --docker` bugs, still active**: phantom
npm-internal packages injected into `bun.lock`, breaking `--frozen-lockfile`
(turborepo#12262); unknown pnpm lockfile `settings` keys silently dropped,
e.g. `dedupePeers` (#12442); `patches/` placed in `out/full/` not
`out/json/`, breaking a `pnpm install` in the json stage when
`patchedDependencies` is configured (#4289). It also respects `.gitignore`
by default, so gitignored-but-required files silently vanish, and does
**not** copy `globalDependencies` files unless a future flag is on.

**`additional_contexts: {base: "service:base"}` does not reliably create a
build-time ordering dependency in Compose** (docker/compose#12783) — Bake's
`contexts = { base = "target:base" }` form does. Use Bake when ordering
across images actually matters.

**2026 fact that reframes this whole section**: Docker Compose **v5.0.0**
(2025-12-02) removed the internal BuildKit client entirely — every `docker
compose build` now delegates to Bake. The `COMPOSE_BAKE=1` opt-in from
Compose 2.33.0 is obsolete; Bake **is** the Compose builder now, making Bake
semantics (deduplicated context transfer, named contexts, cache flags) the
default reality for monorepo Compose builds, not an opt-in extra.

**CI build cache** — SIGNAL → DECISION:

| Signal | Decision |
|---|---|
| CI builds exactly 1 image | `cache-from: type=gha` + `cache-to: type=gha,mode=max` — still set `scope=<image>` explicitly so a second image added later can't collide |
| CI builds N images (matrix/monorepo) | `scope` **must** be unique per image — the default scope is the literal string `buildkit`, so unscoped N-image builds are permanently, silently cold |
| Triggers on `pull_request` | `cache-from` **only** — no `cache-to`. The GH cache is branch-scoped (reads from base + default branch); exporting from a PR poisons and evicts what everyone else reads |
| Triggers on push to default branch | `cache-from` + `cache-to: type=gha,mode=max,scope=<image>` — this is the job that fills the cache every PR reads |
| Multi-stage Dockerfile | `mode=max` is mandatory — the default `mode=min` exports only the final stage, exactly the cheap part |
| >5 images or >10GB total layers | switch to `type=registry,ref=<repo>:buildcache,mode=max` — the 10GB/LRU GH cap causes eviction thrash that presents as "sometimes fast, sometimes slow" |
| `RUN --mount=type=cache` present | state plainly that `type=gha` does **not** preserve cache mounts (docker/build-push-action#1011) — options are accepting it, `reproducible-containers/buildkit-cache-dance`, or a persistent/registry cache |

**Testcontainers vs. Compose** — a `testcontainers` dependency already
exists → use it, don't duplicate the same DB/broker as a Compose service
(double-provisioning, port fights). A `compose.yaml` already defines the
same deps used in dev → reuse it (directly, or via `ComposeContainer`) —
don't author a third description of Postgres. Cross-service/e2e/browser
tests needing the whole stack → Compose `up -d --wait --wait-timeout N` +
`run --rm tests` + `down -v`. A test config pointing at a shared/staging
database → hard stop, refuse, and say why — this is the one case where the
agent should reject the existing design outright.

**Verified failure modes**: `mode=min` (the default) on a multi-stage build
rebuilds the heavy builder stage every run (docker/build-push-action#829 is
exactly this). `docker compose up -d` immediately followed by tests →
connection refused, and the subtler variant: `--wait` with the DB service
having **no** `healthcheck:` returns instantly, proving nothing.
`--exit-code-from` has documented cases of not propagating
(docker/compose#11712/#5894) — assert the exit code explicitly rather than
trusting it. No `down -v` → volumes persist on self-hosted runners,
migrations "already applied," seeded data accumulates, tests pass locally
and fail in CI for reasons nobody can reproduce. `TESTCONTAINERS_RYUK_DISABLED=true`
to dodge a socket-permission error leaks containers that fill the runner
disk and, on shared runners, break other jobs.

**Version floors — hard one**: the GH Actions cache **v1 service shut down
2025-04-15**; only cache API v2 works. Minimums that speak v2: Buildx
v0.21.0, BuildKit v0.20.0, Compose v2.33.1, Docker Engine v28.0.0 — anything
older fails with "This legacy service is shutting down." GH cache quota:
10GB/repo free (raisable on paid plans since 2025-11-20), LRU-evicted,
7-day expiry, readable only from the current branch + its base + the
default branch.

**Verification**: `docker buildx build --progress=plain --cache-from
type=gha,scope=api -t x . 2>&1 | grep -c CACHED` across two runs to prove
the cache actually hits; `gh cache list --limit 100` to inspect scope keys
and size against the cap; a deliberately-failing test
(`run --rm tests sh -c 'exit 7'`) to confirm the pipeline actually goes red
end to end, not just green by accident.

## Brownfield: the full reconciliation algorithm

`docker init`'s brownfield policy — a single destructive "overwrite
everything, unrecoverable" prompt — is the explicit anti-model. Gordon's is
only marginally better (files are shown before writing, with no stated
preserve/extend/replace rule). The algorithm below synthesizes Dev
Containers' "reference and layer, never rewrite" pattern with Nixpacks'
"explicit artifact always wins":

**R1 — detect before generating, always.** The first action is an inventory
(`git ls-files` for `Dockerfile*`/`compose*`/`docker-bake*`/`.dockerignore`/
`devcontainer.json`). Anything found disables the greenfield path entirely.

**R2 — never overwrite, never delete, never truncate.** If a rewrite is
unavoidable, write to a new path (`Dockerfile.new`) and print `diff -u`.
This is the one hard prohibition in the whole section.

**R3 — `git status --porcelain` before any write.** Uncommitted or untracked
artifacts have no recovery path — back them up and say so
(`cp -n Dockerfile Dockerfile.bak`).

**R4 — establish load-bearing status.** Grep CI and deployment manifests for
the file path, the image name, and any `target:`
(`grep -rn 'Dockerfile\|compose\|bake\|target:' .github/workflows
.gitlab-ci.yml Jenkinsfile`; `grep -rn '<image-name>' k8s helm charts *.tf
fly.toml render.yaml`). Load-bearing artifacts get a proposal, never a
silent edit.

**R5 — validate with tools, not opinions.** Run `docker build --check`,
`docker compose config -q`, `docker buildx bake --print`, and hadolint if
available, and **quote the output** as the justification for every proposed
hunk. No finding, no change.

**R6 — classify explicitly**, and act per class:
- **Correct** (matches inferred signals, modern syntax, multi-stage,
  non-root, pinned) → leave it, say so. Doing nothing is a valid — often the
  best — outcome, and "the file looks bad" is not a mandate to regenerate.
- **Incomplete** (right idea, missing `.dockerignore`/healthcheck/non-root/
  cache mounts) → propose additive edits.
- **Outdated** (obsolete `version:` key, `MAINTAINER`, unpinned `FROM
  node:latest`, a dev server in `CMD`, a secret via `ARG`) → propose a diff,
  one rationale line per hunk, citing the specific rule.
- **Wrong-shape** (single stage shipping a full SDK, or the Dockerfile
  builds a different framework than what's actually in the repo) → propose
  a replacement, keep the original as `Dockerfile.bak`, require explicit
  confirmation before overwriting.

**R7 — prefer additive files.** `.dockerignore`, `compose.override.yml`, a
new Bake target that `inherits`, a new CI check step — these cannot change
the produced image and need no approval.

**R8 — one concern per hunk, one rationale per hunk.** Never bundle a
base-image bump with a reformat. Never reformat at all — key ordering,
quoting style, and dropped YAML anchors make the actual change invisible in
the diff, and it gets reverted wholesale (taking the real fix with it).

**R9 — flag breaking changes explicitly.** Appending a stage changes the
default build target (a bare `docker build .` always builds the *last*
stage — a silent wrong-artifact ship, not a loud failure); renaming a stage
breaks `target:` references in CI; changing the build context invalidates
every `COPY`; changing `ENTRYPOINT`/`EXPOSE`/`USER` changes the deployment
contract. Any of these needs approval and a paired CI/manifest edit.

**R10 — don't modernize cosmetics as the headline.** Removing an obsolete
`version: '3.8'` key is safe but trivial — it's informative only, ignored by
Compose v2+, a vintage signal and nothing more. An EOL base image is the
real finding; rank by security and correctness, not lint noise.

**R11 — don't merge separate contracts.** `devcontainer.json` stays a dev
container config, not app-image hardening. A `docker-bake.hcl` and a
compose file that disagree get a divergence report, not a silent
unification.

**R12 — at most one question**, and only when an artifact is load-bearing
or the classification is ambiguous. Offer: leave alone + additive
(Recommended) / in-place diff / write alongside / replace with backup.
Default to "leave alone + additive" on no answer.

**R13 — prove the result.** After any change, rebuild both versions and
diff the `docker inspect` contract (user, ports, entrypoint, cmd, workdir)
plus `docker compose config --format json`. Equal, or intentionally and
visibly different — nothing else is acceptable.

**Verified anti-patterns worth naming directly**: bundling unrelated
changes into one commit (base bump + `version:` removal + reformat +
healthcheck) makes the whole thing unreviewable, so it gets reverted and
even the security fix is lost. Deleting a line that looked redundant —
`libpq-dev`, `build-essential` a native module needs, `platform:
linux/amd64` needed on Apple Silicon, a `ulimit`, a CA cert import — breaks
the build for a reason invisible from the diff. Editing a compose file that
is a **live deployment** (no git remote, `restart: always`, real secrets in
a sibling `.env`) — detect this and refuse to edit in place. Running a
generator "inside the repo to see what it would produce" and accepting its
overwrite prompt — sample any generator in a temp directory and diff
instead.

**Verification sequence**:
```bash
# 0. safety before any write
git status --porcelain
git ls-files --error-unmatch Dockerfile >/dev/null 2>&1 && echo TRACKED || echo UNTRACKED_NO_SAFETY_NET
cp -n Dockerfile Dockerfile.bak 2>/dev/null || true

# 1. inventory + vintage
git ls-files | grep -Ei 'dockerfile|containerfile|compose.*\.ya?ml|docker-bake|\.dockerignore|devcontainer'

# 2. ownership: is it load-bearing?
grep -rn 'Dockerfile\|compose\|bake\|target:' .github/workflows .gitlab-ci.yml Jenkinsfile 2>/dev/null

# 3. validate what exists (non-mutating)
docker build --check .
docker compose config -q && echo COMPOSE_OK

# 4. drift vs repo reality
grep -nE '^FROM' Dockerfile
cat .nvmrc .python-version .tool-versions 2>/dev/null

# 5. after proposing: prove the contract did not change
diff -u Dockerfile Dockerfile.new
for t in before after; do docker inspect brownfield:$t \
  --format '{{.Config.User}}|{{json .Config.ExposedPorts}}|{{json .Config.Entrypoint}}|{{json .Config.Cmd}}|{{.Config.WorkingDir}}'; done
```
Pass criteria: nothing was written while the tree was dirty; the audit
output exists and is quoted in the proposal; `--check` and `compose config
-q` are clean **after** the change and no worse than before; the `inspect`
contract line is identical unless the change was explicitly requested;
stage names are unchanged.

## The static validation loop, in full

The ordered loop — each step is fast, mutates nothing, and has a meaningful
exit code. Stop and fix on first non-zero.

```bash
# 0. preconditions — never ask the user this, detect it
docker info >/dev/null 2>&1 || { echo 'no docker daemon: files are UNVERIFIED'; exit 0; }

# 1. compose schema, interpolation, cross-references (fast, no build work)
docker compose -f compose.yaml config --quiet
docker compose -f compose.yaml -f compose.override.yml config --quiet
docker compose -f compose.yaml -f compose.prod.yml    config --quiet

# 2. Dockerfile lint per service, resolving context/target/args as Compose will
docker compose build --check          # exit 1 on any violation; prints absolute path + line
#    ...or with no compose file, per target — checks are TARGET-SCOPED:
docker build --call=targets .
docker build --check --target dev  .
docker build --check --target prod .

# 3. optional third layer: shell-body analysis BuildKit does not do
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile
```

**Verified falsifications of widely-repeated claims** (tested on Docker
29.7.2/buildx 0.36.1, 2026-09-03):
- **`--check=skip=RuleName` does not exist.** `--check` is a boolean flag;
  that form fails with a `ParseBool` error, exit 125. The only correct forms
  are `docker build --check --build-arg BUILDKIT_DOCKERFILE_CHECK=skip=<rules>`
  or the in-file `# check=skip=...` directive.
- **`--check` does not need `error=true` to fail** — it exits 1 on plain
  warnings already.
- **`SecretsUsedInArgOrEnv` has a verified blind spot for a *global* `ARG`**
  declared before the first `FROM`: `ARG AWS_SECRET_ACCESS_KEY=hunter2`
  before any stage produced "no warnings found," exit 0, while the identical
  `ARG`/`ENV` *inside* a stage fired correctly. **A green check is not proof
  no secret is baked in.**
- **`docker compose config` silently swallows a missing variable.** An
  undefined `${DB_URL}` becomes `DB: ""` with only a warning and exit 0 —
  the most dangerous default in the whole loop, because it makes an
  under-specified compose file look validated. Author required vars as
  `${DB_URL:?DB_URL is required}` so `config` fails loudly instead.
- **`docker compose config` does not validate the filesystem or the
  build.** A nonexistent `build.context` passes with exit 0; a `build.target`
  naming a stage that doesn't exist also passes `config --quiet` with exit
  0, while `docker compose build --check` correctly fails with `error:
  target stage "production" could not be found`, exit 1. Treating `config`
  as a build-wiring validator is a real antipattern.
- **The target-scoping trap** — `--check --target dev` returned exit 0 on a
  Dockerfile whose `prod` stage had a hardcoded secret and a shell-form
  `CMD`. **Checking one target proves nothing about the others** —
  enumerate stages first with `docker build --call=targets .` and check
  every one that will actually be built.
- **hadolint's BuildKit-syntax support is partial, and the gap is
  dangerous.** Verified on v2.15.1: `RUN --mount=type=cache,...`,
  `COPY --link`, and `# syntax=` all parse cleanly. But a heredoc followed
  by another instruction, or a registry ref containing a port
  (`FROM localhost:5000/app:tag`), cause a hard `DL1000` parse failure —
  and hadolint then evaluates **zero** rules while `--no-fail` still exits
  0. An unattended agent must detect `DL1000` explicitly (parse the JSON
  output and check for that code) rather than trusting the exit status —
  see the three-state guard below.
- `-t none` is the **lowest** severity threshold (fails on everything), not
  "never fail" — `--no-fail` is the non-blocking switch. `-f codeclimate`/
  `-f codacy` **always** exit 0 regardless of findings.
- The `hadolint/hadolint` image has no `ENTRYPOINT`, only
  `CMD ["/bin/hadolint", "-"]` — passing any flag requires repeating the
  binary name (`docker run --rm -i hadolint/hadolint hadolint --no-color -`),
  or Docker tries to exec the flag itself and fails with exit 127.

**The three-state hadolint guard** (never trust the exit code alone):
```bash
docker run --rm -i hadolint/hadolint:v2.15.1 hadolint --no-fail -f json - < Dockerfile \
 | python3 -c 'import json,sys; d=json.load(sys.stdin); \
   sys.exit(2 if any(x["code"]=="DL1000" for x in d) else (1 if d else 0))'
# exit 2 = hadolint could not parse the file -> fall back to docker build --check alone,
#          do NOT report it as clean.
```

**Durable enforcement**, for a Dockerfile the agent authored clean:
```dockerfile
# syntax=docker/dockerfile:1
# check=error=true
```

**Only after the static loop is green**, prove it actually builds and runs
— static validation is a syntax-and-configuration gate, never a functional
one, and reporting "validated" after `--check` alone overclaims:
```bash
docker compose build
docker compose up -d --wait --wait-timeout 120
docker compose ps --format '{{.Service}} {{.State}} {{.Health}}'
docker compose down -v
```

**Version floors**: `docker build --check` — Buildx ≥ 0.15.0, Dockerfile
syntax ≥ 1.8, GA 2024-07-29 (Docker Desktop 4.33). `docker compose build
--check` — verified working in Compose v5.5.0; `[uncertain]` on the exact
minimum version — feature-detect with `docker compose build --help | grep
-q -- --check` rather than assuming. hadolint v2.15.1 verified 2026-09-03,
GPL-3.0, third-party — never make it a hard prerequisite; run it
containerized or skip it.

## Version floors — consolidated

| Feature | Floor | Source/status |
|---|---|---|
| BuildKit as default builder | Docker Engine 23.0 (Feb 2023) | current |
| `RUN --mount=type=cache/bind/secret` | Dockerfile frontend 1.2+, stable | current |
| `docker build --check` | Buildx 0.15.0+, Dockerfile syntax 1.8+ | GA 2024-07-29, Docker Desktop 4.33 |
| `docker init` | Docker Desktop 4.27 (Jan 2024) | Desktop-only, not on Engine; 8 templates, still single-service as of 2026-09 |
| `profiles` | docker-compose 1.28.0 (Jan 2021) | current |
| `include:` | Compose v2.20.0 (2023-07-11) | current |
| `develop.watch` GA | Compose v2.22.0 (Docker Desktop 4.24, Sept 2023) | `sync+restart` → 2.23.0; `initial_sync` → 2.29.2; `restart`/`sync+exec` → 2.32.0 |
| `!override` custom YAML tag | Compose v2.24.4 (Feb 2024) | stated explicitly in the Compose Specification |
| `!reset` custom YAML tag | present by Compose v2.20 (compliance bug filed against 2.17.3, June 2023) | `[uncertain]` exact introducing version |
| `--start-interval` on HEALTHCHECK | Docker Engine 25.0+; Compose `start_interval` needs 2.20.2+ | current |
| Docker Bake GA | Docker Desktop 4.38 (2025-02-05) | previously experimental for years |
| Compose delegates `build` to Bake internally | Compose v5.0.0 (2025-12-02) — removed the internal BuildKit client | `COMPOSE_BAKE=1` opt-in from 2.33.0 is now obsolete |
| GHA cache service v2 required | Buildx 0.21.0, BuildKit 0.20.0, Compose 2.33.1, Engine 28.0.0 | v1 shut down 2025-04-15 |
| Docker Hardened Images free/Apache-2.0 | 2025-12-17 | `docker login dhi.io` still required even for the free catalog — verified: anonymous pull returns `unauthorized` |
| `docker compose build --check` | verified working, Compose v5.5.0 | `[uncertain]` exact introducing version |
| Latest verified toolchain (2026-09-03) | Docker Engine 29.7.x, Buildx v0.37.0, BuildKit v0.33.0, Compose v5.5.1, docker/build-push-action v7.3.0, docker/bake-action v7.3.0, docker/setup-buildx-action v4.3.0 | — |

**Recommended floor to assume when generating, absent a repo-specific pin**:
Docker Engine 24+ / Compose v2.24+. Everything above that line is current
and safe to emit by default; anything below needs feature-detection
(`docker compose build --help | grep -q -- --check`) rather than an
assumption.

## Explicitly unverified — this file's own honesty table

Carried forward rather than silently asserted, in addition to the entries
already in `SKILL.md`'s table:

| Claim | Status (as of 2026-09-03) |
|---|---|
| `environment:` written as a list of `KEY=value` strings — whether Compose merge appends the list or normalizes to a mapping first | Sources disagree; sidestepped entirely by always emitting `environment` in mapping form |
| Exact Compose version introducing `!reset` | Present by v2.20 (a compliance bug was filed against 2.17.3 in June 2023); exact introducing release not confirmed against changelogs |
| Exact Compose version introducing `--profile "*"` | Believed ~2.29; not independently confirmed |
| `pdm`/`pipenv` default cache directory paths | Not confirmed against each tool's own docs in this pass — verify with `pdm config cache_dir` / by inspection before hard-coding |
| Exact 2026-major artifact paths for Angular, Astro, Nuxt, SvelteKit | These move between majors; verify by running the build rather than trusting the framework table |
| Whether `--target` drift (a renamed stage an old CI job still references) fails loudly or silently falls back | Most tooling errors rather than silently falling back, but not exhaustively verified across every CI action |
| `docker compose build --check` exact minimum Compose version | Verified working on v5.5.0; earlier floor not confirmed — feature-detect rather than assume |
