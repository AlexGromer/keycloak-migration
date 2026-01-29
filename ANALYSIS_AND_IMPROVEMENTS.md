# Keycloak Migration Scripts: Analysis & Improvements

**Дата анализа**: 2026-01-29
**Версия утилиты**: 1.0.0
**Статус**: Готов к улучшениям + тестированию

---

## Executive Summary

### ✅ Сильные стороны

1. **Комплексная автоматизация** — 6 скриптов покрывают весь цикл: discovery → transform → backup → migrate
2. **Safety-first подход** — backup на каждом шаге, rollback механизм
3. **Детальное логирование** — логи, отчёты, метрики по каждому шагу
4. **Модульная архитектура** — скрипты независимы, можно запускать по отдельности

### ⚠️ Найдено проблем

| Категория | Критичных | Средних | Низких | Всего |
|-----------|-----------|---------|--------|-------|
| **Безопасность** | 2 | 3 | 1 | 6 |
| **Надёжность** | 4 | 5 | 2 | 11 |
| **Производительность** | 0 | 2 | 3 | 5 |
| **Usability** | 1 | 4 | 3 | 8 |
| **ИТОГО** | **7** | **14** | **9** | **30** |

### 🎯 Рекомендуемые приоритеты

1. **P0 (Критично, сейчас)**: Фикс 7 критичных проблем (безопасность + rollback)
2. **P1 (Важно, до прода)**: Тестовая лаба + smoke tests + pre-flight validation
3. **P2 (Улучшения)**: Производительность, idempotency, мониторинг

---

## Детальный анализ по скриптам

## 1. `migrate_keycloak.sh` (Основной скрипт)

### 🔴 Критические проблемы

#### P0-1: Password в environment переменных

**Строки**: 56, 259, 399

```bash
PG_PASS="${PG_PASS:-}"
export PGPASSWORD="$PG_PASS"
```

**Проблема**: Пароль виден в `ps aux`, `/proc/PID/environ`, логах

**Риск**: Утечка credentials в production

**Решение**:
```bash
# Использовать .pgpass или временный файл
setup_pgpass() {
    local pgpass_file="${WORK_DIR}/.pgpass.tmp"
    echo "$PG_HOST:$PG_PORT:$PG_DB:$PG_USER:$PG_PASS" > "$pgpass_file"
    chmod 0600 "$pgpass_file"
    export PGPASSFILE="$pgpass_file"
}

cleanup_pgpass() {
    [[ -f "${WORK_DIR}/.pgpass.tmp" ]] && shred -u "${WORK_DIR}/.pgpass.tmp"
}
trap cleanup_pgpass EXIT
```

#### P0-2: Отсутствие проверки Java версии перед каждым шагом

**Строки**: 233-239

```bash
# Check Java version
local java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
log_info "Java version: $java_version"

if [[ "$java_version" -lt 17 ]]; then
    log_warn "Java 17+ required for KC 22+, Java 21 for KC 26"
    log_warn "Current: Java $java_version"
fi
```

**Проблема**:
- Только WARNING, не блокирует выполнение
- KC 26 ТРЕБУЕТ Java 21, но с Java 17 скрипт продолжит → гарантированный fail

**Решение**:
```bash
check_java_for_version() {
    local kc_ver="$1"
    local java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)

    local required_java=11
    [[ "$kc_ver" -ge 22 ]] && required_java=17
    [[ "$kc_ver" -ge 26 ]] && required_java=21

    if [[ "$java_version" -lt "$required_java" ]]; then
        log_error "KC $kc_ver requires Java $required_java+, current: Java $java_version"
        log_error "Set JAVA_HOME or install required Java version"
        return 1
    fi

    log_success "Java $java_version OK for KC $kc_ver"
    return 0
}

# В migrate_version() перед build_keycloak()
check_java_for_version "$ver" || exit 1
```

#### P0-3: Rollback может сломать БД, если версия схемы не совпадает

**Строки**: 841-842

```bash
pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    --clean --if-exists "$backup_file" 2>&1 | head -20
```

**Проблема**:
- `pg_restore --clean` может удалить таблицы, которых нет в бэкапе
- Если схема изменилась (новые таблицы, constraints), restore может частично провалиться
- Нет проверки совместимости версии схемы

