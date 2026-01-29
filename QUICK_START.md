# Keycloak Migration 16→26: Quick Start

## Что уже готово

✅ **6 скриптов**:
- `kc_discovery.sh` — автообнаружение KC 16, providers, БД
- `transform_providers.sh` — javax → jakarta трансформация
- `backup_keycloak.sh` — backup/restore PostgreSQL
- `migrate_keycloak.sh` — полная миграция 16→17→22→25→26
- `smoke_test.sh` — проверка функциональности после миграции
- `pre_flight_check.sh` — валидация окружения перед стартом

✅ **Тестовая лаба** (Docker Compose):
- PostgreSQL 15
- Keycloak 16.1.1
- PGAdmin (опционально)

✅ **Документация**:
- `ANALYSIS_AND_IMPROVEMENTS.md` — детальный анализ + 30 найденных проблем
- `test_lab/README.md` — руководство по тестированию

---

## Быстрый тест (5 минут)

### 1. Запустить тестовую лабу

```bash
cd /opt/kk_migration/test_lab
docker-compose --profile kc16 up -d

# Дождаться готовности (2 минуты)
docker-compose logs -f keycloak-16 | grep "Admin console"
```

### 2. Pre-flight проверка

```bash
cd /opt/kk_migration

# Проверить окружение
./scripts/pre_flight_check.sh

# Ожидаемый результат: "✓ ALL CHECKS PASSED"
```

### 3. Discovery (mock режим)

```bash
# Быстрый тест с mock данными
./scripts/kc_discovery.sh --mock

# Посмотреть отчёт
cat discovery_*_mock/DISCOVERY_REPORT.md
```

### 4. Smoke test (на работающем KC 16)

```bash
export KC_URL="http://localhost:8080/auth"
export ADMIN_USER="admin"
export ADMIN_PASS="admin"

./scripts/smoke_test.sh

# Ожидаемый результат: "✓ ALL TESTS PASSED" (7/7)
```

---

## Полная миграция (30-40 минут)

### Подготовка

```bash
# 1. Остановить KC 16
docker-compose stop keycloak-16

# 2. Discovery (real mode)
./scripts/kc_discovery.sh \
    -k /path/to/keycloak-16 \
    -H localhost -P 5432 -D keycloak -U keycloak -W keycloak_pass

# 3. Трансформация providers (если есть Type B/C)
./scripts/transform_providers.sh
```

### Миграция

```bash
# Запустить полную миграцию
./scripts/migrate_keycloak.sh migrate \
    -H localhost -P 5432 -D keycloak -U keycloak -W keycloak_pass \
    --http-port 8080 \
    --timeout 600

# Или пошагово с тестами
for ver in 17 22 25 26; do
    echo "=== Migrating to KC $ver ==="
    ./scripts/migrate_keycloak.sh migrate-step $ver -W keycloak_pass

    # Проверка после каждого шага
    ./scripts/smoke_test.sh

    read -p "Continue to next version? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || break
done
```

### Rollback (если что-то пошло не так)

```bash
# Откатиться к KC 17
./scripts/migrate_keycloak.sh rollback 17

# Проверить
./scripts/smoke_test.sh
```

---

## Что нужно улучшить перед production

### Критичные фиксы (P0) — 8-12 часов

См. `ANALYSIS_AND_IMPROVEMENTS.md` → "Критические проблемы":

1. **P0-1**: Пароли через `.pgpass` вместо environment
2. **P0-2**: Блокировка при неправильной Java версии
3. **P0-3**: Safe rollback с pre-rollback backup
4. **P0-4**: Умный wait с динамическим timeout

### Рекомендуемые улучшения (P1) — 16-20 часов

- Idempotency (возможность resume после сбоя)
- Проверка disk space перед экстракцией
- Extended health checks с retry
- Mock failure scenarios для тестирования

---

## Структура проекта

