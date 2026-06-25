# Статический анализ keycloak-zpe-migration

**Дата:** 2026-02-11
**Проект:** /opt/kk_migration/
**Объём:** ~35 скриптов, ~8000 строк Bash
**Инструменты:** shellcheck, ручной анализ функций, source-chain трассировка, логический анализ

---

## СВОДКА

| Категория | CRITICAL | HIGH | MEDIUM | LOW | INFO |
|-----------|----------|------|--------|-----|------|
| Синтаксис (shellcheck) | 0 | 0 | 0 | 333 | — |
| Синтаксис (shellcheck errors) | 4 | 0 | 0 | 0 | — |
| Неопределённые функции | 2 | 0 | 0 | 0 | — |
| Коллизии readonly констант | 7 | 0 | 0 | 0 | — |
| Логические ошибки | 0 | 7 | 8 | 8 | — |
| Неиспользуемые функции | 0 | 0 | 0 | 0 | ~70+ |
| Неиспользуемые библиотеки | 0 | 0 | 0 | 0 | 3 |
| Source-chain проблемы | 0 | 1 | 1 | 3 | — |
| **ИТОГО** | **13** | **8** | **9** | **344** | **73+** |

---

## 1. CRITICAL (13 проблем — ломают работу)

### 1.1 Коллизия readonly констант (7 модулей)

**Проблема:** 7 библиотек определяют `readonly EXIT_SUCCESS=0` и другие одноимённые константы. При одновременном sourcing (а `migrate_keycloak_v3.sh` грузит их все) второе `readonly` объявление КРАШИТ скрипт:
```
bash: EXIT_SUCCESS: readonly variable
```

**Затронутые файлы:**
| Файл | Строки |
|------|--------|
| `scripts/lib/preflight_checks.sh` | 24-34 |
| `scripts/lib/security_checks.sh` | 23-26 |
| `scripts/lib/audit_logger_v2.sh` | 35-37 |
| `scripts/lib/input_validator.sh` | 19-21 |
| `scripts/lib/secrets_manager.sh` | 23-26 |
| `scripts/lib/k8s_secrets.sh` | 27-30 |
| `scripts/lib/vault_integration.sh` | 29-32 |

**Исправление:** Добавить guard:
```bash
[[ -v EXIT_SUCCESS ]] || readonly EXIT_SUCCESS=0
```
Или namespace: `PREFLIGHT_EXIT_SUCCESS`, `SEC_EXIT_SUCCESS`, и т.д.

---

### 1.2 Вызов несуществующих функций (2 функции)

**`audit_migration_end`** — вызывается в `migrate_keycloak_v3.sh:1619`, но НЕ определена ни в одном sourced файле.
- `audit_logger.sh` определяет `audit_migration_end()`, но `audit_logger_v2.sh` перезаписывает `audit_log()` с другой сигнатурой — v1 функция сломается
- `audit_logger_v2.sh` определяет `audit_migration_complete()` (не `_end`)

**`audit_migration_step`** — вызывается в `migrate_keycloak_v3.sh:1534`, определена только в `audit_logger.sh` (v1), которая использует v1 `audit_log()` с 4 аргументами. Но v2 перезаписывает `audit_log()` на 6-аргументную версию.

**Исправление:**
- Заменить `audit_migration_end` на `audit_migration_complete` (v2)
- Либо переписать v1-only функции под v2 сигнатуру `audit_log()`
- Либо прекратить source `audit_logger.sh` и портировать все функции в v2

---

### 1.3 pg_dump -j с несовместимым форматом

**Файл:** `scripts/lib/database_adapter.sh:223`
**Проблема:** Флаг `-j` (parallel) добавляется к `pg_dump -Fc` (custom format). PostgreSQL поддерживает `-j` ТОЛЬКО с directory format (`-Fd`). Результат: `pg_dump` упадёт с ошибкой.

**Исправление:** При `parallel_jobs > 1` использовать `-Fd` вместо `-Fc`, или убрать `-j` для custom format.

---

### 1.4 shellcheck error: `local` вне функции

**Файл:** `tests/test_rate_limiter.sh:119-125`
**Проблема:** 4 оператора `local` используются вне функции (на верхнем уровне скрипта). Это ошибка синтаксиса bash.

---

## 2. HIGH (8 проблем — серьёзные баги)

### 2.1 `audit_migration_start` — перепутаны аргументы
**Файл:** `migrate_keycloak_v3.sh:1520`
**Вызов:** `audit_migration_start "${PROFILE_NAME:-unknown}" "$current_version" "$target_version"`
**Сигнатура v2:** `audit_migration_start(source_db, target_db, profile)` — profile должен быть 3-м, а он 1-й.