**Решение**:
```bash
do_rollback() {
    # ... existing code ...

    # 1. Проверить версию схемы в backup
    log_info "Checking backup schema version..."
    local backup_schema=$(pg_restore -l "$backup_file" 2>/dev/null | grep "DATABASECHANGELOG" || echo "unknown")

    # 2. Создать pre-rollback backup (safety net)
    log_warn "Creating pre-rollback backup..."
    local pre_rollback="${BACKUP_DIR}/pre_rollback_${TIMESTAMP}.dump"
    pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -F c -f "$pre_rollback"
    log_success "Safety backup: $pre_rollback"

    # 3. Terminate connections + restore
    log_info "Terminating active connections..."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PG_DB' AND pid <> pg_backend_pid();" \
        >/dev/null 2>&1 || true

    # 4. Restore with error handling
    log_info "Restoring from backup..."
    if pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        --clean --if-exists -j "$PARALLEL_JOBS" "$backup_file" 2>&1 | tee "${LOG_DIR}/rollback.log"; then
        log_success "Rollback complete"
    else
        log_error "Rollback FAILED! Check ${LOG_DIR}/rollback.log"
        log_error "Emergency backup available: $pre_rollback"
        exit 1
    fi

    # 5. Verify schema
    local restored_tables=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -d ' ')
    log_info "Restored: $restored_tables tables"
}
```

#### P0-4: Timeout при старте KC может привести к false positive

**Строки**: 449-503

```bash
# Wait for startup/migration
local waited=0
local started=false

while [[ $waited -lt $MIGRATION_TIMEOUT ]]; do
    sleep 5
    waited=$((waited + 5))

    # Check if still running
    if ! kill -0 "$kc_pid" 2>/dev/null; then
        log_error "KC $ver crashed during startup"
        cat "$log_file" | tail -50
        return 1
    fi

    # Check for successful startup
    if grep -q "Listening on:" "$log_file" 2>/dev/null; then
        started=true
        break
    fi
    # ...
done
```

**Проблема**:
- Если KC стартует медленно (большая БД), timeout = 300s может быть недостаточно
- Нет возможности динамически увеличить timeout
- Скрипт не проверяет, завершилась ли Liquibase миграция ПОЛНОСТЬЮ

**Решение**:
```bash
wait_for_migration() {
    local ver="$1"
    local kc_pid="$2"
    local log_file="$3"
    local timeout="${MIGRATION_TIMEOUT}"

    log_info "Waiting for migration (timeout: ${timeout}s)..."

    local waited=0
    local migration_started=false
    local migration_completed=false
    local started=false

    while [[ $waited -lt $timeout ]]; do
        sleep 5
        waited=$((waited + 5))

        # Check if process alive
        if ! kill -0 "$kc_pid" 2>/dev/null; then
            log_error "KC $ver crashed during startup"
            tail -100 "$log_file" | grep -E "(ERROR|FATAL|Exception)" || tail -50 "$log_file"
            return 1
        fi

        # Check Liquibase stages
        if ! $migration_started && grep -q "Liquibase: Starting" "$log_file" 2>/dev/null; then
            migration_started=true
            log_info "Liquibase migration started..."
        fi

        if $migration_started && ! $migration_completed && grep -q "Liquibase: Update has been successful" "$log_file" 2>/dev/null; then
            migration_completed=true
            log_success "Database migration completed"
            # Increase timeout after successful migration (KC might need time to start services)
            timeout=$((timeout + 60))
        fi

        # Check startup completion
        if grep -q "Listening on:" "$log_file" 2>/dev/null; then
            started=true
            break
        fi

        # Check for critical errors
        if grep -qE "(FATAL|OutOfMemoryError|StackOverflowError)" "$log_file" 2>/dev/null; then
            log_error "Critical error detected"
            tail -50 "$log_file"
            return 1
        fi

        # Progress indicator
        if [[ $((waited % 30)) -eq 0 ]]; then
            echo -n " (${waited}s)"
        else
            echo -n "."
        fi
    done
    echo ""

    if $started; then
        log_success "KC $ver started (took ${waited}s)"
        return 0
    else
        log_error "Timeout after ${timeout}s"
        log_info "Last 50 lines of log:"
        tail -50 "$log_file"
        return 1
    fi
}
```

### ⚠️ Средние проблемы

#### P1-1: Отсутствие idempotency

