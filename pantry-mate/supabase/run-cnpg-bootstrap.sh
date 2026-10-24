#!/bin/bash
set -euo pipefail

BASE="$HOME/pantry-mate/supabase/cnpg-bootstrap"
LOG="$HOME/pantry-mate/supabase/bootstrap-run.log"

: > "$LOG"

echo "===== SUPABASE CNPG BOOTSTRAP =====" | tee -a "$LOG"

echo "===== INIT SCRIPTS =====" | tee -a "$LOG"

while IFS= read -r sql; do
    echo "RUN INIT: $(basename "$sql")" | tee -a "$LOG"

    kubectl exec -i \
      -n database supabase-postgres-1 -- \
      psql \
        -v ON_ERROR_STOP=1 \
        --no-psqlrc \
        -U postgres \
        -d postgres \
      < "$sql" >> "$LOG" 2>&1

done < <(
    find "$BASE/init-scripts" \
      -maxdepth 1 \
      -type f \
      -name '*.sql' \
      | sort
)

echo "===== MIGRATIONS =====" | tee -a "$LOG"

SUPABASE_ADMIN_PASS="$(
    kubectl get secret supabase-admin \
      -n database \
      -o jsonpath='{.data.password}' \
    | base64 -d
)"

while IFS= read -r sql; do
    echo "RUN MIGRATION: $(basename "$sql")" | tee -a "$LOG"

    kubectl exec -i \
      -n database supabase-postgres-1 -- \
      env PGPASSWORD="$SUPABASE_ADMIN_PASS" \
      psql \
        -v ON_ERROR_STOP=1 \
        --no-psqlrc \
        -h 127.0.0.1 \
        -U supabase_admin \
        -d postgres \
      < "$sql" >> "$LOG" 2>&1

done < <(
    find "$BASE/migrations" \
      -maxdepth 1 \
      -type f \
      -name '*.sql' \
      | sort
)

unset SUPABASE_ADMIN_PASS

echo "===== BOOTSTRAP COMPLETE =====" | tee -a "$LOG"
