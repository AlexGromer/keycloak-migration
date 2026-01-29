# Keycloak Migration Plan: 16 → 26

**Статус**: Draft
**База данных**: PostgreSQL
**Custom Providers**: Требуется discovery
**Дата создания**: 2026-01-28

---

## Executive Summary

Миграция Keycloak 16 → 26 включает:
- **Архитектурный переход**: WildFly → Quarkus (версия 17)
- **Namespace миграция**: Java EE → Jakarta EE (версия 22)
- **10 мажорных версий** с breaking changes
- **Обязательный промежуточный шаг**: версия 25 (Infinispan Protostream)

**Рекомендуемый путь**: 16 → 17 → 22 → 25 → 26

**Оценка времени**: 2-4 недели (зависит от сложности custom providers)

---

## Фаза 0: Discovery & Audit (до начала миграции)

### 0.1 Аудит текущей инсталляции

```bash
# Версия Keycloak
cat $KEYCLOAK_HOME/version.txt
# или
ls $KEYCLOAK_HOME/modules/system/layers/keycloak/org/keycloak/keycloak-server-spi-private/main/*.jar

# Структура deployment
ls -la $KEYCLOAK_HOME/standalone/deployments/

# Конфигурация
cat $KEYCLOAK_HOME/standalone/configuration/standalone.xml | grep -A5 "<spi"
cat $KEYCLOAK_HOME/standalone/configuration/standalone-ha.xml | grep -A5 "<spi"
```

### 0.2 Discovery Custom Providers

#### Метод 1: Поиск deployed JAR файлов

```bash
# Найти все custom JAR в deployments
find $KEYCLOAK_HOME/standalone/deployments -name "*.jar" -type f

# Найти все JAR в modules (custom modules)
find $KEYCLOAK_HOME/modules -name "*.jar" -type f | grep -v "org/keycloak"

# Проверить содержимое каждого JAR
for jar in $(find $KEYCLOAK_HOME/standalone/deployments -name "*.jar"); do
    echo "=== $jar ==="
    unzip -l "$jar" | grep -E "(META-INF/services|META-INF/jboss-deployment)"
    unzip -p "$jar" META-INF/services/org.keycloak.* 2>/dev/null
done
```

#### Метод 2: Проверка SPI регистраций

```bash
# Список всех зарегистрированных провайдеров (в работающем KC)
# Через Admin CLI
$KEYCLOAK_HOME/bin/kcadm.sh get serverinfo -r master --fields "providers(*)"

# Или через REST API
curl -s -X GET "https://your-keycloak/auth/admin/realms/master/serverinfo" \
  -H "Authorization: Bearer $TOKEN" | jq '.providers'
```

#### Метод 3: Анализ исходного кода (если доступен)

```bash
# Поиск SPI имплементаций
grep -r "implements.*Provider" --include="*.java" /path/to/source
grep -r "implements.*ProviderFactory" --include="*.java" /path/to/source
grep -r "@Provider" --include="*.java" /path/to/source

# Поиск javax зависимостей (потребуют миграции на jakarta)
grep -r "import javax\." --include="*.java" /path/to/source | grep -v "javax.crypto\|javax.net\|javax.security"
```

### 0.3 Документирование найденных Custom Providers

Заполните таблицу для каждого найденного провайдера:

| Provider JAR | SPI Type | javax.* imports | RESTEasy usage | Priority |
|--------------|----------|-----------------|----------------|----------|
| custom-auth.jar | Authenticator | ✅ Yes | ❌ No | P1 |
| user-storage.jar | UserStorageProvider | ✅ Yes | ✅ Yes | P1 |
| theme-provider.jar | ThemeProvider | ❌ No | ❌ No | P3 |
| event-listener.jar | EventListenerProvider | ✅ Yes | ❌ No | P2 |

**SPI Types для проверки:**
- `org.keycloak.authentication.AuthenticatorFactory`
- `org.keycloak.storage.UserStorageProviderFactory`
- `org.keycloak.events.EventListenerProviderFactory`
- `org.keycloak.protocol.ProtocolMapperFactory`
- `org.keycloak.broker.provider.IdentityProviderFactory`
- `org.keycloak.services.resource.RealmResourceProviderFactory`

### 0.4 Аудит PostgreSQL