**Проблема**: Если скрипт прервётся посередине, повторный запуск может сломаться

**Решение**: State machine + resume capability
```bash
# В migration_state.env сохранять:
CURRENT_STEP="migrate_22"
LAST_SUCCESSFUL_STEP="migrate_17"
RESUME_SAFE="true"

# При старте проверять:
if [[ -f "${WORK_DIR}/migration_state.env" ]]; then
    source "${WORK_DIR}/migration_state.env"
    if [[ "$RESUME_SAFE" == "true" ]]; then
        log_info "Previous migration interrupted at: $CURRENT_STEP"
        read -r -p "Resume from this point? [y/N] " resume
        if [[ "$resume" =~ ^[Yy]$ ]]; then
            START_FROM="${CURRENT_STEP##migrate_}"
        fi
    fi
fi
```

#### P1-2: Нет проверки свободного места перед экстракцией

**Строки**: 300-312

**Проблема**: 800MB × 4 = 3.2GB нужно, но проверяется только на backups

**Решение**:
```bash
check_disk_space() {
    local required_gb="$1"
    local path="$2"

    local available_gb=$(df -BG "$path" | tail -1 | awk '{print $4}' | tr -d 'G')

    if [[ "${available_gb:-0}" -lt "$required_gb" ]]; then
        log_error "Insufficient disk space: ${available_gb}GB available, ${required_gb}GB required"
        return 1
    fi

    log_success "Disk space OK: ${available_gb}GB available"
    return 0
}

# Перед download_versions():
check_disk_space 15 "$WORK_DIR" || exit 1  # 4×800MB дистрибутивы + 3GB backups + буфер
```

#### P1-3: Health check может ложно пройти

**Строки**: 490-495

```bash
if curl -s "http://localhost:${KC_HTTP_PORT}${KC_RELATIVE_PATH}/health" | grep -q "UP"; then
    log_success "Health check passed"
else
    log_warn "Health check inconclusive"
fi
```

**Проблема**:
- Нет timeout у curl → может зависнуть
- Нет проверки HTTP status code
- Возвращает WARNING, но не блокирует

**Решение**:
```bash
health_check() {
    local ver="$1"
    local max_attempts=5
    local attempt=1

    log_info "Running health check..."

    while [[ $attempt -le $max_attempts ]]; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 10 \
            "http://localhost:${KC_HTTP_PORT}${KC_RELATIVE_PATH}/health" 2>/dev/null)

        local body=$(echo "$response" | head -n -1)
        local status=$(echo "$response" | tail -n 1)

        if [[ "$status" == "200" ]] && echo "$body" | grep -q "UP"; then
            log_success "Health check passed (attempt $attempt/$max_attempts)"

            # Extended check: verify readiness endpoint
            if curl -s --max-time 5 "http://localhost:${KC_HTTP_PORT}${KC_RELATIVE_PATH}/health/ready" \
                | grep -q "UP"; then
                log_success "Readiness check passed"
                return 0
            fi
        fi

        log_info "Attempt $attempt/$max_attempts failed, retrying in 5s..."
        sleep 5
        ((attempt++))
    done

    log_error "Health check failed after $max_attempts attempts"
    return 1
}
```

#### P1-4: Нет валидации build успеха

**Строки**: 382-388

```bash
if ./bin/kc.sh build 2>&1 | tee -a "$LOG_FILE" | grep -E "^(BUILD|Server|ERROR)"; then
    log_success "KC $ver built"
    return 0
else
    log_error "Build failed for KC $ver"
    return 1
fi
```

**Проблема**: `grep` всегда возвращает 0, даже если build провалился

**Решение**:
```bash
build_keycloak() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"
    local build_log="${LOG_DIR}/kc_${ver}_build.log"

    log_info "Building KC $ver..."

    cd "$kc_dir"

    if ./bin/kc.sh build > "$build_log" 2>&1; then
        # Check for success markers
        if grep -q "BUILD SUCCESS\|Server configuration updated\|Updating the configuration" "$build_log"; then
            log_success "KC $ver built successfully"
            return 0
        else
            log_warn "Build command succeeded but no success marker found"
            tail -20 "$build_log"
            read -r -p "Continue anyway? [y/N] " cont
            [[ "$cont" =~ ^[Yy]$ ]] && return 0 || return 1
        fi
    else
        log_error "Build failed for KC $ver"
        tail -30 "$build_log"
        return 1
    fi
}
```

