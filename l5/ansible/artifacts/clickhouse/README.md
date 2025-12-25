# ClickHouse офлайн-пакеты

Положите `.deb` пакеты ClickHouse в:
- `ansible/artifacts/clickhouse/deb/*.deb`


Пример проверки на узле:
- `clickhouse-client --query "SELECT version()"`
