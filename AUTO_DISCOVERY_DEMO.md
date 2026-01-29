# Auto-Discovery System Demo — v3.0

**Модуль автоматического обнаружения Keycloak** в различных окружениях.

---

## Возможности

### 1. Обнаружение Keycloak

Модуль `keycloak_discovery.sh` автоматически находит Keycloak в:

| Режим | Метод обнаружения | Что находит |
|-------|-------------------|-------------|
| **Standalone** | Файловая система + systemd | `/opt/keycloak`, `/usr/local/keycloak`, systemd сервисы |
| **Docker** | `docker ps` | Запущенные и остановленные контейнеры с Keycloak |
| **Docker Compose** | `find docker-compose.yml` | Сервисы Keycloak в compose-файлах |
| **Kubernetes** | `kubectl get deployments/statefulsets` | Deployments и StatefulSets во всех namespace |
| **Deckhouse** | `kubectl get moduleconfig` | ModuleConfig с Keycloak |

---

## Примеры использования

### Пример 1: Standalone обнаружение

```bash
$ source scripts/lib/keycloak_discovery.sh
$ kc_discover_standalone

# Вывод:
/opt/keycloak|16.1.1|standalone
/opt/keycloak-26.0.7|26.0.7|standalone
/usr/local/keycloak|25.0.0|systemd:keycloak
```

**Формат**: `path|version|mode`

---

### Пример 2: Docker обнаружение

```bash
$ kc_discover_docker

# Вывод:
keycloak|16.1.1|docker:quay.io/keycloak/keycloak:16.1.1
keycloak-test|stopped|docker:keycloak/keycloak:latest
```

---

### Пример 3: Kubernetes обнаружение

```bash
$ kc_discover_kubernetes

# Вывод:
keycloak/keycloak|25.0.0|kubernetes:replicas=3,image=keycloak/keycloak:25.0.0
production/keycloak-prod|26.0.7|kubernetes:replicas=5,image=docker.io/keycloak/keycloak:26.0.7
```

---

### Пример 4: Полное автообнаружение (все режимы)

```bash
$ kc_discover_all

# Вывод:
🔍 Searching for Keycloak installations...
  → Checking standalone...
  → Checking Docker...
  → Checking Docker Compose...
  → Checking Kubernetes...
  → Checking Deckhouse...

# Результаты:
/opt/keycloak|16.1.1|standalone
keycloak-dev|17.0.0|docker-compose:./test_lab/docker-compose.yml
production/keycloak|25.0.0|kubernetes:replicas=3,image=keycloak/keycloak:25.0.0
```

---

## Интерактивный выбор

### Пример: Выбор из нескольких установок

```bash
$ kc_select_installation

🔍 Searching for Keycloak installations...
  → Checking standalone...
  → Checking Docker...
  → Checking Docker Compose...
  → Checking Kubernetes...
  → Checking Deckhouse...

✅ Found 3 Keycloak installations:

  [1] standalone → /opt/keycloak (version: 16.1.1)
  [2] docker-compose:./test_lab/docker-compose.yml → keycloak (version: running)
  [3] kubernetes:replicas=3,image=keycloak/keycloak:25.0.0 → production/keycloak (version: 25.0.0)

Select installation [1-3]: 3

# Результат: production/keycloak|25.0.0|kubernetes:replicas=3,image=keycloak/keycloak:25.0.0
```

---

## Автоматическое создание профиля

### Пример: Полный workflow автообнаружения