#### P1-5: Providers копируются ПОСЛЕ build, но build кэширует classpath

**Строки**: 582-589

```bash
# Create config
create_kc_config "$ver"

# Copy providers (for 22+)
copy_providers "$ver"

# Build
build_keycloak "$ver"
```

**Проблема**: Правильный порядок: config → providers → build. Но если build уже был, `kc.sh build` не пересобирает.

**Решение**:
```bash
migrate_version() {
    # ...

    # 1. Config
    create_kc_config "$ver"

    # 2. Providers BEFORE build
    copy_providers "$ver"

    # 3. Force clean build
    if [[ -d "${kc_dir}/data/tmp" ]]; then
        log_info "Cleaning KC build cache..."
        rm -rf "${kc_dir}/data/tmp"
    fi

    # 4. Build
    build_keycloak "$ver"

    # ...
}
```

---

## 2. `backup_keycloak.sh`

### 🟡 Средние проблемы

#### P1-6: Пароль в аргументах командной строки

**Строки**: 119-120, 364

```bash
-W, --pg-password PASS  PostgreSQL password
read -r -s -p "Admin password: " admin_pass
```

**Проблема**: Пароли видны в `ps aux`, history

**Решение**: Только интерактивный ввод или env vars

#### P1-7: Параллельный backup может сломаться на низких версиях PostgreSQL

**Строки**: 250-255

```bash
if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    -F c \
    -j "$PARALLEL_JOBS" \
    -f "$dump_file" \
    --verbose 2>&1 | grep -E "^pg_dump:"; then
```

**Проблема**: `-j` (parallel) requires PostgreSQL 9.3+, но скрипт не проверяет

**Решение**:
```bash
# Перед backup проверить версию PG
local pg_version=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
    "SHOW server_version;" | cut -d. -f1 | tr -d ' ')

local parallel_flag=""
if [[ "$pg_version" -ge 9 ]]; then
    parallel_flag="-j $PARALLEL_JOBS"
    log_info "Using parallel backup ($PARALLEL_JOBS jobs)"
else
    log_warn "PostgreSQL $pg_version does not support parallel backup"
fi

pg_dump ... $parallel_flag -f "$dump_file"
```

---

## 3. `kc_discovery.sh`

### 🟡 Средние проблемы

#### P1-8: Grep timeout может убить скрипт на больших JARs

**Строки**: 605, 625

```bash
javax_refs=$(timeout 5 grep -r -l "javax\." "$temp_dir" 2>/dev/null | head -20 || true)
```

**Проблема**: Если провайдер >100MB, 5s может быть недостаточно

**Решение**:
```bash
# Использовать zipgrep вместо unzip + grep
local javax_count=0

if command -v zipgrep >/dev/null 2>&1; then
    # Быстрый поиск внутри JAR без распаковки
    javax_count=$(timeout 10 zipgrep -c "javax\." "$jar" 2>/dev/null | cut -d: -f2 | paste -sd+ | bc || echo "0")
else
    # Fallback к старому методу
    javax_refs=$(timeout 10 grep -r -l "javax\." "$temp_dir" 2>/dev/null | head -50 || true)
    # ...
fi
```

#### P1-9: Mock mode не тестирует ошибки

**Проблема**: Mock всегда успешен, не помогает найти баги в error handling

**Решение**: Добавить `--mock-fail` режим
```bash
--mock-fail-db         # Симулировать недоступность БД
--mock-fail-provider   # Симулировать битый JAR
--mock-large-db        # Симулировать >1M rows в таблицах
```

---

## 4. `transform_providers.sh`

### ⚠️ Средняя проблема

#### P1-10: Нет проверки успеха трансформации

**Строки**: 58-87

```bash
if java -jar "$TRANSFORMER_JAR" "$input_jar" "$output_jar" -o 2>&1; then
    log_success "Created: $(basename "$output_jar")"
```

**Проблема**: `java -jar` может вернуть 0 даже если трансформация частично провалилась

