# Руководство по миграции Keycloak (container-hop)

Пошаговая, copy-paste инструкция, по которой вы **сами** прогоните и проверите миграцию Keycloak
двумя путями. Все команды, флаги, env-переменные и номера версий в этом документе сверены с
исходным кодом репозитория (ссылки `file:line` — в разделе [Источники](#источники)). Ничего не
выдумано: если какой-то путь имеет ограничение — оно описано честно.

## Что делает инструмент

Это **container-hop** мигратор: вместо «чистого SQL» он **загружает реальный контейнер Keycloak**
каждой промежуточной версии против вашей PostgreSQL. На старте Keycloak прогоняет **оба** слоя
миграции, и инструмент проверяет каждый:

| Слой | Что это | Где хранится | Как проверяется |
|---|---|---|---|
| **L1** | Liquibase changeset'ы (схема БД) | таблица `DATABASECHANGELOG` | лог `... update ... executed successfully` |
| **L2** | RealmMigration / модель | таблица `MIGRATION_MODEL` | `SELECT version FROM MIGRATION_MODEL ...` |

> L2 (RealmMigration) выполняется **только при старте сервера** — поэтому экспорт/импорт SQL его
> пропускает, и нужен реальный запуск контейнера каждого хопа (ADR-001, ADR-005).

## Два пути миграции

| Путь | Target major | Цепочка хопов | Кол-во хопов | По умолчанию |
|---|---|---|---|---|
| **Path A** | 25 | `16.x → 25.0.6` | 1 | — (25 помечен EOL: warn-but-allow) |
| **Path B** | 26 | `16.x → 24.0.5 → 26.6.3` | 2 | ✅ дефолт |

Источник цепочек — `MIGRATION_HOPS=([26]="24.0.5 26.6.3" [25]="25.0.6")`. Стартовая 16.x **не
перезагружается** — это точка отсчёта; загружаются только перечисленные хопы. Версии `26.6.0` и
`26.6.1` **запрещены** (баги миграции `#48438` / `#47908`), `26.6.3` — последняя GA с фиксом.

---

## Оглавление

- [0. Предпосылки](#0-предпосылки)
  - [0.1. Проверка хоста](#01-проверка-хоста)
  - [0.2. Безопасность: работаем на клоне](#02-безопасность-работаем-на-клоне)
  - [0.3. Откуда взять образы (3 способа)](#03-откуда-взять-образы-3-способа)
- [1. Быстрый безопасный прогон через HARNESS («попробовать»)](#1-быстрый-безопасный-прогон-через-harness-попробовать)
- [2. Реальная миграция своего Keycloak 16](#2-реальная-миграция-своего-keycloak-16)
- [3. Верификация после каждого хопа](#3-верификация-после-каждого-хопа)
- [4. Troubleshooting](#4-troubleshooting)
- [5. Rollback / безопасность](#5-rollback--безопасность)
- [Чеклист: что должно получиться](#чеклист-что-должно-получиться)
- [Справочник терминов](#справочник-терминов)
- [Источники](#источники)

---

## 0. Предпосылки

### 0.1. Проверка хоста

```bash
cd /opt/kk_migration

# Контейнерный движок и psql на хосте
docker --version          # на этом хосте: 28.5.2
psql --version            # на этом хосте: 18.4

# ВАЖНО: на этом хосте стоят И podman, И docker. Автодетект выберет podman первым.
# Чтобы инструмент использовал docker — экспортируйте это в КАЖДОЙ сессии:
export CONTAINER_RUNTIME=docker
```

Порядок выбора движка: `CONTAINER_RUNTIME` → `PROFILE_CONTAINER_RUNTIME` (из профиля) → `podman` →
`docker`. То есть `export CONTAINER_RUNTIME=docker` перекрывает всё.

**PostgreSQL ≥ 14 ОБЯЗАТЕЛЬНА для Path B (target 26)** — Keycloak 26.6 убрал поддержку PG13.
Инструмент жёстко блокирует миграцию на 26, если major-версия PG < 14 (`MIN_PG_FOR_26=14`). Для
Path A (target 25) это ограничение не применяется.

```bash
# Проверьте major-версию вашей PostgreSQL
psql -h <pg-host> -U <pg-user> -d keycloak -tAc "SHOW server_version;"
```

### 0.2. Безопасность: работаем на клоне

> ⚠️ **Миграция необратима в рамках одного прогона.** Liquibase (L1) и RealmMigration (L2)
> **изменяют вашу БД** при старте каждого хопа. Откат — только восстановление из бэкапа.

Перед реальной миграцией (раздел 2) выберите одно:
- прогон на **клоне** вашей PostgreSQL (рекомендуется — нулевой риск для прода), **или**
- наличие свежего бэкапа / PITR-точки и плана восстановления (раздел 5).

```bash
# Пример: снять дамп исходной БД KC16 (на клон или для бэкапа)
PGPASSWORD='<pg-pass>' pg_dump -h <pg-host> -U <pg-user> -Fc keycloak > kc16_before_migration.dump
```

### 0.3. Откуда взять образы (3 способа)

Готовые «суверенные» образы Keycloak (Astra SE / RED OS) собраны для 4 версий
`{16.1.1, 24.0.5, 25.0.6, 26.6.3}` × 2 ОС `{astra, redos}`. Схема тегов:
`ghcr.io/alexgromer/keycloak-migration:<os>-<version>` (имя GHCR-неймспейса всегда в нижнем
регистре). Выберите один из трёх способов.

#### Способ 1 — Pull из приватного GHCR (есть сеть + доступ)

```bash
docker login ghcr.io                    # логин out-of-band (PAT с read:packages)

# Path B (target 26) — нужны обе версии цепочки
docker pull ghcr.io/alexgromer/keycloak-migration:astra-24.0.5
docker pull ghcr.io/alexgromer/keycloak-migration:astra-26.6.3
# Path A (target 25)
docker pull ghcr.io/alexgromer/keycloak-migration:astra-25.0.6
# (для RED OS замените astra- на redos-)
```

#### Способ 2 — Air-gap: загрузка из бандлов в `dist/`

В репозитории уже лежат бандлы (≈1.8 ГБ каждый). **Важно:** бандл — это `tar.xz` **с четырьмя
image-тарболлами внутри**, а не один `docker save`. Поэтому `docker load -i <bundle>.tar.xz`
напрямую **не сработает** — сначала распаковываем, потом грузим каждый образ.

```bash
cd /opt/kk_migration/dist

# 1) Проверить целостность
sha256sum -c kc-astra-bundle.tar.xz.sha256        # (и kc-redos-bundle.tar.xz.sha256)

# 2) Распаковать бандл -> 4 файла kc-astra-<version>.tar
mkdir -p /var/tmp/kc-images
tar -xJf kc-astra-bundle.tar.xz -C /var/tmp/kc-images
ls /var/tmp/kc-images
#   kc-astra-16.1.1.tar  kc-astra-24.0.5.tar  kc-astra-25.0.6.tar  kc-astra-26.6.3.tar

# 3) Загрузить нужные образы (каждый восстановит свой тег ghcr.io/...:astra-<version>)
docker load -i /var/tmp/kc-images/kc-astra-24.0.5.tar
docker load -i /var/tmp/kc-images/kc-astra-26.6.3.tar
# (Path A: kc-astra-25.0.6.tar)
```

#### Способ 3 — Локальная сборка из лицензионных баз

Требует ваши **лицензионные** базовые образы (Astra SE `ubi17`/`ubi18`, RED OS `ubi8`) — они
оператор-supplied и в репозиторий не коммитятся.

```bash
cd /opt/kk_migration
cp config/images.conf.example config/images.conf   # config/images.conf в .gitignore
# отредактируйте config/images.conf:
#   ASTRA_BASE / ASTRA_BASE_KC16 / REDOS_BASE / REDOS_BASE_KC16  — базовые образы
#   GHCR_IMAGE  — куда публиковать (по умолчанию ghcr.io/AlexGromer/keycloak-migration)
#   ASTRA_JDK=17  (Astra ubi18 несёт openjdk-17, НЕ 21!), REDOS_JDK=21, JDK_KC16=11

scripts/build_matrix.sh                # dry-run: печатает план 8 ячеек, не собирает
scripts/build_matrix.sh --build        # сборка -> dist/kc-<os>-<version>.tar (+ .sha256)
scripts/build_matrix.sh --build --publish   # + push в приватный GHCR
```

---

## 1. Быстрый безопасный прогон через HARNESS («попробовать»)

**Harness** (`scripts/harness/run_migration_harness.sh`) — это испытательный стенд. Он поднимает
**свежую одноразовую PostgreSQL**, грузит базовый KC16, засевает **случайные** realm'ы/users/clients
через kcadm, гоняет всю цепочку хопов и после каждого хопа проверяет L1 + L2 + целостность данных.
Это лучший способ «попробовать», ничего не трогая в проде.

> Поведение harness по умолчанию — **dry-run**: печатает каждую команду (секреты замаскированы как
> `***`) и **не мутирует ничего**. Живой прогон включается флагом `--go`.

### 1.1. Dry-run для Path B (target 26, дефолт)

```bash
cd /opt/kk_migration
export CONTAINER_RUNTIME=docker
scripts/harness/run_migration_harness.sh --dry-run
```

В выводе ищите шапку плана и цепочку:

```
   mode          : DRY-RUN
   start version : 16.1.1
   target major  : 26
   hop chain     : 16.1.1 -> 24.0.5 -> 26.6.3
   seed          : 3 realms x (50 users + 10 clients)
```

Далее идут строки `DRY-RUN: ...` для каждого шага (создание сети, запуск PG, boot KC16, seed, и для
каждого хопа — build → run → L1 → L2 → integrity → stop). Ни одна из них не выполняется.

### 1.2. Dry-run для Path A (target 25)

Target major переключается **env-переменной `TARGET_MAJOR`** (CLI-флага `--target-major` нет):

```bash
cd /opt/kk_migration
export CONTAINER_RUNTIME=docker
TARGET_MAJOR=25 scripts/harness/run_migration_harness.sh --dry-run
# hop chain : 16.1.1 -> 25.0.6
```

### 1.3. Живой прогон harness (`--go`)

> ⚠️ Honest note: harness в режиме `--go` **всегда собирает** хоп-образы из суверенной базы
> (`acquisition=build`) — он **не** использует готовые pull/load образы. Поэтому для `--go` нужна
> **лицензионная база** через `--os-base-image`. Если лицензионной базы нет — ограничьтесь dry-run
> (раздел 1.1/1.2), а живую миграцию делайте на готовых образах через раздел 2.

Живой прогон поднимает свежую тестовую PG и требует два секрета в окружении:

```bash
cd /opt/kk_migration
export CONTAINER_RUNTIME=docker
export HARNESS_DB_PASSWORD='<пароль-для-тестовой-PG>'
export HARNESS_KC_ADMIN_PASSWORD='<пароль-admin-для-сидинга>'

# Path B (target 26)
scripts/harness/run_migration_harness.sh --go \
  --os-base-image <ваша-лицензионная-база-astra-или-redos> \
  --realms 3 --users 50 --clients 10

# Path A (target 25)
TARGET_MAJOR=25 scripts/harness/run_migration_harness.sh --go \
  --os-base-image <ваша-лицензионная-база>
```

Полезные флаги harness (всё проверено по коду):

| Флаг | Назначение |
|---|---|
| `--dry-run` / `--go` | план (дефолт) / живой прогон |
| `--profile <name>` | профиль (дефолт `test-harness-sovereign`) |
| `--os-base-image <ref>` | суверенная база, из которой строятся хопы |
| `--image-ref <tpl>` | шаблон тега образа (с `{version}`) |
| `--final-ref <ref>` | переопределить образ ТОЛЬКО последнего хопа |
| `--preset astra\|redos` | пресет-плейсхолдер базы |
| `--pg-image <img>` | образ тестовой PG (дефолт `postgres:16`) |
| `--realms N` `--users N` `--clients N` | объём случайного сидинга (дефолт 3 / 50 / 10) |

Как читать вывод `--go` (см. раздел 3 — те же проверки):
- `[OK]` от `wait_for_migration` → L1 (Liquibase) прошёл;
- `MIGRATION_MODEL confirms version '...'` → L2 прошёл;
- `[OK] integrity: realm N == baseline N` / `user_entity ...` / `client N >= baseline N` → данные целы.

---

## 2. Реальная миграция своего Keycloak 16

Здесь мигрируется **ваша существующая БД** через `scripts/migrate_keycloak_v3.sh migrate --profile`.
В отличие от harness, сидинга нет — данные уже в БД, нужен только **пароль БД** (admin-пароль не
требуется).

### 2.1. Как инструмент находит образы (важно — прочитайте до создания профиля)

Полный ref образа инструмент строит так:
`<registry>/<image>:<version>` (из YAML-ключей `registry:` и `image:`), напр.
`ghcr.io/alexgromer/keycloak-migration:26.6.3`.

> **Подводный камень (проверено по коду).** Тег вида `<os>-<version>` (`astra-26.6.3`) задаётся
> только через `PROFILE_CONTAINER_IMAGE_REF`, но плоский YAML-парсер инструмента **не умеет хранить
> значения с `:`**, а `migrate` при загрузке профиля **затирает** эту env-переменную. Поэтому для
> реальной миграции используется надёжная схема: **получить образы → перетегировать в
> `<registry>/<image>:<version>` → `acquisition: preloaded`.** (Стенд-harness — единственный, кто
> работает с `<os>-`-тегами, т.к. ставит ref после загрузки профиля и всегда `build`.)

Переименуйте уже полученные (раздел 0.3) образы в версионную схему:

```bash
export CONTAINER_RUNTIME=docker
NS=ghcr.io/alexgromer/keycloak-migration      # ваш registry/image (можно любой локальный)

# Path B (target 26)
docker tag $NS:astra-24.0.5 $NS:24.0.5
docker tag $NS:astra-26.6.3 $NS:26.6.3
# Path A (target 25)
docker tag $NS:astra-25.0.6 $NS:25.0.6

docker images | grep keycloak-migration       # убедитесь, что есть теги :24.0.5 / :26.6.3 (или :25.0.6)
```

### 2.2. Создать профиль `profiles/<name>.yaml`

Профиль должен быть **run + container** (по образцу `test-harness-sovereign.yaml`), а **не**
standalone-download. Создайте файл (Path B — target 26):

```yaml
# profiles/kc-prod-26.yaml — реальная миграция KC16 -> 26.6.3 (Path B)
profile:
  name: kc-prod-26
  environment: run

database:
  type: postgresql
  location: standalone
  host: <pg-host>            # хост/IP вашей PostgreSQL (или ИМЯ контейнера PG при bridge-сети)
  port: 5432
  name: keycloak
  user: keycloak
  credentials_source: env    # косметика: пароль всё равно берётся из env PROFILE_DB_PASSWORD

keycloak:
  deployment_mode: run         # транзитный контейнер-мигратор на каждый хоп
  distribution_mode: container
  cluster_mode: standalone

  current_version: 16.1.1
  target_version: 26.6.3       # <-- Path B. Для Path A поставьте 25.0.6
  run_container_name: kc-migrate

  registry: ghcr.io/alexgromer       # <registry> для <registry>/<image>:<version>
  image: keycloak-migration          # <image>
  container:
    runtime: docker
    acquisition: preloaded           # образы уже загружены и перетегированы (раздел 2.1)

migration:
  strategy: inplace
  parallel_jobs: 1
  timeout_per_version: 900
  run_smoke_tests: false
  backup_before_step: true           # дамп БД перед каждым хопом (раздел 5)
```

Для **Path A** скопируйте файл как `profiles/kc-prod-25.yaml` и поставьте `target_version: 25.0.6`.

### 2.3. Задать секреты и сетевые env

```bash
cd /opt/kk_migration
export CONTAINER_RUNTIME=docker
export PROFILE_DB_PASSWORD='<пароль-вашей-PostgreSQL>'   # единственный обязательный секрет

# Если PostgreSQL запущена В КОНТЕЙНЕРЕ на bridge-сети:
#   - в профиле host: = ИМЯ контейнера PG
#   - и укажите сеть (по умолчанию контейнер-мигратор стартует с --network=host):
# export PROFILE_KC_RUN_NETWORK=<docker-network>
```

> При `--network=host` (по умолчанию) контейнер делит сеть с хостом, поэтому `host: localhost` в
> профиле достанет PG на хосте. Для PG-в-контейнере используйте bridge-сеть + имя контейнера.

### 2.4. Сухой прогон (план — ничего не мутирует)

```bash
# Показать план миграции
scripts/migrate_keycloak_v3.sh plan --profile kc-prod-26

# Полный dry-run (печатает реальные cr-команды, но не выполняет их)
scripts/migrate_keycloak_v3.sh migrate --profile kc-prod-26 --dry-run
```

В dry-run вы увидите строку запуска контейнера-мигратора (пароль замаскирован):

```
DRY-RUN: cr run -d --name kc-migrate-24.0.5 --network=host -e KC_DB=postgres \
  -e KC_DB_URL=jdbc:postgresql://<host>:5432/keycloak -e KC_DB_USERNAME=keycloak \
  -e KC_DB_PASSWORD=*** ghcr.io/alexgromer/keycloak-migration:24.0.5 start --optimized
```

### 2.5. Живая миграция

```bash
# Path B (target 26): 16.1.1 -> 24.0.5 -> 26.6.3
scripts/migrate_keycloak_v3.sh migrate --profile kc-prod-26
```

> `migrate` спрашивает **интерактивное подтверждение `[y/N]`** перед мутацией — введите `y`.
> Флага `--yes` нет (есть только `--force` у `rollback`).

```bash
# Path A (target 25): 16.1.1 -> 25.0.6
scripts/migrate_keycloak_v3.sh migrate --profile kc-prod-25
# (эквивалентно: target можно задать через env, если target_version в профиле не указан)
# TARGET_MAJOR=25 scripts/migrate_keycloak_v3.sh migrate --profile kc-prod-25
```

Target major берётся из `target_version` профиля (`26.6.3` → major 26 → цепочка `24.0.5 26.6.3`;
`25.0.6` → major 25 → цепочка `25.0.6`). Если `target_version` пуст — инструмент использует env
`TARGET_MAJOR` или дефолт `26`, либо спросит интерактивно.

### Path A vs Path B — что меняется

| Параметр | Path A (target 25) | Path B (target 26) |
|---|---|---|
| `target_version` в профиле | `25.0.6` | `26.6.3` |
| Цепочка хопов | `16.x → 25.0.6` | `16.x → 24.0.5 → 26.6.3` |
| Кол-во загружаемых контейнеров | 1 | 2 |
| Переименовать/загрузить образы | `:25.0.6` | `:24.0.5` и `:26.6.3` |
| PG ≥ 14 | не требуется | **обязательно** |
| Статус мажора | EOL (warn-but-allow) | поддерживаемый, дефолт |
| Итог `MIGRATION_MODEL` (major.minor) | `25.0` | `26.6` |

Полный набор флагов `migrate_keycloak_v3.sh` (проверено по парсеру аргументов):

| Флаг | Действие |
|---|---|
| `--profile <name>` | имя профиля из `profiles/` (без `.yaml`) |
| `--dry-run` | показать, но не выполнять |
| `--skip-tests` | пропустить smoke-тесты после хопа |
| `--skip-preflight` | пропустить preflight-проверки |
| `--airgap` | режим без сети (`AIRGAP_MODE=true`) |
| `--auto-rollback` | авто-откат при сбое хопа |
| `--monitor` | живой монитор миграции (если доступен) |

Команды: `plan` | `migrate` | `rollback` (у `rollback` есть `--force`). `--target-major`,
`--yes`, `--profile-name` — **не существуют**.

---

## 3. Верификация после каждого хопа

Инструмент проверяет всё сам (и падает fail-closed, если L2 не подтвердился), но вот как убедиться
вручную. Подставьте версию хопа: для Path B это `24.0.5`, затем `26.6.3`; для Path A — `25.0.6`.

### L1 — Liquibase (схема БД)

```bash
# В логах контейнера-мигратора
docker logs kc-migrate-<version> 2>&1 | grep -iE "update.*executed successfully"

# Либо рост числа применённых changeset'ов
PGPASSWORD="$PROFILE_DB_PASSWORD" psql -h <pg-host> -U keycloak -d keycloak \
  -tAc "SELECT COUNT(*) FROM databasechangelog;"
```

### L2 — RealmMigration (модель) — это авторитетный критерий успеха

```bash
PGPASSWORD="$PROFILE_DB_PASSWORD" psql -h <pg-host> -U keycloak -d keycloak \
  -tAc "SELECT version FROM MIGRATION_MODEL ORDER BY update_time DESC LIMIT 1;"
```

Ожидаемая `major.minor`: `24.0` после хопа на 24.0.5, `25.0` (Path A) или `26.6` (Path B) в финале.
Инструмент сравнивает именно `major.minor` сохранённого значения с ожидаемым.

### Целостность данных

```bash
PGPASSWORD="$PROFILE_DB_PASSWORD" psql -h <pg-host> -U keycloak -d keycloak -tAc \
  "SELECT (SELECT COUNT(*) FROM realm)        AS realms,
          (SELECT COUNT(*) FROM user_entity)  AS users,
          (SELECT COUNT(*) FROM client)       AS clients;"
```

Правило целостности (как в harness):
- `realm` — **равно** исходному (потери realm'ов недопустимы);
- `user_entity` — **равно** исходному (потери пользователей недопустимы);
- `client` — **≥** исходного (миграции версий **добавляют** служебные клиенты — это норма).

---

## 4. Troubleshooting

| Симптом / ошибка | Причина | Решение |
|---|---|---|
| `forbidden`/отказ на `26.6.0` или `26.6.1` | запрещённые патчи (баги `#48438` / `#47908`) | используйте `26.6.3` (цепочка Path B уже это делает) |
| Блок миграции на target 26 | PG major < 14 (`MIN_PG_FOR_26=14`) | обновите PostgreSQL до ≥ 14, либо мигрируйте сначала на Path A (25) |
| Команды идут через podman, а нужен docker | оба движка стоят, podman выбирается первым | `export CONTAINER_RUNTIME=docker` в текущей сессии |
| `image not present locally` при `preloaded` | образ не загружен или тег не совпал с `<registry>/<image>:<version>` | перетегируйте (раздел 2.1); проверьте `docker images` |
| `docker load` падает на `*.tar.xz` бандле | бандл = tar из 4 image-тарболлов, не single save | сначала `tar -xJf`, затем `docker load -i` каждого (раздел 0.3, способ 2) |
| Нет места в `/var` или `/tmp` | образы крупные (~0.7–1 ГБ), диск тесный | чистите неиспользуемые образы (`docker image prune`), распаковывайте в `/var/tmp` |
| GHCR pull → `denied`/`unauthorized` | приватный GHCR, нет логина | `docker login ghcr.io` (PAT c `read:packages`) |
| KC16 не стартует на суверенной базе | sovereign datasource собран корректно, но **runtime непроверен** | этот прогон и есть проверка; как стартовый KC16 для теста допустим fallback `quay.io/keycloak/keycloak:16.1.1` (его использует harness) |
| Коммиты/подпись | в репозитории включена GPG-подпись коммитов | подписывайте коммиты (`git commit -S`) |
| Не удаляется ветка | удаление веток заблокировано HITL-гейтом | выполните удаление сами через `!` (см. раздел 5) |

---

## 5. Rollback / безопасность

- **Бэкап перед каждым хопом:** `backup_before_step: true` в профиле → инструмент снимает дамп БД
  (`backup_before_<version>_<timestamp>.dump` в `migration_workspace/`) перед мутацией.
- **Авто-откат:** запускайте с `--auto-rollback` — при сбое хопа инструмент попытается откатиться к
  последнему бэкапу.
- **Ручной откат:** `scripts/migrate_keycloak_v3.sh rollback` (при необходимости `--force`).
- **Работайте на клоне** (раздел 0.2) — самый надёжный «откат» для прода: исходная БД не тронута.
- **Возобновление:** инструмент пишет checkpoint'ы; повторный `migrate --profile <name>` продолжит с
  последнего успешного шага.
- **Восстановление из дампа** (если делали `pg_dump -Fc`):

  ```bash
  PGPASSWORD='<pg-pass>' pg_restore -h <pg-host> -U <pg-user> -d keycloak --clean kc16_before_migration.dump
  ```

- **Удаление веток** в этой среде заблокировано HITL-гейтом — выполняйте сами:

  ```text
  ! git -C /opt/kk_migration branch -d <branch>
  ! git -C /opt/kk_migration push origin --delete <branch>
  ```

---

## Чеклист: что должно получиться

- [ ] `MIGRATION_MODEL.version` (major.minor) = **`25.0`** (Path A, полная строка `25.0.6`) или
      **`26.6`** (Path B, полная строка `26.6.3`).
- [ ] `databasechangelog` пополнился changeset'ами (L1 прошёл на каждом хопе).
- [ ] `COUNT(realm)` и `COUNT(user_entity)` **равны** домиграционным значениям.
- [ ] `COUNT(client)` **≥** домиграционного значения.
- [ ] Для Path B оба хопа (`24.0.5`, затем `26.6.3`) подтвердили L1 + L2.
- [ ] Транзитные контейнеры-миграторы остановлены и удалены (`docker ps -a | grep kc-migrate`).
- [ ] Есть бэкап/клон исходной БД на случай отката.

---

## Справочник терминов

| Термин | Значение |
|---|---|
| **Container-hop** | миграция через последовательный запуск реального контейнера KC каждой версии цепочки |
| **Хоп (hop)** | один шаг цепочки: загружаемая промежуточная/целевая версия KC |
| **L1 / Liquibase** | миграция схемы БД, трекинг в `DATABASECHANGELOG` |
| **L2 / RealmMigration** | миграция модели данных, трекинг в `MIGRATION_MODEL`; выполняется только при старте сервера |
| **target major** | целевой мажор (25 или 26), определяет цепочку хопов |
| **acquisition** | способ получить образ: `pull` \| `load` \| `preloaded` \| `build` |
| **harness** | испытательный стенд: свежая PG + случайный сидинг + полная цепочка + проверки |
| **dry-run** | режим «печатать команды, ничего не выполнять» (дефолт harness) |
| **Quarkus vs WildFly** | KC 24/25/26 = Quarkus (`KC_DB_URL`); KC16 = WildFly (`DB_VENDOR`/`KEYCLOAK_USER`) |

---

## Источники

Каждая команда выше сверена с кодом репозитория:

- `scripts/migrate_keycloak_v3.sh` — `MIGRATION_HOPS`/`MIGRATION_TARGET_FULL` (`:64-72`),
  `DEFAULT_TARGET_MAJOR`/`FORBIDDEN_VERSIONS`/`EOL_TARGET_MAJORS`/`MIN_PG_FOR_26` (`:74-81`),
  Java-требования (`:84-96`), выбор target (`:278-321`), сборка цепочки (`:234-247`, `:1537-1555`),
  PG≥14-гейт (`:255-256`, `:1549`), шаг хопа (`:1348-1496`), `usage()`/парсер флагов (`:2017-2129`).
- `scripts/lib/deployment_adapter.sh` — `kc_run_migrating_container` (`:507-540`).
- `scripts/lib/distribution_handler.sh` — `dist_image_ref` (`:29-42`), `dist_container`/acquisition
  (`:276-409`).
- `scripts/lib/profile_manager.sh` — парсер YAML/`profile_load` (`:35-127`), `PROFILE_DIR=./profiles`
  (`:8`), затирание `IMAGE_REF` (`:109`), `credentials_source` (`:84`).
- `scripts/lib/container_runtime.sh` — выбор движка `CONTAINER_RUNTIME→…→podman→docker` (`:14-44`).
- `scripts/lib/migration_verify.sh` — `kc_verify_migration_model` / SQL `MIGRATION_MODEL` (`:110-147`),
  `_mv_psql` (`:46-54`).
- `scripts/harness/run_migration_harness.sh` — флаги/дефолт dry-run (`:13-17,120-138`), `TARGET_MAJOR`
  и форс `current=16.1.1` (`:170-193`), цепочка хопов (`:69-115`).
- `scripts/harness/lib/harness_seed.sh` (`:22-32`), `harness_integrity.sh` (`:26-43`),
  `harness_runtime.sh` (`:40-72`).
- `scripts/build_matrix.sh` — матрица/JDK/`GHCR_IMAGE`/`cr save` (`:39-51,116-126,178`),
  `config/images.conf.example`, `docs/AIRGAP.md`.
- `ARCHITECTURE.md` — ADR-001/002/005/006 (`:47-52`); `CHANGELOG.md` — v3.8.0.
- Структура бандла (`tar` из 4 image-тарболлов) проверена через `tar -tJf dist/kc-astra-bundle.tar.xz`.