### 2.2 WORK_DIR может не существовать при LOG_FILE
**Файл:** `migrate_keycloak_v3.sh:50`
**Проблема:** `LOG_FILE` использует `$WORK_DIR` который ещё не создан. `tee -a "$LOG_FILE"` упадёт.
**Исправление:** `mkdir -p "$WORK_DIR"` сразу после определения.

### 2.3 `"$build_cmd"` — строка как единая команда
**Файл:** `migrate_keycloak_v3.sh:854`
**Проблема:** `"$build_cmd"` пытается выполнить `/path/to/kc.sh build` как одну команду (с пробелом). Bash будет искать файл буквально с именем `kc.sh build`.
**Исправление:** Убрать кавычки `$build_cmd` или использовать массив.

### 2.4 Quoting: dump_opts и restore_opts как строки
**Файл:** `database_adapter.sh:219-228, 372-379`
**Проблема:** `$dump_opts` и `$restore_opts` — строки, используются unquoted. Пробелы в путях/именах сломают аргументы.
**Исправление:** Использовать массивы `local -a dump_opts=(...)`.

### 2.5 $? проверяется после if (всегда 0)
**Файл:** `security_checks.sh:412-434`
**Проблема:** `$?` проверяется внутри `else` ветки, где он всегда = 0 (результат if-теста, не функции).
**Исправление:** `local rc=0; func || rc=$?; if [[ $rc -eq 0 ]]; ...`

### 2.6 Bash арифметика с float
**Файл:** `db_optimizations.sh:31`
**Проблема:** `$(( db_size_gb / 2 ))` — `db_size_gb` это float (напр. "5.25"), bash arithmetic не поддерживает дробные числа.
**Исправление:** `optimal_jobs=$(printf "%.0f" "$(echo "$db_size_gb / 2" | bc -l)")`

### 2.7 Canary: валидация ДО наблюдения
**Файл:** `canary.sh:90-92`
**Проблема:** Step 3 (validate) выполняется до Step 4 (sleep). Canary может деградировать за время sleep без обнаружения.
**Исправление:** Запускать валидацию периодически во время sleep.

### 2.8 `((failure_count++))` с set -e
**Файл:** `rate_limiter.sh:268`
**Проблема:** `((0++))` возвращает exit code 1. С `set -e` скрипт упадёт.
**Исправление:** `failure_count=$((failure_count + 1))`

---

## 3. MEDIUM (9 проблем)