```sql
-- Подключиться к БД Keycloak
\c keycloak_db

-- Размер базы
SELECT pg_size_pretty(pg_database_size('keycloak_db'));

-- Количество записей в критических таблицах (порог 300,000)
SELECT 'USER_ATTRIBUTE' as table_name, COUNT(*) as rows FROM user_attribute
UNION ALL
SELECT 'FED_USER_ATTRIBUTE', COUNT(*) FROM fed_user_attribute
UNION ALL
SELECT 'CLIENT_ATTRIBUTES', COUNT(*) FROM client_attributes
UNION ALL
SELECT 'GROUP_ATTRIBUTE', COUNT(*) FROM group_attribute
UNION ALL
SELECT 'USER_ENTITY', COUNT(*) FROM user_entity
UNION ALL
SELECT 'CREDENTIAL', COUNT(*) FROM credential
UNION ALL
SELECT 'USER_SESSION', COUNT(*) FROM user_session
UNION ALL
SELECT 'CLIENT_SESSION', COUNT(*) FROM client_session;

-- Проверка прав на системные таблицы (нужны для эффективного upgrade)
SELECT has_table_privilege(current_user, 'pg_class', 'SELECT') as pg_class_access,
       has_table_privilege(current_user, 'pg_namespace', 'SELECT') as pg_namespace_access;

-- Существующие индексы (для сравнения после миграции)
SELECT indexname, tablename, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;
```

### 0.5 Чеклист Phase 0

- [ ] Keycloak версия подтверждена: 16.x
- [ ] Все custom JAR файлы найдены и задокументированы
- [ ] javax.* зависимости в custom providers идентифицированы
- [ ] RESTEasy usage в custom providers идентифицирован
- [ ] Размер PostgreSQL базы записан
- [ ] Таблицы с >300k записей идентифицированы
- [ ] Права pg_class/pg_namespace проверены
- [ ] Текущие индексы задокументированы
- [ ] Realms список задокументирован
- [ ] Federation providers задокументированы (LDAP, Kerberos, etc.)
- [ ] Identity Providers задокументированы (SAML, OIDC, Social)

---

## Фаза 1: Подготовка инфраструктуры

### 1.1 Требования к окружению

| Компонент | KC 16 (текущий) | KC 17-21 | KC 22-25 | KC 26 (целевой) |
|-----------|-----------------|----------|----------|-----------------|
| Java | 8/11 | 11/17 | 17 | **21** |
| PostgreSQL | 10+ | 11+ | 12+ | **15+** рекомендуется |

### 1.2 Подготовка серверов

```bash
# Установить OpenJDK 21 (для целевой версии)
sudo apt update
sudo apt install openjdk-21-jdk

# Проверить версию
java -version
# openjdk version "21.x.x"

# Установить JAVA_HOME
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
```

### 1.3 Подготовка staging окружения

```bash
# Создать директорию для миграции
mkdir -p /opt/keycloak-migration/{backup,staging,scripts,providers}

# Структура:
# /opt/keycloak-migration/
# ├── backup/           # Бэкапы БД и конфигов
# ├── staging/          # Staging инсталляции KC
# │   ├── kc-17/
# │   ├── kc-22/
# │   ├── kc-25/
# │   └── kc-26/
# ├── scripts/          # Миграционные скрипты
# └── providers/        # Migrated custom providers
```

### 1.4 Скачать все необходимые версии Keycloak

```bash
cd /opt/keycloak-migration/staging

# KC 17 (первая Quarkus версия)
wget https://github.com/keycloak/keycloak/releases/download/17.0.1/keycloak-17.0.1.tar.gz
tar xzf keycloak-17.0.1.tar.gz && mv keycloak-17.0.1 kc-17

# KC 22 (Jakarta EE)
wget https://github.com/keycloak/keycloak/releases/download/22.0.5/keycloak-22.0.5.tar.gz
tar xzf keycloak-22.0.5.tar.gz && mv keycloak-22.0.5 kc-22

# KC 25 (обязательный промежуточный шаг)
wget https://github.com/keycloak/keycloak/releases/download/25.0.6/keycloak-25.0.6.tar.gz
tar xzf keycloak-25.6.0.tar.gz && mv keycloak-25.0.6 kc-25

# KC 26 (целевая версия)
wget https://github.com/keycloak/keycloak/releases/download/26.0.7/keycloak-26.0.7.tar.gz
tar xzf keycloak-26.0.7.tar.gz && mv keycloak-26.0.7 kc-26
```

### 1.5 Чеклист Phase 1

