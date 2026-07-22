> ЯЗЫК: 🇷🇺 Русский | [🇬🇧 English](README.en.md)

# Keycloak Migration Tool v3.9.7

**Утилита миграции Keycloak «в одну команду»** с авто-детектированием окружения, поддержкой мультитенантных и кластерных развёртываний, мониторингом в реальном времени, производственной закалкой (production hardening), **security-закалкой** (SAST, сканирование секретов, валидация ввода, аудит-логирование), **контейнерной поэтапной миграцией** (container-hop — на каждом шаге поднимается настоящий контейнер Keycloak и проверяется продвижение уровня MIGRATION_MODEL, Layer-2), **суверенными образами ОС** (Astra Linux SE / RED OS) с **air-gap** офлайн-дистрибуцией и поддержкой всех БД, официально поддерживаемых Keycloak.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-31%20suites-success)](tests/)
[![Bash](https://img.shields.io/badge/bash-5.0%2B-green.svg)](scripts/)
[![Databases](https://img.shields.io/badge/databases-6-blue.svg)](scripts/lib/database_adapter.sh)
[![Version](https://img.shields.io/badge/version-v3.9.7-blue.svg)](CHANGELOG.md)
[![Images](https://img.shields.io/badge/sovereign%20images-Astra%20SE%20%7C%20RED%20OS-blue.svg)](docs/AIRGAP.md)

---

## 🚀 Быстрый старт (90% случаев)

### 1. Клонировать репозиторий

```bash
git clone https://github.com/AlexGromer/keycloak-migration
cd keycloak-migration
```

### 2. Запустить мастер настройки

```bash
./scripts/config_wizard.sh
```

Мастер:
1. **Авто-детектирует** существующую установку Keycloak;
2. **Определяет** текущую версию по БД / развёртыванию;
3. **Спрашивает** целевую версию;
4. **Генерирует** профиль миграции;
5. **Выполняет** миграцию одной командой.

### 3. Либо прямой вызов с готовым профилем

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=my-profile.yaml
```

### 4. Container-hop одной командой (суверенные образы, v3.9)

Для цепочек `16.1.1 → 24.0.5 → 26.6.3` (target 26) или `16.1.1 → 25.0.6` (target 25) скрипт
`migrate_oneshot.sh` делает всё неинтерактивно — получает образы → генерирует профиль запуска и
контейнеров → мигрирует. По умолчанию dry-run; для боевого прогона добавьте `--go`:

```bash
export CONTAINER_RUNTIME=docker
# Только план (ничего не меняет):
scripts/migrate_oneshot.sh --target 26 --os astra --db-host <pg-host> --dry-run
# Боевой прогон (target 26 = 16.1.1 → 24.0.5 → 26.6.3):
export PROFILE_DB_PASSWORD=...
scripts/migrate_oneshot.sh --target 26 --os astra --db-host <pg-host> --source pull --go
```

Полный runbook (оба пути, air-gap, верификация, откат) — в **`docs/MIGRATION_GUIDE.md`**.

**Готово!** Остальное инструмент делает автоматически.

---

## 🧩 Автономность pg-client (новое в v3.9.7)

Начиная с **v3.9.7** узлу миграции **больше не нужны установленные `psql` / `pg_dump` /
`pg_restore`**. Каждый вызов PostgreSQL-клиента проходит через helper `pg_client`
(`scripts/lib/container_runtime.sh`):

- если бинарник есть на хосте — он запускается на хосте (прежний быстрый путь, сохраняет `-Fd`/`-j`);
- если бинарника нет — вызов исполняется **внутри контейнерного образа** (переменная
  `PROFILE_PG_CLIENT_IMAGE`, по умолчанию `postgres:16`) поверх host-сети `--network=host`, с
  проброшенным паролем БД (`PGPASSWORD`) и bind-монтированием файлов бэкапа тем же путём
  (`PG_CLIENT_MOUNT`, relabel `:z` для SELinux). Флаг `--user` добавляется только на явно
  rootful-движке.

**Advisory-lock по БД тоже стал автономным.** Межхостовая блокировка «одна миграция на одну
базу» (ADR-011) теперь удерживается через контейнер, когда `psql` на хосте отсутствует — **без
деградации** до более слабой пофайловой блокировки рабочего каталога. Долгоживущий `psql` живёт
в pg-client-контейнере как coproc поверх `docker/podman run --rm -i` и освобождается принудительным
удалением контейнера (проверены и аварийное, и штатное освобождение).

Требование совместимости: **мажор клиента должен быть ≥ мажора сервера БД** (`pg_dump` отказывается
работать с более новым сервером). `PROFILE_PG_CLIENT_IMAGE` переопределяется; решения зафиксированы в
**ADR-012** (автономность) и **ADR-013** (суверенный per-OS образ pg-client по умолчанию, собранный
FROM базы ALSE / RED OS) — см. `ARCHITECTURE.md`.

**Пример полностью автономного прогона** (на узле только контейнерный движок, `postgresql-client` не
установлен):

```bash
export PROFILE_DB_PASSWORD='...'
export PROFILE_PG_CLIENT_IMAGE=postgres:17   # мажор ≥ мажора сервера БД
scripts/migrate_oneshot.sh --target 26 --os astra --source preloaded \
  --image-ns ghcr.io/<you>/keycloak-migration \
  --db-host <db-host> --db-port 5432 --db-name keycloak --db-user keycloak --go
```

Бэкап, reconcile-запросы и advisory-lock — всё выполняется внутри pg-client-контейнера автоматически.

---

## 📦 Суверенные контейнерные образы (GHCR + Air-gap)

Hop-образы Keycloak собираются FROM суверенных баз ОС (**Astra Linux SE / RED OS**), публикуются в
**приватный GHCR** и поставляются как **air-gap tar-архивы**. Multistage + non-root (uid 1000);
Quarkus-образы запекают `--db=postgres` на этапе сборки.

| Тег образа | Версия KC | ОС |
|---|---|---|
| `ghcr.io/<owner>/keycloak-migration:astra-26.6.3` | 26.6.3 (Quarkus) | Astra SE |
| `…:redos-26.6.3` | 26.6.3 (Quarkus) | RED OS |
| `…:{astra,redos}-{16.1.1,24.0.5,25.0.6}` | звенья цепочки (16→24→26 / 16→25) | обе |

```bash
# Онлайн (приватный GHCR):
docker login ghcr.io && docker pull ghcr.io/<owner>/keycloak-migration:redos-26.6.3
# Офлайн (air-gap):
docker load -i kc-redos-26.6.3.tar.xz
```

**Собрать матрицу самостоятельно** (на своих лицензионных базах): отредактируйте `config/images.conf`
→ `scripts/build_matrix.sh --build [--publish]`. Полный runbook сборка → экспорт → перенос →
потребление: **[docs/AIRGAP.md](docs/AIRGAP.md)**.

---

## 🧪 Матрица испытаний

Прогон живьём на `docker` с засеянной базой Keycloak 16:

| Путь | 16→24→26 (target 26) | 16→25.0.6 (target 25) |
|---|---|---|
| `psql` присутствует на хосте | PASS (Complete) | PASS (Complete) |
| автономный (host-клиенты скрыты) | PASS (Complete) | PASS (Complete) |

Дополнительно проверен контейнерный путь: бэкап через контейнерный `pg_dump` + проверка целостности,
restore-into-scratch, `CREATE INDEX CONCURRENTLY`; advisory-lock — захват / удержание /
аварийное освобождение (`SIGKILL → EOF на stdin → контейнер завершается → блокировка снимается
автоматически) / штатное освобождение.

**Контроль качества:** 31/31 test suites; два независимых состязательных (adversarial) прохода
верификации закрыли 1 critical и 3 high дефекта до релиза.

> **Известное ограничение (честно):** второй **параллельный** захват контейнерной блокировки может
> «зависнуть» и затем упасть **fail-closed** (то есть по-прежнему отказывает — корректность
> сохраняется) под `docker run -i`. Одиночный прогон это не затрагивает. Рекомендуется
> перепроверить на `podman`.

---

## 🎯 Возможности

### Авто-детектирование
- **Текущая версия** — из JAR-манифеста, БД, Docker-образа или Kubernetes-развёртывания;
- **Тип БД** — из JDBC URL или CLI-инструментов;
- **Режим развёртывания** — Standalone / Docker / Kubernetes определяется автоматически;
- **Целевая версия** — интерактивный выбор с показом требований к Java.

### Поддержка нескольких БД
- ✅ **PostgreSQL** (рекомендуется)
- ✅ **MySQL / MariaDB**
- ✅ **CockroachDB** (v18+)
- ✅ **Oracle Database**
- ✅ **Microsoft SQL Server**
- ✅ **H2** (только dev, с предупреждениями)

### Поддержка нескольких режимов развёртывания
- ✅ **Standalone** (systemd, init.d, вручную)
- ✅ **Docker** (одиночный контейнер)
- ✅ **Docker Compose** (мультиконтейнер)
- ✅ **Kubernetes** (Deployment, StatefulSet)
- ✅ **Custom** (свои скрипты)

### Production-Ready
- ✅ **Расширенные preflight-проверки** — 15 проверок (диск, память, сеть, здоровье БД, статус Keycloak, зависимости, учётные данные) (v3.5)
- ✅ **Rate Limiting** — защита боевой БД от перегрузки с адаптивным троттлингом (v3.5)
- ✅ **Ротация бэкапов** — авто-очистка по политикам (keep-last-N, по времени, по размеру, GFS) (v3.5)
- ✅ **Детекция утечек соединений** — обнаружение idle-in-transaction (v3.5)
- ✅ **Circuit Breaker** — защита от каскадных сбоев с retry-логикой (v3.5)
- ✅ **SAST** — ShellCheck на pre-commit (v3.6)
- ✅ **Сканирование секретов** — gitleaks (v3.6)
- ✅ **Валидация ввода** — защита от SQL/command/path-инъекций (v3.6)
- ✅ **Управление секретами** — единый интерфейс Vault, K8s, AWS, Azure (v3.6)
- ✅ **HMAC-аудит-логирование** — криптографические подписи от подмены (v3.6)
- ✅ **Атомарные checkpoint'ы** — возобновление с любого шага
- ✅ **Авто-откат** при сбое
- ✅ **Airgap-режим** — предварительная валидация артефактов
- ✅ **JSON-аудит-логирование** — полная трассируемость
- ✅ **Мониторинг в реальном времени** — Prometheus + Grafana (v3.1)
- ✅ **Мультитенантность** — параллельная миграция изолированных инстансов (v3.2)
- ✅ **Кластерные развёртывания** — rolling update без простоя (v3.2)
- ✅ **Container-hop миграция** — на каждом шаге поднимается реальный контейнер Keycloak, проверяются Layer-1 (`DATABASECHANGELOG`) и Layer-2 (`MIGRATION_MODEL`)
- ✅ **verify** — приёмка после миграции: L2+L3+readiness+Admin API (ADR-010)
- ✅ **Layer-3 gate целостности данных** на каждом шаге (счётчики realm/user/client/role) (ADR-010)
- ✅ **Advisory-lock по БД** — одна миграция на одну базу, межхостово (ADR-011)
- ✅ **`--apply-indexes`** — создание индексов, пропущенных Keycloak, через `CONCURRENTLY` (v3.9.4/3.9.6)
- ✅ **Автономность pg-client** — `psql`/`pg_dump`/`pg_restore` на хосте не обязательны (v3.9.7, ADR-012/013)
- ✅ **Покрытие тестами** — 31 test suite (`tests/run_all_tests.sh`)

### Стратегии миграции
in-place, rolling update (K8s), blue-green, canary (v3.3).

### Оптимизации под конкретную БД (v3.4)
Параллельные jobs, `VACUUM ANALYZE`, XtraBackup / mariabackup, zone-aware backup CockroachDB, оценка
времени миграции.

### Путь миграции (реальные цепочки)
Инструмент поднимает версии Keycloak по проверенным промежуточным звеньям:

```
target 26:  16.1.1 → 24.0.5 → 26.6.3
target 25:  16.1.1 → 25.0.6
```

Требования к Java проверяются автоматически на каждом звене (Java 11 / 17 / 21). Целевые версии
зафиксированы в **ADR-002** (target 26 = **26.6.3**; версии 26.6.0 / 26.6.1 запрещены).

---

## 📖 Как это работает

Инструмент **мигрирует** существующую установку Keycloak, а не разворачивает её с нуля. Нужен уже
работающий инстанс Keycloak.

**Что делает инструмент:**
1. Определяет текущую версию Keycloak и окружение;
2. Делает бэкап БД;
3. Останавливает сервис Keycloak;
4. Скачивает / собирает целевую версию;
5. Обновляет схему БД;
6. Перезапускает на новой версии;
7. Валидирует и при необходимости откатывает.

**Чего инструмент НЕ делает:**
- ❌ Не ставит Keycloak с нуля;
- ❌ Не provision'ит инфраструктуру;
- ❌ Не настраивает сеть / DNS.

---

## 📦 Установка

### Требования
- Bash 5.0+;
- существующая установка Keycloak (16.1.1+);
- клиент БД (`psql`, `mysql`, `cockroach`, …) — **или** контейнерный движок (см. автономность pg-client);
- Java (версия по требованиям Keycloak);
- для Kubernetes — `kubectl`.

### Клонирование и запуск

```bash
git clone https://github.com/AlexGromer/keycloak-migration
cd keycloak-migration
./scripts/config_wizard.sh
```

---

## 🎮 Примеры использования

### 1. Интерактивный мастер (рекомендуется)
```bash
./scripts/config_wizard.sh
```
Авто-обнаружение установок и генерация YAML-профиля.

### 2. Неинтерактивный режим (CI/CD)
```bash
export PROFILE_DB_TYPE=postgresql
export PROFILE_KC_DEPLOYMENT_MODE=kubernetes
export PROFILE_KC_CURRENT_VERSION=16.1.1
export PROFILE_KC_TARGET_VERSION=26.6.3

./scripts/config_wizard.sh --non-interactive --profile-name ci-migration
./scripts/migrate_keycloak_v3.sh migrate --profile ci-migration
```

### 3. Только авто-обнаружение
```bash
./scripts/kc_discovery.sh
```
Сканирует окружение и создаёт профиль автоматически.

---

## 🚁 Продвинутые сценарии

> Ниже — сжатые примеры. Полные профили лежат в каталоге `profiles/`, подробные runbook'и —
> в **[docs/MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md)** и **[docs/AIRGAP.md](docs/AIRGAP.md)**.

### Мультитенантная миграция (v3.2)

**Сценарий:** SaaS-платформа с несколькими изолированными инстансами Keycloak.
**Профиль:** `profiles/multi-tenant-example.yaml`

```yaml
profile:
  name: multi-tenant-saas
  mode: multi-tenant

migration:
  strategy: rolling_update
  parallel: true

tenants:
  - name: enterprise-corp
    database:
      host: db1.example.com
      name: keycloak_enterprise
    deployment:
      mode: kubernetes
      namespace: keycloak-enterprise
      replicas: 3
  - name: smb-startup
    database:
      host: db2.example.com
      name: keycloak_smb
    deployment:
      mode: kubernetes
      namespace: keycloak-smb
      replicas: 2

rollout:
  type: parallel        # parallel | sequential
  max_concurrent: 3
```

Живой прогресс по тенантам:
```
┌─ MIGRATION PROGRESS (3/3 tenants) ────────────────────────────┐
│ enterprise-corp  |  87% [████████████████████░░░░░░] 16→26    │
│ smb-startup      |  92% [██████████████████████░░░]  16→26    │
│ trial-demo       | 100% [████████████████████████]   16→26 ✓ │
└────────────────────────────────────────────────────────────────┘
```

**Возможности:** параллельное/последовательное выполнение, per-tenant checkpoint'ы и откат,
агрегированный аудит, прогресс по каждому тенанту, независимая обработка сбоев (один упал — остальные
продолжают).

### Кластерное развёртывание (v3.2)

**Сценарий:** 4 standalone-узла Keycloak на bare-metal за HAProxy с общей БД.
**Профиль:** `profiles/clustered-bare-metal-example.yaml`

```yaml
profile:
  name: clustered-bare-metal
  mode: clustered

migration:
  strategy: rolling_update
  auto_rollback: true

database:
  type: postgresql
  host: db-cluster.example.com
  name: keycloak

cluster:
  load_balancer:
    type: haproxy
    host: lb.example.com
    admin_socket: /var/run/haproxy/admin.sock
    backend_name: keycloak_backend
  nodes:
    - name: kc-node-1
      host: 192.168.1.101
      ssh_user: keycloak
      keycloak_home: /opt/keycloak
    # kc-node-2..4 аналогично

rollout:
  type: sequential
  nodes_at_once: 1
  drain_timeout: 60      # сек на слив соединений
  startup_timeout: 120   # сек на здоровье узла
```

**Процесс rolling update:** drain узла из LB → ждём завершения активных соединений → миграция узла →
health check → возврат в LB → следующий узел.
**Возможности:** zero-downtime, интеграция с LB (HAProxy / Nginx), connection draining, health-check
перед возвратом, авто-откат, мониторинг по узлам.

### Стратегии Blue-Green и Canary (v3.3)

**Blue-Green** (`profiles/blue-green-k8s-istio.yaml`) — миграция без простоя с мгновенным
переключением трафика. Оба окружения (blue v16 / green v26) используют одну БД, поэтому конфликтов
миграции схемы нет; откат — мгновенное переключение обратно.

```yaml
profile:
  name: blue-green-k8s-istio
  strategy: blue_green

migration:
  current_version: "16.1.1"
  target_version: "26.6.3"

blue_green:
  old_environment: "blue"
  new_environment: "green"
  deployment:
    type: kubernetes
    namespace: keycloak
    replicas: 3
  traffic_router:
    type: istio          # istio | nginx | haproxy
    virtualservice: keycloak-vs
    subset_blue: v16
    subset_green: v26
  readiness_timeout: 600
  keep_old: false
  cleanup_delay: 300
```

**Canary** (`profiles/canary-k8s-istio.yaml`) — прогрессивное развёртывание с валидацией по
Prometheus на каждой фазе (10% → 50% → 100%). Авто-откат по порогам: `error_rate` > 0.01, `p99` >
500 мс, недостаточно запросов, либо 3 подряд неуспешные валидации.

```yaml
migration:
  current_version: "16.1.1"
  target_version: "26.6.3"

canary:
  deployment:
    namespace: keycloak
    deployment: keycloak
    replicas: 10
  traffic_router:
    type: istio
    virtualservice: keycloak-vs
    subset_old: v16
    subset_new: v26
  phases:
    - name: phase-1-initial
      percentage: 10
      replicas: 1
      duration: 3600
      validation:
        error_rate_threshold: 0.01
        latency_p99_threshold: 500
        min_requests: 100
    - name: phase-2-half
      percentage: 50
      replicas: 5
      duration: 7200
    - name: phase-3-full
      percentage: 100
      replicas: 10
      duration: 1800
  auto_rollback: true

validation:
  prometheus_url: http://prometheus.monitoring.svc.cluster.local:9090
```

### Оптимизации под конкретную БД (v3.4)

Все оптимизации **автоматические**, конфигурация не нужна — инструмент определяет тип БД и применяет
подходящие настройки:
- PostgreSQL: авто-подбор параллельных jobs по формуле `min(cpu_cores, max(1, db_size_gb / 2))`,
  учёт размера БД, `VACUUM ANALYZE` после миграции, рекомендации по пулу соединений;
- MySQL: Percona **XtraBackup** (горячий бэкап, до 10× быстрее `mysqldump`);
- MariaDB: **mariabackup**;
- CockroachDB: zone-aware backup (multi-region);
- оценка времени миграции до старта.

Ручное переопределение авто-тюнинга:
```yaml
database:
  type: postgresql
  backup:
    parallel_jobs: 8      # переопределить авто-подбор
    verify: true          # проверка целостности бэкапа
  optimization:
    vacuum_analyze: true
    show_recommendations: true
```

Выигрыш: 2–4× быстрее бэкапы PostgreSQL, до 10× MySQL XtraBackup, оптимизированные запросы после
`VACUUM ANALYZE`, right-sized конфигурация, верификация бэкапов, точные оценки времени.

### Производственная закалка (v3.5)

**(A) 15 preflight-проверок** выполняются автоматически перед каждой миграцией и группируются как:
*System Resources* (диск, память, сеть), *Database Health* (доступность, версия, размер, статус
репликации PRIMARY/REPLICA), *Keycloak Health* (статус сервиса, учётные данные Admin API), *Backup
Validation* (место под бэкап, права каталога), *Dependencies* (нужные утилиты, версия Java),
*Configuration* (синтаксис YAML, учётные данные). При провале критичных проверок миграция
**блокируется**.

**(B) Rate Limiting и защита БД:** стратегии `fixed` / `token_bucket` / `adaptive`, circuit breaker
(порог 5 сбоев), экспоненциальный backoff, мониторинг пула соединений (предупреждение при >80%),
детекция утечек.

```yaml
migration:
  rate_limiting:
    enabled: true
    strategy: adaptive        # fixed | token_bucket | adaptive
    ops_per_second: 10
    circuit_breaker:
      threshold: 5
      timeout: 30
```

**(C) Ротация бэкапов:** политики `keep_last_n`, по времени, по размеру, GFS
(Grandfather-Father-Son), комбинированная.

```yaml
backup:
  rotation:
    policy: keep_last_n       # keep_last_n | time_based | size_based | gfs | combined
    keep_count: 5
    max_age_days: 30
    max_size_gb: 100
    # для GFS: daily_keep: 7 / weekly_keep: 4 / monthly_keep: 12
```

Ручной запуск (`source scripts/lib/backup_rotation.sh`): `rotate_keep_last_n`, `rotate_by_age`,
`rotate_by_size`, `rotate_gfs`, `get_backup_statistics`.

### Интеграция мониторинга (v3.1)

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=prod.yaml --enable-monitoring
# Поднять стек:
cd examples/monitoring && docker-compose up -d
```

Доступ: **Grafana** `http://localhost:3000` (7 панелей, авто-refresh 5 c), **Prometheus**
`http://localhost:9091`, **Alertmanager** `http://localhost:9093` (11 правил алертов).

Экспортируемые метрики: `keycloak_migration_progress`, `_checkpoint_status`, `_duration_seconds`,
`_errors_total`, `_database_size_bytes`, `_java_heap_bytes`, `_last_success_timestamp`.
Метки для мультиинстанса: `tenant="…"`, `node="…"`.

---

## 🏗️ Архитектура

```
┌─────────────────────────────────────────────────────────────────┐
│                  KEYCLOAK MIGRATION v3.9.7                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐  │
│  │   Profile    │──────│  Discovery   │──────│  Migration   │  │
│  │   Manager    │      │   Engine     │      │   Engine     │  │
│  └──────────────┘      └──────────────┘      └──────────────┘  │
│         │                      │                      │         │
│         ▼                      ▼                      ▼         │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐  │
│  │   Database   │      │  Deployment  │      │ Distribution │  │
│  │   Adapter    │      │   Adapter    │      │   Handler    │  │
│  └──────────────┘      └──────────────┘      └──────────────┘  │
│         │                      │                      │         │
│         └──────────────────────┴──────────────────────┘         │
│                                │                                │
│                                ▼                                │
│                      ┌──────────────────┐                       │
│                      │  State Manager   │                       │
│                      │  + Checkpoints   │                       │
│                      └──────────────────┘                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Database Adapter** (`scripts/lib/database_adapter.sh`): `db_validate_type`, `db_detect_type`,
`db_build_jdbc_url`, `db_backup` / `db_restore`.
**Deployment Adapter** (`scripts/lib/deployment_adapter.sh`): `deploy_validate_mode`,
`deploy_detect_mode`, `kc_start` / `kc_stop`, `kc_health_check`.
**Distribution Handler** (`scripts/lib/distribution_handler.sh`): `dist_download`,
`dist_validate_airgap`, `dist_check_network`.

Решения зафиксированы в `ARCHITECTURE.md` (ADR-001 … ADR-013).

---

## 📋 Типовые потоки

### Standalone → Kubernetes
```bash
./scripts/config_wizard.sh
./scripts/migrate_keycloak_v3.sh plan     --profile standalone-postgresql   # dry-run
./scripts/migrate_keycloak_v3.sh migrate  --profile standalone-postgresql
./scripts/migrate_keycloak_v3.sh rollback                                    # при необходимости
```

### Kubernetes Rolling Update
```yaml
# profiles/k8s-production.yaml
keycloak:
  deployment_mode: kubernetes
  cluster_mode: infinispan
  current_version: 16.1.1
  target_version: 26.6.3
  kubernetes:
    namespace: keycloak
    deployment: keycloak
    replicas: 3

migration:
  strategy: rolling_update   # zero-downtime
  run_smoke_tests: true
  backup_before_step: true
```

### Air-gap миграция
```bash
# 1. На СВЯЗАННОМ хосте: собрать бандл суверенных образов
scripts/build_matrix.sh --build           # -> dist/kc-<os>-<ver>.tar (+ .sha256)
#    (или взять готовый комбинированный бандл dist/kc-<os>-bundle.tar.xz)
# 2. Перенести dist/*.tar(.xz) + .sha256 на изолированный контур и проверить контрольную сумму
sha256sum -c kc-astra-bundle.tar.xz.sha256
# 3. В AIR-GAP: миграция из офлайн-бандла (образы грузятся из tar; хостовый psql не требуется — v3.9.7)
scripts/migrate_oneshot.sh --target 26 --os astra --source bundle \
  --bundle dist/kc-astra-bundle.tar.xz \
  --db-host <db-host> --db-port 5432 --db-name keycloak --db-user keycloak --go
#    (или --source preloaded, если образы уже загружены в рантайм)
```
> Полный runbook офлайн-поставки: [docs/AIRGAP.md](docs/AIRGAP.md).

---

## 🧪 Тестирование

```bash
# Все тесты
./tests/run_all_tests.sh

# Отдельные наборы
./tests/test_database_adapter.sh
./tests/test_deployment_adapter.sh
./tests/test_profile_manager.sh
./tests/test_migration_logic.sh
./tests/test_pg_client.sh          # автономность pg-client (v3.9.7)
```

Актуальный авторитетный результат: **`run_all_tests.sh` — 31/31**.

---

## 📁 Структура проекта

```
kk_migration/
├── scripts/
│   ├── migrate_keycloak_v3.sh      # основной скрипт миграции
│   ├── migrate_oneshot.sh          # container-hop «в одну команду»
│   ├── config_wizard.sh            # интерактивная настройка
│   ├── kc_discovery.sh             # авто-обнаружение
│   ├── build_matrix.sh             # сборка матрицы суверенных образов
│   └── lib/
│       ├── database_adapter.sh     # абстракция БД (6 движков)
│       ├── deployment_adapter.sh   # абстракция развёртывания (5 режимов)
│       ├── container_runtime.sh    # движок контейнеров + pg_client (v3.9.7)
│       ├── db_lock.sh              # advisory-lock по БД (ADR-011)
│       ├── migration_verify.sh     # verify: L2+L3+readiness+Admin API (ADR-010)
│       ├── data_integrity.sh       # Layer-3 gate целостности (ADR-010)
│       ├── profile_manager.sh      # работа с YAML-профилями
│       ├── distribution_handler.sh # управление артефактами
│       ├── keycloak_discovery.sh   # сканирование окружения
│       └── audit_logger.sh         # JSON-аудит-логирование
│
├── profiles/                       # YAML-профили (multi-tenant, clustered, blue-green, canary, …)
├── tests/                          # наборы тестов (run_all_tests.sh — 31/31)
├── docs/                           # MIGRATION_GUIDE.md, AIRGAP.md
└── README.md
```

---

## 🔧 Конфигурация

### Пример YAML-профиля
```yaml
profile:
  name: standalone-postgresql
  environment: standalone

database:
  type: postgresql
  location: standalone
  host: localhost
  port: 5432
  name: keycloak
  user: keycloak
  credentials_source: env

keycloak:
  deployment_mode: standalone
  distribution_mode: container
  cluster_mode: standalone
  current_version: 16.1.1
  target_version: 26.6.3

migration:
  strategy: inplace
  parallel_jobs: 4
  timeout_per_version: 900
  run_smoke_tests: true
  backup_before_step: true
```

### Переменные окружения
```bash
# Учётные данные БД
export KC_DB_PASSWORD="secret"
export PROFILE_DB_PASSWORD="secret"       # для боевого container-hop

# Неинтерактивный режим
export NON_INTERACTIVE=true
export PROFILE_DB_TYPE=postgresql
export PROFILE_KC_DEPLOYMENT_MODE=kubernetes

# Container-hop / автономность pg-client (v3.9.7)
export CONTAINER_RUNTIME=docker
export PROFILE_PG_CLIENT_IMAGE=postgres:16   # мажор ≥ мажора сервера БД
# PG_CLIENT_MOUNT — путь bind-монтирования файлов бэкапа в pg-client-контейнер

# Опции миграции
export AIRGAP_MODE=true
export AUTO_ROLLBACK=true
export SKIP_PREFLIGHT=false
```

---

## 🚀 Продвинутые возможности

### Атомарные checkpoint'ы
Возобновление миграции с любого шага:
```
backup_done → stopped → downloaded → built →
started → migrated → health_ok → tests_ok
```
При падении на `health_ok` — исправьте причину и запустите снова, инструмент продолжит с последнего
checkpoint'а. **Важно:** не переиспользуйте один и тот же `--work-dir` между разными прогонами (иначе
устаревшие checkpoint'ы могут исказить реконсиляцию состояния).

### verify и gate целостности данных (ADR-010)
Подкоманда `verify` выполняет приёмку после миграции: продвижение Layer-2 (`MIGRATION_MODEL`),
Layer-3 (счётчики realm / user / client / role), readiness и вызовы Admin API. Layer-3 gate
целостности отрабатывает на **каждом** hop'е.

### Advisory-lock по БД (ADR-011)
Одновременно на одной базе выполняется **только одна** миграция — межхостово. В v3.9.7 блокировка
удерживается через pg-client-контейнер, если `psql` на хосте отсутствует (см. раздел «Автономность
pg-client»).

### Авто-откат (уточнение по ADR-009)
Gate миграции — **продвижение Layer-2** (`MIGRATION_MODEL`), а health check теперь **диагностический**
(ADR-009), а не решающий. Авто-откат срабатывает при **сбое миграции**, а не «при неуспешном health
check»:
```bash
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --auto-rollback
```

### `--apply-indexes` (v3.9.4/3.9.6)
Создаёт индексы, которые Keycloak пропустил (порог), через `CREATE INDEX CONCURRENTLY IF NOT EXISTS`.
Флаг имеет приоритет над значением из профиля (env-wins).

### Аудит-логирование
Все операции пишутся в `migration_audit.jsonl`:
```json
{"ts":"2026-07-22T21:15:00Z","level":"INFO","event":"migration_start","profile":"k8s-prod","from_version":"16.1.1","to_version":"26.6.3"}
{"ts":"2026-07-22T21:16:32Z","level":"INFO","event":"backup_created","version":"24.0.5","backup_path":"/opt/backup_24.0.5.dump","size_bytes":"458123456"}
{"ts":"2026-07-22T21:18:45Z","level":"INFO","event":"migration_step","version":"24.0.5","status":"migrated","duration_s":"133"}
{"ts":"2026-07-22T21:35:12Z","level":"INFO","event":"migration_end","profile":"k8s-prod","status":"success","total_duration_s":"1212"}
```

---

## 🛠️ CLI-справочник

```bash
# Подкоманды
./scripts/migrate_keycloak_v3.sh migrate  --profile <name>
./scripts/migrate_keycloak_v3.sh plan     --profile <name>
./scripts/migrate_keycloak_v3.sh verify   --profile <name>    # приёмка после миграции (ADR-010)
./scripts/migrate_keycloak_v3.sh rollback [--force]
#   Офлайн-получение образов (air-gap) — НЕ подкоманда migrate_keycloak_v3.sh;
#   см. `migrate_oneshot.sh --source bundle|preloaded` ниже и docs/AIRGAP.md.

# Флаги
--airgap                 # офлайн-режим (сначала валидировать артефакты)
--auto-rollback          # авто-откат при сбое миграции
--skip-preflight         # пропустить preflight-проверки (не рекомендуется)
--dry-run                # показать план без выполнения
--apply-indexes          # создать пропущенные индексы через CONCURRENTLY (v3.9.4/3.9.6)
--no-resume              # игнорировать существующие checkpoint'ы, начать заново
--force-unlock           # снять «застрявший» advisory-lock (ADR-011)
--security-scan          # запустить security-сканирование (ShellCheck / gitleaks)

# One-shot container-hop (migrate_oneshot.sh — свои флаги, НЕ migrate_keycloak_v3.sh)
scripts/migrate_oneshot.sh --target <25|26> --os <astra|redos> --db-host <host> \
  --source <pull|bundle|preloaded> [--bundle <file>] [--dry-run | --go]
#   --env-file <path>        # загрузить переменные окружения из файла
#   --wizard                 # запустить интерактивный мастер
#   --image-ref-template <t> # шаблон ссылки на образы для container-hop

# Управление профилями
./scripts/migrate_keycloak_v3.sh profile list
./scripts/migrate_keycloak_v3.sh profile validate <name>

# Авто-обнаружение
./scripts/kc_discovery.sh [--output <profile-name>]
```

---

## 📊 Системные требования

- **ОС:** Linux (проверено на Debian, Ubuntu, RHEL, Kali; суверенные — Astra Linux SE, RED OS);
- **Bash:** 5.0+;
- **Диск:** место под бэкап проверяется **измеримо** (реальный размер БД × запас) с нижним порогом
  512 МБ — жёсткого требования «15 ГБ» больше нет (см. CHANGELOG [3.9.1]/[3.9.2]);
- **Память:** 4 ГБ+ рекомендуется;
- **Java:** 11 / 17 / 21 (авто-валидация под каждое звено).

### Опциональные инструменты
`kubectl` (Kubernetes), `docker` / `docker-compose` (контейнеры и автономность pg-client), `helm`,
`gitleaks` / `trufflehog` (секреты), `jq` (JSON-аудит).

---

## 🐛 Устранение неполадок

**Проблема:** `Java version insufficient`
```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
```

**Проблема:** миграция упала на checkpoint'е
```bash
# Возобновление с последнего checkpoint'а (тот же профиль, тот же --work-dir):
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
```

**Проблема:** health check не проходит
```bash
# Health диагностический (ADR-009). Откат вручную:
./scripts/migrate_keycloak_v3.sh rollback
# Либо включить авто-откат при сбое миграции:
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --auto-rollback
```

**Проблема:** advisory-lock «застрял» после аварийного прогона
```bash
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --force-unlock
```

**Проблема:** валидация air-gap не проходит
```bash
# Проверьте контрольную сумму бандла и пересоберите его при необходимости:
sha256sum -c kc-astra-bundle.tar.xz.sha256
scripts/build_matrix.sh --build
# Затем прогон из бандла (см. «Air-gap миграция» выше и docs/AIRGAP.md):
scripts/migrate_oneshot.sh --target 26 --os astra --source bundle --bundle dist/kc-astra-bundle.tar.xz --db-host <db-host> --go
```

---

## 🔧 Способы запуска инструмента (интеграции)

> **Примечание:** это способы **запускать сам инструмент миграции**, а не разворачивать Keycloak.
> Интеграции Docker/Helm/Ansible/Terraform и облачные примеры сейчас числятся в CHANGELOG как
> **[Unreleased] Planned** — задокументированы, но ещё не поставлены.

### Docker (CI/CD и изоляция)
```bash
docker run --rm \
  -v $(pwd)/profiles:/data \
  -v ~/.kube:/root/.kube \
  ghcr.io/<owner>/keycloak-migration:redos-26.6.3 \
  --profile=/data/production.yaml
```

### Helm (K8s-native Job с RBAC)
```bash
helm install my-migration ./examples/helm/keycloak-migration \
  --set database.host=keycloak-db \
  --set migration.targetVersion=26.6.3
```

### Ansible (оркестрация >3 серверов)
```bash
ansible-playbook -i inventory examples/ansible/keycloak-migration.yml \
  --limit production-servers
```

### Terraform (IaC)
```hcl
module "keycloak_migration" {
  source        = "./examples/terraform/modules/keycloak-migration"
  database_host = aws_db_instance.keycloak.endpoint
  target_version = "26.6.3"
}
```

### Облачные примеры
AWS (EKS + RDS), GCP (GKE + Cloud SQL), Azure (AKS + Azure Database) — `examples/cloud/`.

---

## 📜 Лицензия

MIT License.

## 🤝 Вклад

1. Форкните репозиторий;
2. Создайте feature-ветку;
3. Добавьте тесты;
4. Убедитесь, что все тесты проходят: `./tests/run_all_tests.sh`;
5. Откройте pull request.

## 📚 Документация

- **[QUICKSTART.md](QUICKSTART.md)** — начните отсюда: каждый параметр, источники образов, что
  происходит на каждом шаге и что делать при сбое;
- [docs/MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md) — полный runbook;
- [docs/AIRGAP.md](docs/AIRGAP.md) — офлайн / суверенная поставка;
- [ARCHITECTURE.md](ARCHITECTURE.md) — принятые решения (ADR-001 … ADR-013);
- [CHANGELOG.md](CHANGELOG.md) — что менялось и что ломалось до исправления.

## 🏆 Авторы

Разработано [AlexGromer](https://github.com/AlexGromer) при поддержке Claude Code.

---

**Repository:** https://github.com/AlexGromer/keycloak-migration
