#!/usr/bin/env bash
set -euo pipefail

# Логируем факт, что узел стал MASTER, и какие IPv4-адреса сейчас висят на интерфейсах
VIP_ADDRESSES="$(ip -4 addr show | awk '/inet / {print $2}' | tr '\n' ' ')"
echo "$(date -Is) MASTER $(hostname) vip=${VIP_ADDRESSES}" >> /var/log/keepalived-vip.log