- [ ] OpenJDK 21 установлен
- [ ] PostgreSQL версия совместима (12+)
- [ ] Staging окружение создано
- [ ] Все версии KC скачаны (17, 22, 25, 26)
- [ ] Достаточно дискового пространства (минимум 3x размер БД)

---

## Фаза 2: Backup & Export

### 2.1 Full Database Backup

```bash
# Остановить Keycloak (если возможно)
systemctl stop keycloak

# Создать full dump PostgreSQL
pg_dump -h localhost -U keycloak -d keycloak_db -F c -f /opt/keycloak-migration/backup/keycloak_db_v16_$(date +%Y%m%d_%H%M%S).dump

# Создать plain SQL backup (для ручного восстановления)
pg_dump -h localhost -U keycloak -d keycloak_db -F p -f /opt/keycloak-migration/backup/keycloak_db_v16_$(date +%Y%m%d_%H%M%S).sql

# Проверить бэкап
pg_restore --list /opt/keycloak-migration/backup/keycloak_db_v16_*.dump | head -50
```

### 2.2 Realm Export (JSON)

```bash
# Запустить KC 16 с export
cd $KEYCLOAK_HOME

# Export всех realms в отдельные файлы
./bin/standalone.sh \
  -Dkeycloak.migration.action=export \
  -Dkeycloak.migration.provider=dir \
  -Dkeycloak.migration.dir=/opt/keycloak-migration/backup/realms \
  -Dkeycloak.migration.usersExportStrategy=DIFFERENT_FILES \
  -Dkeycloak.migration.usersPerFile=100

# Дождаться завершения и остановить
# Ctrl+C после "Export finished successfully"
```

### 2.3 Configuration Backup

```bash
# Backup конфигурации WildFly
cp -r $KEYCLOAK_HOME/standalone/configuration /opt/keycloak-migration/backup/config_v16/

# Backup custom providers
cp -r $KEYCLOAK_HOME/standalone/deployments/*.jar /opt/keycloak-migration/backup/providers_v16/

# Backup themes
cp -r $KEYCLOAK_HOME/themes /opt/keycloak-migration/backup/themes_v16/

# Backup modules (если есть custom)
find $KEYCLOAK_HOME/modules -type f -name "*.jar" ! -path "*/org/keycloak/*" \
  -exec cp {} /opt/keycloak-migration/backup/modules_v16/ \;
```

### 2.4 Чеклист Phase 2

- [ ] PostgreSQL full dump создан
- [ ] PostgreSQL dump проверен (pg_restore --list)
- [ ] Realm export завершён успешно
- [ ] Все JSON файлы realms сохранены
- [ ] standalone.xml backed up
- [ ] Custom providers JAR backed up
- [ ] Themes backed up
- [ ] Custom modules backed up
- [ ] Backup протестирован на restore (опционально, но рекомендуется)

---

## Фаза 3: Миграция Custom Providers

### 3.1 Анализ необходимых изменений

Для каждого custom provider из Phase 0.3:

#### Тип A: Providers БЕЗ javax.* и RESTEasy
**Действие**: Только repackage для Quarkus deployment
```bash
# Проверить что JAR содержит META-INF/beans.xml
unzip -l provider.jar | grep beans.xml

# Если нет - добавить пустой beans.xml
mkdir -p META-INF
touch META-INF/beans.xml
jar uf provider.jar META-INF/beans.xml
```

#### Тип B: Providers С javax.* imports (БЕЗ RESTEasy)
**Действие**: Namespace migration javax → jakarta

```bash
# Использовать Eclipse Transformer
wget https://repo1.maven.org/maven2/org/eclipse/transformer/org.eclipse.transformer.cli/0.5.0/org.eclipse.transformer.cli-0.5.0.jar

# Трансформировать JAR
java -jar org.eclipse.transformer.cli-0.5.0.jar \
  provider-v16.jar \
  provider-jakarta.jar \
  -o

# Проверить результат
unzip -p provider-jakarta.jar $(unzip -l provider-jakarta.jar | grep ".class" | head -1 | awk '{print $4}') | strings | grep -E "javax\.|jakarta\."
```

#### Тип C: Providers С RESTEasy Classic
**Действие**: Полная миграция кода (требует исходники)

```java
// БЫЛО (RESTEasy Classic)
import javax.ws.rs.core.Context;
import org.jboss.resteasy.client.jaxrs.ResteasyClientBuilder;

@Context
private HttpServletRequest request;

// СТАЛО (RESTEasy Reactive / Jakarta)
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.client.ClientBuilder;

// @Context больше не поддерживается для injection
// Использовать KeycloakSession для получения контекста
```