```bash
$ source scripts/lib/profile_manager.sh
$ source scripts/lib/keycloak_discovery.sh

$ kc_auto_discover_profile

═══════════════════════════════════════════════════════════
  Keycloak Auto-Discovery v3.0
═══════════════════════════════════════════════════════════

🔍 Searching for Keycloak installations...
  → Checking standalone...
  → Checking Docker...
  → Checking Docker Compose...
  → Checking Kubernetes...
  → Checking Deckhouse...

✅ Found 1 Keycloak installation:

  Location: production/keycloak
  Version:  25.0.0
  Mode:     kubernetes:replicas=3,image=keycloak/keycloak:25.0.0

Use this installation? [Y/n]: y

─────────────────────────────────────────────────────────────
✅ Profile populated from discovery:
  Deployment Mode: kubernetes
  Current Version: 25.0.0

─────────────────────────────────────────────────────────────
✅ Database auto-detected:
  Type: postgresql
  Host: postgres-postgresql.database.svc.cluster.local:5432
  Database: keycloak
  User: keycloak

═══════════════════════════════════════════════════════════
✅ Auto-discovery complete!
═══════════════════════════════════════════════════════════

# Переменные окружения установлены:
$ echo $PROFILE_KC_DEPLOYMENT_MODE
kubernetes

$ echo $PROFILE_KC_CURRENT_VERSION
25.0.0

$ echo $PROFILE_DB_TYPE
postgresql

$ echo $PROFILE_K8S_NAMESPACE
production

$ echo $PROFILE_K8S_REPLICAS
3
```

---

## Преобразование в профиль

### Пример: Сохранение обнаруженной конфигурации

```bash
# После автообнаружения (переменные PROFILE_* установлены)
$ export PROFILE_KC_TARGET_VERSION="26.0.7"
$ export PROFILE_MIGRATION_STRATEGY="rolling_update"
$ export PROFILE_MIGRATION_RUN_TESTS="true"

# Сохранить профиль
$ profile_save "production-auto-discovered"

Profile saved: /opt/kk_migration/profiles/production-auto-discovered.yaml

# Содержимое профиля:
$ cat profiles/production-auto-discovered.yaml
```

```yaml
# Keycloak Migration Profile v3.0
# Generated: 2026-01-29 12:34:56 UTC

profile:
  name: production-auto-discovered
  environment: kubernetes

database:
  type: postgresql
  location: kubernetes
  host: postgres-postgresql.database.svc.cluster.local
  port: 5432
  name: keycloak
  user: keycloak
  credentials_source: secret

keycloak:
  deployment_mode: kubernetes
  distribution_mode: container
  cluster_mode: infinispan

  current_version: 25.0.0
  target_version: 26.0.7

  kubernetes:
    namespace: production
    deployment: keycloak
    service: keycloak-http
    replicas: 3

  container:
    registry: docker.io
    image: keycloak/keycloak
    pull_policy: IfNotPresent

migration:
  strategy: rolling_update
  parallel_jobs: 4
  timeout_per_version: 900
  run_smoke_tests: true
  backup_before_step: true
```

---

## Использование в мастере конфигурации

### Пример: config_wizard.sh с автообнаружением

```bash
$ ./scripts/config_wizard.sh

┌─────────────────────────────────────────────────────────────────┐
│   Keycloak Migration Configuration Wizard v3.0                  │
│   Universal Migration Tool for All Environments                 │
└─────────────────────────────────────────────────────────────────┘

═══ [0/8] Auto-Discovery ═══

Would you like to auto-discover existing Keycloak installation?
This will scan your environment for Keycloak instances.

Run auto-discovery? [Y/n]: y

🔍 Searching for Keycloak installations...
  → Checking standalone...
  → Checking Docker...
  → Checking Docker Compose...
  → Checking Kubernetes...
  → Checking Deckhouse...

✅ Found 1 Keycloak installation:

  Location: keycloak/keycloak
  Version:  16.1.1
  Mode:     kubernetes:replicas=1,image=keycloak/keycloak:16.1.1

Use this installation? [Y/n]: y

─────────────────────────────────────────────────────────────
✅ Profile populated from discovery:
  Deployment Mode: kubernetes
  Current Version: 16.1.1

─────────────────────────────────────────────────────────────
✅ Database auto-detected:
  Type: postgresql
  Host: postgres-postgresql.database.svc.cluster.local:5432
  Database: keycloak
  User: keycloak

═══════════════════════════════════════════════════════════
✅ Auto-discovery complete!
═══════════════════════════════════════════════════════════

═══ [1/8] Database Type ═══

[INFO] Database type already set from auto-discovery: postgresql
Keep this database type? [Y/n]: y

═══ [2/8] Database Location ═══

[INFO] Database location already set from auto-discovery: postgres-postgresql.database.svc.cluster.local:5432
Keep this database location? [Y/n]: y

═══ [3/8] Keycloak Deployment Mode ═══

[INFO] Deployment mode already set from auto-discovery: kubernetes
Keep this deployment mode? [Y/n]: y

... (остальные шаги) ...

═══ Configuration Summary ═══

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Profile:           kubernetes-postgresql-standalone

  Database:          postgresql (kubernetes)
                     postgres-postgresql.database.svc.cluster.local:5432/keycloak

  Deployment:        kubernetes
  Distribution:      container
  Cluster Mode:      standalone

  Kubernetes:        keycloak/keycloak
                     Replicas: 1

  Migration:         16.1.1 → 26.0.7
  Strategy:          rolling_update

  Options:
    Smoke Tests:     true
    Backups:         true
    Parallel Jobs:   4
    Timeout:         900s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Save this profile? [Y/n]: y
[✓] Profile saved to: /opt/kk_migration/profiles/kubernetes-postgresql-standalone.yaml

Start migration now? [y/N]: n

[INFO] To run migration later, use:

  ./scripts/migrate_keycloak_v3.sh migrate --profile kubernetes-postgresql-standalone

```