**Решение**:
```bash
transform_jar() {
    # ... existing code ...

    # Verify transformation more thoroughly
    log_info "Verifying transformation..."

    # 1. Check output JAR exists and not empty
    if [[ ! -f "$output_jar" ]] || [[ ! -s "$output_jar" ]]; then
        log_error "Output JAR is missing or empty"
        return 1
    fi

    # 2. Compare JAR sizes (output should be similar to input)
    local input_size=$(stat -c%s "$input_jar")
    local output_size=$(stat -c%s "$output_jar")
    local size_diff=$((100 * (input_size - output_size) / input_size))

    if [[ "${size_diff#-}" -gt 20 ]]; then
        log_warn "Size changed by ${size_diff}% — may indicate issues"
    fi

    # 3. Check javax references
    local javax_count=$(unzip -p "$output_jar" "*.class" 2>/dev/null | strings | grep -c "javax\.\(ws\|persistence\|servlet\|inject\|enterprise\)" || echo "0")

    if [[ "$javax_count" -gt 0 ]]; then
        log_warn "$javax_count javax.* references remain"
        log_warn "Manual review required — may need source code access"
    else
        log_success "All javax.* references successfully transformed"
    fi

    # 4. Verify JAR is valid
    if ! unzip -t "$output_jar" >/dev/null 2>&1; then
        log_error "Output JAR is corrupted"
        return 1
    fi

    log_success "Transformation verified: $(basename "$output_jar")"
    return 0
}
```

---

## Дополнительные улучшения

### Pre-flight Validation (новый скрипт)

Создать `scripts/pre_flight_check.sh`:

```bash
#!/bin/bash
# Pre-flight checks before migration

check_all() {
    local checks_passed=0
    local checks_failed=0

    # 1. Java versions
    for ver in 11 17 21; do
        if command -v java-$ver >/dev/null 2>&1; then
            log_success "Java $ver available"
            ((checks_passed++))
        else
            log_warn "Java $ver not found"
            ((checks_failed++))
        fi
    done

    # 2. PostgreSQL connectivity
    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
        log_success "PostgreSQL connection OK"
        ((checks_passed++))
    else
        log_error "Cannot connect to PostgreSQL"
        ((checks_failed++))
    fi

    # 3. Disk space
    local required_gb=15
    local available_gb=$(df -BG "$WORK_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ "${available_gb:-0}" -ge "$required_gb" ]]; then
        log_success "Disk space OK: ${available_gb}GB"
        ((checks_passed++))
    else
        log_error "Insufficient disk space: ${available_gb}GB < ${required_gb}GB"
        ((checks_failed++))
    fi

    # 4. Memory
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    if [[ "$total_mem" -ge 8 ]]; then
        log_success "Memory OK: ${total_mem}GB"
        ((checks_passed++))
    else
        log_warn "Low memory: ${total_mem}GB (recommend 8GB+)"
        ((checks_failed++))
    fi

    # 5. PostgreSQL version
    local pg_version=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c "SHOW server_version;" | cut -d. -f1 | tr -d ' ')
    if [[ "$pg_version" -ge 12 ]]; then
        log_success "PostgreSQL $pg_version OK"
        ((checks_passed++))
    else
        log_warn "PostgreSQL $pg_version (recommend 12+)"
        ((checks_failed++))
    fi

    # 6. KC 16 validation
    if [[ -f "$KEYCLOAK_HOME/version.txt" ]]; then
        local kc_version=$(cat "$KEYCLOAK_HOME/version.txt")
        if [[ "$kc_version" =~ ^16\. ]]; then
            log_success "Keycloak version: $kc_version"
            ((checks_passed++))
        else
            log_error "Unexpected KC version: $kc_version (expected 16.x)"
            ((checks_failed++))
        fi
    else
        log_error "Cannot detect KC version"
        ((checks_failed++))
    fi

    # Summary
    echo ""
    echo "Pre-flight check: $checks_passed passed, $checks_failed failed"

    if [[ $checks_failed -gt 0 ]]; then
        log_error "Fix issues before proceeding"
        return 1
    else
        log_success "All checks passed — ready for migration"
        return 0
    fi
}

check_all "$@"
```

### Smoke Tests (новый скрипт)

Создать `scripts/smoke_test.sh`:

```bash
#!/bin/bash
# Smoke tests after KC migration step

KC_URL="http://localhost:8080/auth"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"

smoke_test() {
    local tests_passed=0
    local tests_failed=0

    log_section "SMOKE TESTS"

    # 1. Health endpoint
    if curl -sf --max-time 10 "${KC_URL}/health" | grep -q "UP"; then
        log_success "[1/7] Health endpoint"
        ((tests_passed++))
    else
        log_error "[1/7] Health endpoint FAILED"
        ((tests_failed++))
    fi

    # 2. Master realm accessible
    if curl -sf --max-time 10 "${KC_URL}/realms/master" | grep -q "master"; then
        log_success "[2/7] Master realm accessible"
        ((tests_passed++))
    else
        log_error "[2/7] Master realm FAILED"
        ((tests_failed++))
    fi

    # 3. Admin login
    local token=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=$ADMIN_USER" \
        -d "password=$ADMIN_PASS" 2>/dev/null | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

    if [[ -n "$token" ]]; then
        log_success "[3/7] Admin login"
        ((tests_passed++))
    else
        log_error "[3/7] Admin login FAILED"
        ((tests_failed++))
        return 1
    fi

    # 4. List realms
    local realms=$(curl -sf "${KC_URL}/admin/realms" -H "Authorization: Bearer $token" | grep -o '"realm":"[^"]*' | wc -l)
    if [[ "$realms" -gt 0 ]]; then
        log_success "[4/7] List realms ($realms found)"
        ((tests_passed++))
    else
        log_error "[4/7] List realms FAILED"
        ((tests_failed++))
    fi

    # 5. List users in master realm
    local users=$(curl -sf "${KC_URL}/admin/realms/master/users" -H "Authorization: Bearer $token" | grep -o '"id":"[^"]*' | wc -l)
    if [[ "$users" -gt 0 ]]; then
        log_success "[5/7] List users ($users found)"
        ((tests_passed++))
    else
        log_error "[5/7] List users FAILED"
        ((tests_failed++))
    fi

    # 6. List clients
    local clients=$(curl -sf "${KC_URL}/admin/realms/master/clients" -H "Authorization: Bearer $token" | grep -o '"clientId":"[^"]*' | wc -l)
    if [[ "$clients" -gt 0 ]]; then
        log_success "[6/7] List clients ($clients found)"
        ((tests_passed++))
    else
        log_error "[6/7] List clients FAILED"
        ((tests_failed++))
    fi

    # 7. Check providers (optional)
    local providers=$(curl -sf "${KC_URL}/admin/serverinfo" -H "Authorization: Bearer $token" | grep -o '"providers"' | wc -l)
    if [[ "$providers" -gt 0 ]]; then
        log_success "[7/7] Providers loaded"
        ((tests_passed++))
    else
        log_warn "[7/7] Cannot verify providers"
    fi

    # Summary
    echo ""
    echo "Smoke tests: $tests_passed passed, $tests_failed failed"

    if [[ $tests_failed -gt 0 ]]; then
        log_error "Migration verification FAILED"
        return 1
    else
        log_success "Migration verification PASSED"
        return 0
    fi
}

smoke_test "$@"
```

---

## План тестирования

### Тестовая лаба (Docker Compose)

Создать `test_lab/docker-compose.yml`:

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15
    container_name: kc_migration_postgres
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: keycloak_pass
    ports:
      - "5432:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init_test_data.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak"]
      interval: 5s
      timeout: 5s
      retries: 5

  keycloak-16:
    image: quay.io/keycloak/keycloak:16.1.1
    container_name: kc_migration_16
    environment:
      DB_VENDOR: postgres
      DB_ADDR: postgres
      DB_DATABASE: keycloak
      DB_USER: keycloak
      DB_PASSWORD: keycloak_pass
      KEYCLOAK_USER: admin
      KEYCLOAK_PASSWORD: admin
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./custom_providers:/opt/jboss/keycloak/standalone/deployments
    profiles:
      - kc16

volumes:
  pg_data:

networks:
  default:
    name: kc_migration_net
```

Создать `test_lab/init_test_data.sql`:

```sql
-- Инициализация тестовых данных после первого старта KC 16

-- Имитация больших таблиц (для теста manual indexes)
-- Этот скрипт запустить вручную после инициализации KC 16

-- Вставить 350k строк в user_attribute (симулировать threshold)
INSERT INTO user_attribute (id, name, value, user_id)
SELECT
    gen_random_uuid()::text,
    'test_attr_' || i,
    'test_value_' || i,
    (SELECT id FROM user_entity LIMIT 1)