### 3.2 Пошаговая миграция provider

```bash
# 1. Создать рабочую директорию для provider
mkdir -p /opt/keycloak-migration/providers/my-provider/{original,transformed,rebuilt}

# 2. Скопировать оригинал
cp original-provider.jar /opt/keycloak-migration/providers/my-provider/original/

# 3. Декомпилировать (если нет исходников)
# Использовать CFR или Procyon
java -jar cfr.jar original-provider.jar --outputdir decompiled/

# 4. Применить изменения:
#    - javax.* → jakarta.* (кроме JDK packages)
#    - ResteasyClientBuilder → ClientBuilder
#    - @Context injection → KeycloakSession
#    - Добавить META-INF/beans.xml

# 5. Пересобрать с новыми зависимостями
# pom.xml должен использовать:
#   - keycloak-server-spi: 22.0.0+ (для Jakarta)
#   - jakarta.ws.rs-api вместо javax.ws.rs-api

# 6. Тестировать с KC 22
```

### 3.3 Тестирование providers на KC 22

```bash
# Копировать transformed provider в KC 22
cp /opt/keycloak-migration/providers/my-provider/transformed/*.jar \
   /opt/keycloak-migration/staging/kc-22/providers/

# Собрать KC с providers
cd /opt/keycloak-migration/staging/kc-22
./bin/kc.sh build

# Запустить в dev mode для тестирования
./bin/kc.sh start-dev \
  --db=postgres \
  --db-url=jdbc:postgresql://localhost/keycloak_test \
  --db-username=keycloak \
  --db-password=xxx

# Проверить что providers загрузились
curl -s http://localhost:8080/admin/master/console/ | grep -i "error"
# Логи: grep "provider" logs/keycloak.log
```

### 3.4 Чеклист Phase 3

- [ ] Все custom providers классифицированы (A/B/C)
- [ ] Type A providers: beans.xml добавлен
- [ ] Type B providers: javax→jakarta трансформация выполнена
- [ ] Type C providers: код мигрирован на RESTEasy Reactive
- [ ] Все providers успешно загружаются в KC 22
- [ ] Функциональность providers протестирована
- [ ] Providers работают без ошибок в логах

---

## Фаза 4: Поэтапная миграция базы данных

### 4.1 Подготовка PostgreSQL

```sql
-- Создать staging базу (клон production)
CREATE DATABASE keycloak_staging WITH TEMPLATE keycloak_db;

-- Или restore из backup
CREATE DATABASE keycloak_staging;
pg_restore -h localhost -U keycloak -d keycloak_staging /opt/keycloak-migration/backup/keycloak_db_v16_*.dump

-- Убедиться в правах
GRANT SELECT ON pg_class TO keycloak;
GRANT SELECT ON pg_namespace TO keycloak;
```

### 4.2 Миграция 16 → 17 (WildFly → Quarkus)

```bash
cd /opt/keycloak-migration/staging/kc-17

# Конфигурация
cat > conf/keycloak.conf << 'EOF'
# Database
db=postgres
db-url=jdbc:postgresql://localhost/keycloak_staging
db-username=keycloak
db-password=YOUR_PASSWORD

# HTTP
http-enabled=true
http-port=8080
hostname-strict=false

# Legacy URL compatibility
http-relative-path=/auth
EOF

# НЕ копировать custom providers пока!
# Сначала проверить чистую миграцию БД

# Build
./bin/kc.sh build

# Start (автоматическая миграция схемы)
./bin/kc.sh start --optimized 2>&1 | tee /opt/keycloak-migration/logs/migration_16_17.log

# Проверить успешность
grep -i "error\|exception\|failed" /opt/keycloak-migration/logs/migration_16_17.log
```

**Ожидаемые изменения в БД (16→17):**
- Новые таблицы для Quarkus
- Изменения в REALM таблице
- Миграция конфигурации SPI

### 4.3 Миграция 17 → 22 (Jakarta EE)

```bash
cd /opt/keycloak-migration/staging/kc-22

# Копировать конфигурацию
cp ../kc-17/conf/keycloak.conf conf/

# Build
./bin/kc.sh build

# Start
./bin/kc.sh start --optimized 2>&1 | tee /opt/keycloak-migration/logs/migration_17_22.log

# Проверить миграцию
grep -i "liquibase\|changelog\|migrat" /opt/keycloak-migration/logs/migration_17_22.log
```

