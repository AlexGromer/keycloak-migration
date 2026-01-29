#!/bin/bash
#
# Generate SQL for manual index creation (tables >300k rows)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find latest discovery
discovery_dirs=($(ls -d "${SCRIPT_DIR}"/../discovery_* 2>/dev/null | sort -r))

if [[ ${#discovery_dirs[@]} -eq 0 ]]; then
    echo "ERROR: No discovery output found. Run kc_discovery.sh first."
    exit 1
fi

latest="${discovery_dirs[0]}"
table_counts="${latest}/db/table_counts.csv"

if [[ ! -f "$table_counts" ]]; then
    echo "ERROR: Table counts not found"
    exit 1
fi

output_file="${latest}/db/manual_indexes.sql"

cat > "$output_file" << 'EOF'
-- Keycloak Manual Index Creation Script
-- Run these AFTER Keycloak migration if indexes were skipped
-- Use CONCURRENTLY to avoid table locks

-- Check which indexes already exist before running:
-- SELECT indexname FROM pg_indexes WHERE schemaname = 'public';

BEGIN;

EOF

# Check each critical table
while IFS=',' read -r table count status; do
    [[ "$table" == "table_name" ]] && continue
    [[ "$status" != "MANUAL INDEX REQUIRED" ]] && continue

    echo "-- Table: $table (${count} rows)" >> "$output_file"

    case "$table" in
        "user_attribute")
            cat >> "$output_file" << 'EOF'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_user_attribute_name_value
    ON user_attribute (name, value);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_user_attribute_user
    ON user_attribute (user_id);

EOF
            ;;
        "fed_user_attribute")
            cat >> "$output_file" << 'EOF'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fed_user_attr_name_value
    ON fed_user_attribute (name, value);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fed_user_attr_user
    ON fed_user_attribute (user_id);

EOF
            ;;
        "client_attributes")
            cat >> "$output_file" << 'EOF'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_client_attr_name_value
    ON client_attributes (name, value);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_client_attr_client
    ON client_attributes (client_id);

EOF
            ;;
        "group_attribute")
            cat >> "$output_file" << 'EOF'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_group_attr_name_value
    ON group_attribute (name, value);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_group_attr_group
    ON group_attribute (group_id);

EOF
            ;;
    esac
done < "$table_counts"

echo "COMMIT;" >> "$output_file"

echo "Generated: $output_file"
echo ""
echo "Review the SQL file and run manually against PostgreSQL after migration:"
echo "  psql -h HOST -U USER -d keycloak -f $output_file"