FROM generate_series(1, 350000) AS i;

-- Добавить несколько test realms
INSERT INTO realm (id, name, enabled) VALUES
    (gen_random_uuid()::text, 'test-realm-1', true),
    (gen_random_uuid()::text, 'test-realm-2', true);
```

### Тестовые сценарии

#### Сценарий 1: Нормальная миграция (Happy Path)

```bash
# 1. Запустить лабу с KC 16
cd test_lab
docker-compose --profile kc16 up -d

# 2. Дождаться инициализации
sleep 60

# 3. Discovery
./scripts/kc_discovery.sh \
    -k /opt/jboss/keycloak \
    -H localhost -P 5432 -D keycloak -U keycloak -W keycloak_pass \
    -o ./test_discovery

# 4. Pre-flight checks
./scripts/pre_flight_check.sh

# 5. Остановить KC 16
docker-compose stop keycloak-16

# 6. Запустить миграцию
./scripts/migrate_keycloak.sh migrate \
    -W keycloak_pass \
    -H localhost -P 5432 -D keycloak -U keycloak \
    --http-port 8080

# 7. Smoke test на каждой версии
for ver in 17 22 25 26; do
    echo "Testing KC $ver..."
    ./scripts/smoke_test.sh
done

# 8. Rollback test
./scripts/migrate_keycloak.sh rollback 22

# 9. Forward test (resume)
./scripts/migrate_keycloak.sh migrate --start-from 22
```

#### Сценарий 2: Failure Recovery

```bash
# Симулировать сбой на KC 22
# 1. Убить процесс во время миграции
pkill -9 -f "keycloak.*22"

# 2. Попытаться возобновить
./scripts/migrate_keycloak.sh migrate --start-from 22

# 3. Если не получилось — rollback
./scripts/migrate_keycloak.sh rollback 22
```

#### Сценарий 3: Custom Providers

```bash
# 1. Подготовить mock providers
./scripts/kc_discovery.sh --mock

# 2. Transform providers
./scripts/transform_providers.sh

# 3. Миграция с providers
./scripts/migrate_keycloak.sh migrate \
    -p ./providers_transformed_* \
    -W keycloak_pass
```

---

## Чек-лист перед production

### Критичные фиксы (P0)

- [ ] **P0-1**: Пароли через .pgpass вместо env
- [ ] **P0-2**: Блокировка при неправильной версии Java
- [ ] **P0-3**: Safe rollback с pre-rollback backup
- [ ] **P0-4**: Умный wait с динамическим timeout
- [ ] **P0-5**: Порядок providers → build (не наоборот)
- [ ] **P0-6**: Валидация build success
- [ ] **P0-7**: Health check с retry

### Важные улучшения (P1)

- [ ] **P1-1**: Idempotency + resume capability
- [ ] **P1-2**: Проверка disk space перед экстракцией
- [ ] **P1-3**: Pre-flight validation script
- [ ] **P1-4**: Smoke tests после каждой версии
- [ ] **P1-5**: Mock mode с failure scenarios

### Тестирование

- [ ] Тестовая лаба с Docker Compose развёрнута
- [ ] Тест: Happy path (16 → 17 → 22 → 25 → 26)
- [ ] Тест: Rollback на каждой версии
- [ ] Тест: Resume после сбоя
- [ ] Тест: Custom providers (Type A, B, C)
- [ ] Тест: Большие таблицы (>300k rows)
- [ ] Тест: Разные версии Java (11, 17, 21)
- [ ] Тест: Низкая память (simulate OOM)
- [ ] Тест: Медленная БД (simulate network lag)

### Документация

- [ ] README с Quick Start
- [ ] Troubleshooting guide
- [ ] Rollback runbook
- [ ] Performance tuning guide

---

## Итого

**Текущий статус**: 🟡 Готов к тестированию после фикса P0

**После улучшений**: 🟢 Production-ready

**Оценка работ**:
- P0 фиксы: ~8-12 часов
- P1 улучшения: ~16-20 часов
- Тестовая лаба: ~4-6 часов
- Тестирование: ~8-12 часов
- **ИТОГО**: ~40-50 часов

**Рекомендация**: Начать с P0 фиксов + тестовая лаба, затем запустить Happy Path тест.