**ВНИМАНИЕ при 22**: Если есть таблицы >300k записей:

```bash
# Проверить логи на пропущенные индексы
grep -i "index.*skip\|threshold" /opt/keycloak-migration/logs/migration_17_22.log

# Если индексы пропущены - применить вручную
# SQL будет в логах или в файле keycloak-database-update.sql
```

### 4.4 Миграция 22 → 25 (Persistent Sessions)

```bash
cd /opt/keycloak-migration/staging/kc-25

cp ../kc-22/conf/keycloak.conf conf/

# ВАЖНО: Включить persistent sessions ДО запуска
cat >> conf/keycloak.conf << 'EOF'

# Persistent sessions (required for 25→26 migration)
spi-user-sessions-infinispan-offline-session-cache-entry-lifespan-override=2592000
EOF

./bin/kc.sh build
./bin/kc.sh start --optimized 2>&1 | tee /opt/keycloak-migration/logs/migration_22_25.log

# Дать поработать 5-10 минут для стабилизации сессий
# Затем остановить gracefully
./bin/kc.sh stop
```

### 4.5 Миграция 25 → 26 (Целевая версия)

```bash
cd /opt/keycloak-migration/staging/kc-26

cp ../kc-25/conf/keycloak.conf conf/

# Обновить конфигурацию для v26
cat >> conf/keycloak.conf << 'EOF'

# KC 26 specific
# Infinispan Protostream (автоматически)
EOF

# Добавить migrated custom providers
cp /opt/keycloak-migration/providers/*/transformed/*.jar providers/

# Build с providers
./bin/kc.sh build

# Start
./bin/kc.sh start --optimized 2>&1 | tee /opt/keycloak-migration/logs/migration_25_26.log

# Проверить
grep -i "error\|exception\|failed\|provider" /opt/keycloak-migration/logs/migration_25_26.log
```

### 4.6 Создание индексов вручную (если пропущены)

```sql
-- Проверить какие индексы нужны
-- (из логов миграции)

-- Пример для USER_ATTRIBUTE
CREATE INDEX CONCURRENTLY idx_user_attribute_name_value
ON user_attribute (name, value);

-- Пример для FED_USER_ATTRIBUTE
CREATE INDEX CONCURRENTLY idx_fed_user_attr_name_value
ON fed_user_attribute (name, value);

-- CONCURRENTLY - не блокирует таблицу (PostgreSQL)
```

### 4.7 Чеклист Phase 4

- [ ] Staging база создана из backup
- [ ] Миграция 16→17 успешна (логи чистые)
- [ ] Миграция 17→22 успешна
- [ ] Jakarta EE миграция схемы подтверждена
- [ ] Миграция 22→25 успешна
- [ ] Persistent sessions включены
- [ ] Миграция 25→26 успешна
- [ ] Custom providers загружены в KC 26
- [ ] Пропущенные индексы созданы вручную
- [ ] Нет ERROR/EXCEPTION в логах

---

## Фаза 5: Функциональное тестирование

### 5.1 Smoke Tests

```bash
# Базовая доступность
curl -s http://localhost:8080/auth/realms/master | jq .realm
# Expected: "master"

# Admin Console
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/auth/admin/master/console/
# Expected: 200

# Health check (KC 26+)
curl -s http://localhost:8080/health | jq .status
# Expected: "UP"
```

### 5.2 Authentication Tests

```bash
# Получить токен (password grant)
curl -s -X POST "http://localhost:8080/auth/realms/YOUR_REALM/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=YOUR_CLIENT" \
  -d "username=testuser" \
  -d "password=testpass" | jq .access_token

# Проверить userinfo
curl -s "http://localhost:8080/auth/realms/YOUR_REALM/protocol/openid-connect/userinfo" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

### 5.3 Custom Provider Tests

Для каждого custom provider создать тест-кейсы:

| Provider | Test Case | Expected | Status |
|----------|-----------|----------|--------|
| custom-auth | Login with custom authenticator | Success, correct flow | ⬜ |
| user-storage | Federated user lookup | User found from external store | ⬜ |
| event-listener | Login event fired | Event logged to external system | ⬜ |
| protocol-mapper | Custom claim in token | Claim present with correct value | ⬜ |

### 5.4 Integration Tests

- [ ] LDAP/AD Federation работает
- [ ] SAML IdP integration работает
- [ ] OIDC IdP integration работает
- [ ] Social logins работают (Google, GitHub, etc.)
- [ ] Custom themes отображаются корректно
- [ ] Email отправляется
- [ ] 2FA/MFA работает

### 5.5 Performance Baseline

```bash
# Простой load test
# Используя k6, wrk или ab

