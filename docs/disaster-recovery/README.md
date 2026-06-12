# Disaster-Recovery Helpers

This directory holds helper scripts used by the restore procedures in [`docs/BACKUP_STRATEGY.md`](../BACKUP_STRATEGY.md) and [`.backup/README.md`](../../.backup/README.md).

- `mysql-create-dbs.sql` — recreates the per-app MySQL databases (`homeassistant`, `uptimekuma`, `pricebuddy`) and their users on a fresh cluster, before importing data from the MySQL dumps. Replace each `<value>` placeholder with the real password from the restored secrets.
