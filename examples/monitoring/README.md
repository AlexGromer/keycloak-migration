# Monitoring & Observability

Keycloak Migration Tool supports Prometheus metrics export for real-time monitoring.

---

## Features

- **Real-time Metrics** — Migration progress, checkpoints, errors, duration
- **Prometheus Integration** — Standard text format metrics
- **Grafana Dashboards** — Pre-built visualization (coming soon)
- **Alerting** — Alert on failures via Prometheus Alertmanager

---

## Quick Start

### Option 1: Docker Compose Stack (Recommended)

Easiest way to get full monitoring stack (Prometheus + Grafana + Alertmanager):

```bash
cd examples/monitoring

# Start monitoring stack
docker-compose up -d

# Run migration with monitoring enabled
cd ../..
./scripts/migrate_keycloak_v3.sh migrate --profile prod.yaml --enable-monitoring
```

**Access dashboards:**
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9091
- Alertmanager: http://localhost:9093

The Keycloak Migration dashboard is auto-loaded in Grafana.

---

### Option 2: Manual Setup

#### 1. Enable Monitoring

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile prod.yaml --enable-monitoring
```

This starts a simple HTTP server on port **9090** exposing metrics.

#### 2. Scrape Metrics

Add to Prometheus configuration:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'keycloak-migration'
    static_configs:
      - targets: ['localhost:9090']
```

### 3. View Metrics

```bash
curl http://localhost:9090/metrics
```

---

## Available Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `keycloak_migration_progress` | gauge | Migration progress (0.0 to 1.0) |
| `keycloak_migration_checkpoint_status` | gauge | Checkpoint status (0=pending, 1=in_progress, 2=completed, 3=failed) |
| `keycloak_migration_duration_seconds` | counter | Total migration duration |
| `keycloak_migration_errors_total` | counter | Number of errors encountered |
| `keycloak_migration_database_size_bytes` | gauge | Database size in bytes |
| `keycloak_migration_java_heap_bytes` | gauge | Java heap memory usage |
| `keycloak_migration_last_success_timestamp` | gauge | Unix timestamp of last successful migration |

---

## Example Metrics Output

```prometheus
# HELP keycloak_migration_progress Migration progress as percentage (0.0 to 1.0)
# TYPE keycloak_migration_progress gauge
keycloak_migration_progress{profile="prod",from_version="16.1.1",to_version="26.0.7",status="in_progress"} 0.67

# HELP keycloak_migration_checkpoint_status Current checkpoint status
# TYPE keycloak_migration_checkpoint_status gauge
keycloak_migration_checkpoint_status{checkpoint="backup_done"} 2
keycloak_migration_checkpoint_status{checkpoint="stopped"} 2
keycloak_migration_checkpoint_status{checkpoint="downloaded"} 2
keycloak_migration_checkpoint_status{checkpoint="built"} 2
keycloak_migration_checkpoint_status{checkpoint="started"} 1
keycloak_migration_checkpoint_status{checkpoint="migrated"} 0
keycloak_migration_checkpoint_status{checkpoint="health_ok"} 0
keycloak_migration_checkpoint_status{checkpoint="tests_ok"} 0

# HELP keycloak_migration_duration_seconds Total migration duration in seconds
# TYPE keycloak_migration_duration_seconds counter
keycloak_migration_duration_seconds{profile="prod"} 1847

# HELP keycloak_migration_errors_total Total number of errors encountered
# TYPE keycloak_migration_errors_total counter
keycloak_migration_errors_total{profile="prod",error_type="connection"} 2
keycloak_migration_errors_total{profile="prod",error_type="health_check"} 0
```

---

## Prometheus Queries

### Migration Progress

```promql
keycloak_migration_progress{profile="prod"}
```

### Failed Checkpoints

```promql
keycloak_migration_checkpoint_status == 3
```

### Total Errors

```promql
sum(keycloak_migration_errors_total{profile="prod"})
```

### Migration Duration

```promql
rate(keycloak_migration_duration_seconds{profile="prod"}[5m])
```

---

## Alerting Rules

Example Prometheus alert rules:

```yaml
# alerts.yml
groups:
  - name: keycloak_migration
    rules:
      - alert: MigrationFailed
        expr: keycloak_migration_checkpoint_status == 3
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Keycloak migration failed at checkpoint {{ $labels.checkpoint }}"
          description: "Migration for profile {{ $labels.profile }} failed."

      - alert: MigrationStalled
        expr: changes(keycloak_migration_progress[10m]) == 0 and keycloak_migration_progress > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Keycloak migration appears stalled"
          description: "No progress in last 10 minutes for profile {{ $labels.profile }}."

      - alert: HighErrorRate
        expr: rate(keycloak_migration_errors_total[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate during migration"
          description: "Error rate: {{ $value }} errors/sec for profile {{ $labels.profile }}."
```

---

## Grafana Dashboard (Coming Soon)

Pre-built dashboard will include:

- **Progress Bar** — Visual migration progress (0-100%)
- **Checkpoint Timeline** — Visual representation of checkpoint status
- **Error Rate Graph** — Errors over time
- **Database Growth** — Database size before/after each version
- **Java Heap Usage** — Memory consumption during migration
- **Duration Heatmap** — Migration duration distribution

**Import JSON:** `examples/monitoring/grafana-dashboard.json` (not yet available)

---

## Advanced: Custom Metrics

You can add custom metrics in your scripts:

```bash
#!/bin/bash

# Source the exporter
source scripts/lib/prometheus_exporter.sh

# Start exporter
prom_start_exporter 9090

# Update metrics
prom_set_progress 0.25 "in_progress"
prom_set_checkpoint "backup_done" 2
prom_increment_errors "connection"

# Custom tracking
prom_track_migration "my_custom_step" my_command arg1 arg2

# Stop exporter on exit (automatic via trap)
```

---

## Troubleshooting

### Port Already in Use

```bash
# Check what's using port 9090
lsof -i :9090

# Use different port
./scripts/migrate_keycloak_v3.sh migrate --profile prod.yaml --monitoring-port 9091
```

### Metrics Not Updating

```bash
# Check metrics file
cat /tmp/keycloak_migration_metrics.prom

# Check exporter process
ps aux | grep prometheus_exporter
```

### Prometheus Not Scraping

```bash
# Test metrics endpoint
curl http://localhost:9090/metrics

# Check Prometheus targets
# Open http://localhost:9090/targets in Prometheus UI
```

---

## Integration with OpenTelemetry

The tool can export traces via OpenTelemetry (future enhancement).

Example configuration:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_SERVICE_NAME="keycloak-migration"

./scripts/migrate_keycloak_v3.sh migrate --profile prod.yaml --enable-telemetry
```

---

## References

- [Prometheus Metrics](https://prometheus.io/docs/concepts/metric_types/)
- [Prometheus Alerting](https://prometheus.io/docs/alerting/latest/overview/)
- [Grafana Documentation](https://grafana.com/docs/)
- [OpenTelemetry](https://opentelemetry.io/)