| # | Файл:Строка | Проблема |
|---|-------------|----------|
| 3.1 | `migrate_keycloak_v3.sh:304` | `get_checkpoint()` без `else echo ""` — с `set -e` может abort |
| 3.2 | `migrate_keycloak_v3.sh:277` | `sed -i` с `$value` — спецсимволы `|`, `&`, `\` ломают sed |
| 3.3 | `migrate_keycloak_v3.sh:1999` | `--profile` без значения съедает следующий флаг |
| 3.4 | `distribution_handler.sh:443` | `dist_container` failure не останавливает `dist_container_update` |
| 3.5 | `profile_manager.sh:40` | `parse_yaml_value` для неуникальных ключей возвращает первое совпадение |
| 3.6 | `profile_manager.sh:50` | Точки в section name интерпретируются как regex wildcard в sed |
| 3.7 | `prometheus_exporter.sh:78` | `sed` заменяет ВСЕ metric lines с тем же именем (разные labels теряются) |
| 3.8 | `multi_tenant.sh:376-377` | `$(cmd1 || cmd2)` fallback не работает (cmd1 всегда exit 0 с пустым output) |
| 3.9 | `secrets_manager.sh:538,564,574` | `$AZURE_VAULT_NAME` без `:-` default — crash с `set -u` |

---

## 4. АРХИТЕКТУРНЫЕ ПРОБЛЕМЫ

### 4.1 Неявная зависимость на log_*() (HIGH)

ВСЕ 14 библиотек в `scripts/lib/` вызывают `log_info()`, `log_error()`, `log_warn()` и т.д. (638 вызовов), но эти функции определены ТОЛЬКО в вызывающих скриптах (не в библиотеках). Нет `lib/logging.sh`.

**Рекомендация:** Создать `scripts/lib/logging.sh` и sourcing его первым.

### 4.2 Неиспользуемые целые библиотеки (3 файла)

| Библиотека | Функций | Статус |
|------------|---------|--------|
| `k8s_secrets.sh` | 20+ | Никогда не source |
| `vault_integration.sh` | 20+ | Никогда не source |
| `secrets_manager.sh` | 15+ | Source, но 0 вызовов |

### 4.3 ~70+ orphan-функций

Определены, но никогда не вызываются извне своего файла. Основной "вклад": `audit_logger_v2.sh` (12 orphans), `k8s_secrets.sh` (20+), `vault_integration.sh` (16+), `secrets_manager.sh` (15+).

### 4.4 Множественный re-sourcing без guard

- `db_optimizations.sh` — sourced до 5 раз внутри `database_adapter.sh`
- `validation.sh`, `traffic_switcher.sh` — re-sourced в `blue_green.sh` и `canary.sh`
- `database_adapter.sh`, `deployment_adapter.sh` — двойной source через `keycloak_discovery.sh`

**Рекомендация:** Добавить source guard:
```bash
[[ "${_DB_OPTIMIZATIONS_LOADED:-}" == "true" ]] && return 0
_DB_OPTIMIZATIONS_LOADED=true
```

### 4.5 Несовместимость audit_logger v1/v2

Обе версии sourced в `migrate_keycloak_v3.sh`. v2 перезаписывает `audit_log()` с другой сигнатурой (6 vs 4 аргумента). v1-only функции (`audit_migration_step`, `audit_backup`, `audit_rollback`, `audit_health_check`, `audit_migration_end`) вызывают `audit_log()` с v1 сигнатурой — на runtime будет вызвана v2 версия с неправильными аргументами.

---

## 5. SHELLCHECK СВОДКА (333 warnings)

| Код | Описание | Количество |
|-----|----------|-----------|
| SC2155 | Declare and assign separately (маскирует return value) | 260 |
| SC2034 | Unused variable | 27 |
| SC1090 | Can't follow non-constant source | 5 |
| SC2168 | `local` outside function | 4 |
| SC2076 | Remove quotes from =~ right side | 2 |
| SC2207 | Prefer mapfile or read -a | 2 |
| SC2178 | Array used as string | 1 |
| SC2128 | Array expanded without index | 1 |
| SC2188 | Redirect without command | 1 |
| SC2087 | Quote EOF in heredoc | 1 |

Наиболее частая проблема — SC2155: `local var=$(cmd)` маскирует exit code `cmd`. Нужно разделять:
```bash
local var
var=$(cmd)
```

---

## 6. SOURCE-CHAIN ГРАФ

```
migrate_keycloak_v3.sh
  ├── database_adapter.sh
  │     └── (lazy) db_optimizations.sh  [до 5x!]
  ├── deployment_adapter.sh
  ├── profile_manager.sh
  ├── keycloak_discovery.sh
  │     ├── deployment_adapter.sh  [ДУБЛЬ]
  │     └── database_adapter.sh    [ДУБЛЬ]
  ├── distribution_handler.sh
  ├── audit_logger.sh          ← v1
  ├── prometheus_exporter.sh
  ├── multi_tenant.sh
  ├── (conditional) preflight_checks.sh
  ├── (conditional) rate_limiter.sh
  ├── (conditional) backup_rotation.sh
  ├── (conditional) security_checks.sh
  ├── (conditional) input_validator.sh
  ├── (conditional) secrets_manager.sh    [ФАЙЛ ОТСУТСТВУЕТ]
  ├── (conditional) audit_logger_v2.sh    ← v2 перезаписывает v1
  ├── (lazy) blue_green.sh
  │     ├── validation.sh
  │     └── traffic_switcher.sh
  └── (lazy) canary.sh
        ├── traffic_switcher.sh
        └── validation.sh

IMPLICIT: ALL lib/*.sh → log_info/error/warn/success/section() (не в библиотеке!)
```

---

## 7. ПРИОРИТЕТЫ ИСПРАВЛЕНИЯ

### Tier 1: Блокеры (исправить немедленно)
1. Readonly constant collisions (7 файлов) — CRASH при runtime
2. Undefined `audit_migration_end`/`audit_migration_step` — CRASH при миграции
3. pg_dump `-j` с `-Fc` — CRASH при backup
4. `local` вне функции в test_rate_limiter.sh

### Tier 2: Серьёзные баги (исправить до release)
5. audit_migration_start — перепутаны аргументы
6. WORK_DIR не создан до LOG_FILE
7. "$build_cmd" quoting
8. dump_opts/restore_opts quoting
9. $? после if
10. Float в bash arithmetic
11. Canary validation timing
12. ((counter++)) с set -e

### Tier 3: Архитектура (спринт рефакторинга)
13. Создать lib/logging.sh
14. Удалить или интегрировать 3 unused библиотеки
15. Source guards для предотвращения re-sourcing
16. Резолвить audit_logger v1/v2 несовместимость
17. Очистить ~70 orphan-функций