```
/opt/kk_migration/
├── scripts/
│   ├── kc_discovery.sh           ✅ Готов
│   ├── transform_providers.sh    ✅ Готов
│   ├── backup_keycloak.sh        ✅ Готов
│   ├── migrate_keycloak.sh       ✅ Готов (нужны улучшения)
│   ├── smoke_test.sh             ✅ Готов (новый)
│   └── pre_flight_check.sh       ✅ Готов (новый)
│
├── test_lab/
│   ├── docker-compose.yml        ✅ Готов
│   ├── README.md                 ✅ Готов
│   └── custom_providers/         📁 Для тестовых providers
│
├── migration_workspace/          📁 Создаётся при миграции
│   ├── staging/                  ← KC 17, 22, 25, 26
│   ├── backups/                  ← PostgreSQL dumps
│   ├── downloads/                ← Дистрибутивы KC
│   └── logs/                     ← Логи миграции
│
├── KEYCLOAK_MIGRATION_PLAN.md    ✅ Готов
├── ANALYSIS_AND_IMPROVEMENTS.md  ✅ Готов (новый)
└── QUICK_START.md                ✅ Готов (этот файл)
```

---

## Тестовые сценарии

| Сценарий | Время | Готовность |
|----------|-------|------------|
| **Happy Path** (16→26) | ~40 мин | ✅ Готов |
| **Rollback Test** | ~10 мин | ✅ Готов |
| **Resume After Failure** | ~15 мин | ⚠️ Нужна P1-1 |
| **Custom Providers** | ~20 мин | ✅ Готов |
| **Large Tables** (>300k) | ~60 мин | ✅ Готов |

См. `test_lab/README.md` для детального описания.

---

## FAQ

### Q: Можно ли запускать в production прямо сейчас?

**A**: Не рекомендуется. Необходимо:
1. Пофиксить 7 критичных проблем (P0)
2. Протестировать все сценарии в test_lab
3. Провести dry-run на staging копии production

**ETA до production-ready**: ~40-50 часов работы.

### Q: Что делать, если миграция застряла?

**A**:
```bash
# 1. Посмотреть логи
tail -100 migration_workspace/logs/kc_*_startup.log

# 2. Если Liquibase висит — увеличить timeout
pkill -9 java
./scripts/migrate_keycloak.sh migrate --start-from <VERSION> --timeout 900

# 3. Если всё плохо — rollback
./scripts/migrate_keycloak.sh rollback <VERSION>
```

### Q: Как протестировать с реальными custom providers?

**A**:
```bash
# 1. Положить JAR в test_lab/custom_providers/
cp /path/to/custom.jar test_lab/custom_providers/

# 2. Discovery обнаружит их автоматически
./scripts/kc_discovery.sh -k /opt/jboss/keycloak ...

# 3. Transform (если Type B/C)
./scripts/transform_providers.sh

# 4. Миграция с providers
./scripts/migrate_keycloak.sh migrate -p ./providers_transformed_*/
```

### Q: Сколько времени займёт миграция в production?

**A**: Зависит от размера БД и custom providers:
- **Малая БД** (<1GB, нет providers): ~30-40 минут
- **Средняя БД** (1-10GB, 2-3 providers): ~1-2 часа
- **Большая БД** (>10GB, много providers): ~3-4 часа

**Downtime window**: Рекомендуется 4-6 часов (с запасом на rollback).

---

## Следующие шаги

1. **Сейчас** — запустить Quick Test (5 минут)
2. **Сегодня** — протестировать все сценарии в test_lab
3. **На неделе** — пофиксить P0 проблемы
4. **Через неделю** — dry-run на staging копии production
5. **Production** — после успешного staging теста

---

## Контакты и поддержка

- **Документация**: `KEYCLOAK_MIGRATION_PLAN.md` (детальный план)
- **Анализ проблем**: `ANALYSIS_AND_IMPROVEMENTS.md` (30 найденных issues)
- **Тестирование**: `test_lab/README.md` (сценарии)
- **Issues**: GitHub (если опубликовано)

---

**Статус утилиты**: 🟡 **Beta** — готова к тестированию, нужны P0 фиксы перед production

**Версия**: 1.0.0 (2026-01-29)