---

## Функции API

### Основные функции обнаружения

```bash
# Обнаружение по типу развёртывания
kc_discover_standalone      # → path|version|mode
kc_discover_docker          # → container|version|mode
kc_discover_docker_compose  # → service|version|mode
kc_discover_kubernetes      # → namespace/deployment|version|mode
kc_discover_deckhouse       # → module|version|mode

# Универсальное обнаружение
kc_discover_all             # → все установки из всех режимов

# Интерактивный выбор
kc_select_installation      # → выбранная установка

# Преобразование в профиль
kc_discovery_to_profile <discovery_result>
  # → устанавливает PROFILE_* переменные

# Обнаружение БД из конфигурации KC
kc_discover_database <deploy_mode> [args]
  # → устанавливает PROFILE_DB_* переменные

# Полный автоматический workflow
kc_auto_discover_profile
  # → обнаружение + выбор + преобразование + обнаружение БД
```

---

## Поддерживаемые сценарии

| Сценарий | Обнаружение KC | Обнаружение БД | Автопрофиль |
|----------|----------------|----------------|-------------|
| **Standalone на localhost** | ✅ Путь + версия | ✅ Из keycloak.conf | ✅ Полный |
| **Docker контейнер** | ✅ Контейнер + образ | ✅ Из keycloak.conf | ✅ Полный |
| **Docker Compose** | ✅ Сервис + compose-файл | ✅ Из keycloak.conf | ✅ Полный |
| **Kubernetes** | ✅ Namespace/deployment + replicas | ✅ Из ConfigMap | ✅ Полный |
| **Deckhouse** | ✅ ModuleConfig | ⚠️ Ограниченно | ⚠️ Частичный |
| **Несколько установок** | ✅ Интерактивный выбор | ✅ Из выбранной | ✅ Полный |

---

## Преимущества автообнаружения

✅ **Zero Configuration** — обнаружение без ввода данных вручную
✅ **Multi-Environment** — работает в любом окружении
✅ **Interactive** — выбор из нескольких установок
✅ **Profile Generation** — автоматическое создание профилей
✅ **Database Detection** — автоопределение БД из конфигурации KC
✅ **Version Detection** — определение текущей версии Keycloak

---

## Ограничения

⚠️ **Требует прав доступа**:
- Standalone: чтение `/opt`, `/usr/local`, systemd
- Docker: доступ к Docker socket
- Kubernetes: права `kubectl get` (deployments, statefulsets, configmaps)

⚠️ **Не обнаруживает**:
- Остановленные standalone установки (если не systemd)
- Keycloak в нестандартных путях (если не в `/opt`, `/usr/local`)
- Kubernetes установки без меток `keycloak` в названии

⚠️ **Обнаружение БД**:
- Работает только для Keycloak >= 17 (Quarkus-based)
- Для WildFly-based KC (16 и старше) требуется парсинг `standalone.xml` (не реализовано)

---

**Last Updated**: 2026-01-29
**Version**: 3.0.0-alpha
**Module**: keycloak_discovery.sh (468 lines)