# Пример с wrk (100 concurrent, 30 sec)
wrk -t4 -c100 -d30s \
  -s /opt/keycloak-migration/scripts/token_request.lua \
  http://localhost:8080/auth/realms/master/protocol/openid-connect/token

# Сравнить с baseline KC 16
```

### 5.6 Чеклист Phase 5

- [ ] Smoke tests passed
- [ ] Authentication flows работают
- [ ] Все custom providers функционируют
- [ ] Federation providers работают
- [ ] Identity providers работают
- [ ] Themes корректны
- [ ] Email работает
- [ ] Performance приемлемый

---

## Фаза 6: Production Migration

### 6.1 Pre-Migration Checklist

- [ ] Все тесты на staging пройдены
- [ ] Rollback план задокументирован
- [ ] Maintenance window согласован
- [ ] Stakeholders уведомлены
- [ ] Monitoring настроен
- [ ] On-call support готов

### 6.2 Migration Steps

```bash
# 1. Объявить maintenance window
# 2. Остановить traffic (LB health check fail)

# 3. Создать финальный backup
pg_dump -h localhost -U keycloak -d keycloak_prod -F c \
  -f /opt/keycloak-migration/backup/keycloak_prod_pre_migration_$(date +%Y%m%d_%H%M%S).dump

# 4. Остановить KC 16
systemctl stop keycloak

# 5. Поэтапная миграция БД (как в Phase 4)
# 16 → 17 → 22 → 25 → 26

# 6. Запустить KC 26
systemctl start keycloak-26

# 7. Проверить health
curl -s http://localhost:8080/health | jq .status

# 8. Включить traffic (LB health check pass)

# 9. Мониторить 30 минут
```

### 6.3 Rollback Plan

```bash
# ЕСЛИ что-то пошло не так:

# 1. Остановить KC 26
systemctl stop keycloak-26

# 2. Restore база из backup
dropdb keycloak_prod
createdb keycloak_prod
pg_restore -h localhost -U keycloak -d keycloak_prod \
  /opt/keycloak-migration/backup/keycloak_prod_pre_migration_*.dump

# 3. Запустить KC 16
systemctl start keycloak

# 4. Проверить
curl -s http://localhost:8080/auth/realms/master | jq .realm
```

### 6.4 Post-Migration

```bash
# Cleanup старых версий (через 2 недели после успешной миграции)
# rm -rf /opt/keycloak-16

# Обновить документацию
# Обновить runbooks
# Обновить CI/CD pipelines
```

---

## Приложения

### A. Mapping конфигурации WildFly → Quarkus

| WildFly (standalone.xml) | Quarkus (keycloak.conf) |
|--------------------------|-------------------------|
| `<socket-binding port="8080"/>` | `http-port=8080` |
| `<datasource jndi-name="java:jboss/datasources/KeycloakDS">` | `db-url=jdbc:postgresql://...` |
| `<spi name="hostname">` | `hostname=...` |
| `<theme><staticMaxAge>` | `spi-theme-static-max-age=...` |

### B. Известные проблемы и решения

| Проблема | Решение |
|----------|---------|
| `/auth` path не работает | Добавить `http-relative-path=/auth` |
| Custom provider не загружается | Проверить beans.xml, @Provider annotation |
| Индексы не создались | Применить SQL из логов вручную |
| Sessions потеряны после 25→26 | Убедиться что persistent sessions были включены в 25 |

### C. Полезные ссылки

- [Keycloak Upgrading Guide](https://www.keycloak.org/docs/latest/upgrading/index.html)
- [Migrating to Quarkus](https://www.keycloak.org/migration/migrating-to-quarkus)
- [Red Hat KC 26 Migration Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.0/html-single/migration_guide/index)
- [Server Developer Guide (Custom Providers)](https://www.keycloak.org/docs/latest/server_development/index.html)
- [GitHub Discussions](https://github.com/keycloak/keycloak/discussions)

---

## История изменений

| Дата | Версия | Изменения |
|------|--------|-----------|
| 2026-01-28 | 1.0 | Initial draft |

