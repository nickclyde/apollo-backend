#!/bin/sh
set -e
if psql -h postgres -U apollo -d apollo -tAc "SELECT to_regclass('public.accounts')" | grep -q accounts; then
  echo "schema already loaded, skipping"
else
  psql -h postgres -U apollo -d apollo -v ON_ERROR_STOP=1 -f /schema.sql
  echo "schema loaded"
fi
