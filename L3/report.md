# Отчёт

## Самостоятельная работа: «Nginx-прокси во внутренней сети с двумя бэкендами»

**Студент:** Чуев Никита Сергеевич
**Группа:** p4250
**Дисциплина:** Системное администрирование
**Работа:** «Nginx-прокси во внутренней сети с двумя бэкендами»
**Дата выполнения:** 08.09.2025

---

## 1. Цель работы

Цель работы — развернуть во внутренней («серой») сети стенд из трёх узлов и настроить:

* Nginx как reverse-proxy на узле `proxy01`;
* два независимых HTTP-бэкенда на узлах `app01` и `app02` (порт `8080`);
* балансировку запросов с `proxy01` на оба бэкенда;
* логирование запросов в формате JSON с указанием upstream;
* простые health-checks и сценарий failover;
* сетевые ограничения (бэкенды доступны только с `proxy01`, наружу — только `proxy01:80`);
* reproducible-структуру репозитория с конфигами, юнитами, скриптами и результатами проверок.

---

## 2. Топология и исходные данные

### 2.1. Узлы и роли

Во внутренней сети использованы три хоста:

| Хост    | Роль                    | DNS-имя          | IP-адрес   |
| ------- | ----------------------- | ---------------- | ---------- |
| proxy01 | reverse-proxy (Nginx)   | proxy01.dc.local | 10.100.0.1 |
| app01   | backend №1 (HTTP :8080) | app01.dc.local   | 10.100.0.2 |
| app02   | backend №2 (HTTP :8080) | app02.dc.local   | 10.100.0.3 |

### 2.2. Настройка хостнеймов и /etc/hosts

На каждом узле:

```bash
# Пример для app01
sudo hostnamectl set-hostname app01
```

Для связи по именам использован статический `/etc/hosts`. На КАЖДОМ узле добавлены строки:

```text
10.100.0.1  proxy01.dc.local proxy01
10.100.0.2  app01.dc.local   app01
10.100.0.3  app02.dc.local   app02
```

Проверка:

```bash
host app01.dc.local
host app02.dc.local
host proxy01.dc.local
```

Результат этих команд сохранён в `checks/dns.txt`.

---

## 3. Мини-бэкенды на app01 и app02

### 3.1. Установка Python и подготовка каталога

На узлах `app01` и `app02`:

```bash
sudo apt -y update && sudo apt -y install python3
```

Создание каталога для приложения:

```bash
sudo install -d -o root -g root /opt/simple-backend
```

Копирование исходников из репозитория:

```bash
sudo cp app/app.py /opt/simple-backend/app.py
sudo cp app/systemd/simple-backend@.service \
  /etc/systemd/system/simple-backend@.service
sudo systemctl daemon-reload
```

### 3.2. Файл `app/app.py`

Файл `app/app.py` реализует минимальный HTTP-бэкенд:

```python
from http.server import BaseHTTPRequestHandler, HTTPServer
import os, socket, datetime

NAME = os.environ.get("APP_NAME", socket.gethostname())

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"backend={NAME} host={socket.gethostname()} time={datetime.datetime.utcnow().isoformat()}Z\n"
        self.send_response(200); self.send_header("Content-Type","text/plain"); self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, fmt, *args): return

HTTPServer(("0.0.0.0", int(os.environ.get("PORT","8080"))), H).serve_forever()
```

Назначение:

* слушать порт `8080` (по умолчанию) на всех интерфейсах;

* на любые `GET` возвращать строку вида:

  ```text
  backend=app01 host=app01 time=2025-09-25T12:34:56Z
  ```

* имя бэкенда берётся из переменной окружения `APP_NAME` (для различия `app01`/`app02`).

### 3.3. Юнит `app/systemd/simple-backend@.service`

Шаблонный unit-файл позволяет запускать экземпляры `simple-backend@app01` и `simple-backend@app02`:

```ini
[Unit]
Description=Simple HTTP backend
After=network-online.target
Wants=network-online.target

[Service]
Environment=APP_NAME=%i PORT=8080
ExecStart=/usr/bin/python3 /opt/simple-backend/app.py
Restart=always
User=www-data
Group=www-data

[Install]
WantedBy=multi-user.target
```

Сигнал `%i` подставляет в `APP_NAME` имя экземпляра (`app01` или `app02`).

### 3.4. Запуск сервисов на app01 и app02

На `app01`:

```bash
sudo systemctl enable --now simple-backend@app01
```

На `app02`:

```bash
sudo systemctl enable --now simple-backend@app02
```

Проверка статуса:

```bash
systemctl status simple-backend@app01
systemctl status simple-backend@app02
```

Проверка ответов с `proxy01`:

```bash
curl -s http://app01.dc.local:8080/
curl -s http://app02.dc.local:8080/
```

Эти два ответа сохранены в `checks/backend.txt`.

---

## 4. Настройка Nginx как reverse-proxy на proxy01

### 4.1. Установка и базовая настройка

На `proxy01`:

```bash
sudo apt -y update && sudo apt -y install nginx
sudo mkdir -p /etc/nginx/conf.d
```

Копирование конфига из репозитория:

```bash
sudo cp proxy/nginx.conf.d/app.conf /etc/nginx/conf.d/app.conf
```

### 4.2. Файл `proxy/nginx.conf.d/app.conf`

Содержимое:

```nginx
upstream app_backend {
    server app01.dc.local:8080 max_fails=2 fail_timeout=5s;
    server app02.dc.local:8080 max_fails=2 fail_timeout=5s;
    keepalive 32;
}

map $http_x_request_id $reqid { default $http_x_request_id; "" $request_id; }

log_format json_logs escape=json
  '{ "ts":"$time_iso8601", "remote":"$remote_addr", "req":"$request",'
  ' "status":$status, "bytes":$body_bytes_sent,'
  ' "rt":$request_time, "urt":$upstream_response_time,'
  ' "upstream":"$upstream_addr", "req_id":"$reqid", "ua":"$http_user_agent" }';

server {
    listen 80 default_server;
    server_name proxy01.dc.local _;

    access_log /var/log/nginx/access.json json_logs;
    error_log  /var/log/nginx/error.log warn;

    location /healthz { return 200; }

    location / {
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Request-Id      $reqid;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 5s;
        proxy_send_timeout 5s;

        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_pass http://app_backend;
    }
}
```

По факту реализовано:

* upstream `app_backend` с двумя бэкендами `app01.dc.local:8080` и `app02.dc.local:8080`;
* round-robin балансировка (по умолчанию);
* `max_fails` и `fail_timeout` для простых health-check’ов;
* JSON-формат логов в `/var/log/nginx/access.json` с полями `ts`, `req_id`, `remote`, `upstream`, `status`, `rt`, `urt`, `ua`;
* проброс заголовков `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Request-Id`;
* эндпоинт `/healthz` для проверки доступности прокси.

### 4.3. Проверка и запуск Nginx

Проверка синтаксиса:

```bash
sudo nginx -t
```

Запуск и автозапуск:

```bash
sudo systemctl enable --now nginx
```

Проверка доступа через прокси:

```bash
curl -s http://proxy01.dc.local/
```

Для проверки балансировки:

```bash
for i in {1..10}; do
  curl -s http://proxy01.dc.local/
done
```

Вывод этих 10 запросов сохранён в `checks/proxy-roundrobin.txt` (ожидается присутствие ответов и от `app01`, и от `app02`).

---

## 5. Сетевая безопасность (firewall)

### 5.1. Правила на app01 и app02 (ufw)

Задача: разрешить доступ к порту `8080` только с `proxy01` (10.100.0.1).

На каждом из бэкендов:

```bash
sudo apt -y install ufw

sudo ufw default deny incoming
sudo ufw default allow outgoing

# Разрешить 8080 только для proxy01
sudo ufw allow from 10.100.0.1 to any port 8080 proto tcp

sudo ufw enable
sudo ufw status verbose
```

Фактически:

* все входящие соединения запрещены;
* порт `8080` доступен только с IP `10.100.0.1`.

### 5.2. Правила на proxy01 (ufw)

Задача: открыть наружу только HTTP (`80/tcp`).

На `proxy01`:

```bash
sudo apt -y install ufw

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow 80/tcp

sudo ufw enable
sudo ufw status verbose
```

В результате:

* внешние клиенты могут обращаться только к `proxy01:80`;
* бэкенды полностью скрыты, работают только за прокси.

---

## 6. Проверки и файлы в каталоге `checks/`

### 6.1. Скрипт `checks/run_all.sh`

Для автоматизации формирования проверок использован скрипт `checks/run_all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "# DNS" > checks/dns.txt
{
  host app01.dc.local
  host app02.dc.local
  host proxy01.dc.local
} >> checks/dns.txt 2>&1 || true

echo "# Backends from proxy01" > checks/backend.txt
{
  curl -s http://app01.dc.local:8080/
  curl -s http://app02.dc.local:8080/
} >> checks/backend.txt

echo "# Round-robin via proxy01" > checks/proxy-roundrobin.txt
for i in {1..10}; do curl -s http://proxy01.dc.local/; done >> checks/proxy-roundrobin.txt

echo "# Access log sample (first 10 lines)" > checks/access-sample.json
sudo head -n 10 /var/log/nginx/access.json >> checks/access-sample.json || true

# Failover
echo "# Failover test" > checks/failover.txt
echo "Stopping app02..." | tee -a checks/failover.txt
sudo systemctl stop simple-backend@app02
for i in {1..5}; do
  out="$(curl -s http://proxy01.dc.local/)"
  echo "$out" | tee -a checks/failover.txt
  sleep 0.3
done
echo "--- last 10 access log lines during failover ---" >> checks/failover.txt
sudo tail -n 10 /var/log/nginx/access.json >> checks/failover.txt || true

echo "Starting app02..." | tee -a checks/failover.txt
sudo systemctl start simple-backend@app02
sleep 2
for i in {1..6}; do
  curl -s http://proxy01.dc.local/ | tee -a checks/failover.txt
  sleep 0.3
done
echo "--- last 10 access log lines after recovery ---" >> checks/failover.txt
sudo tail -n 10 /var/log/nginx/access.json >> checks/failover.txt || true

echo "Done. See checks/ directory."
```

Скрипт сделан исполняемым:

```bash
chmod +x checks/run_all.sh
```

Запуск:

```bash
./checks/run_all.sh
```

### 6.2. Сформированные файлы

После запуска скрипта в каталоге `checks/` находятся:

* `checks/dns.txt` — результат команд:

  ```bash
  host app01.dc.local
  host app02.dc.local
  host proxy01.dc.local
  ```
* `checks/backend.txt` — результат:

  ```bash
  curl -s http://app01.dc.local:8080/
  curl -s http://app02.dc.local:8080/
  ```
* `checks/proxy-roundrobin.txt` — 10 запросов через прокси:

  ```bash
  for i in {1..10}; do curl -s http://proxy01.dc.local/; done
  ```
* `checks/access-sample.json` — первые 10 строк логов Nginx:

  ```bash
  sudo head -n 10 /var/log/nginx/access.json
  ```
* `checks/failover.txt` — проверка сценария отказа `app02` и восстановления:

  * остановка `simple-backend@app02`,
  * несколько запросов к `proxy01.dc.local`,
  * фрагмент логов во время отказа,
  * запуск `simple-backend@app02`,
  * несколько запросов после восстановления,
  * фрагмент логов после восстановления.

---

## 7. Структура репозитория

Финальная структура соответствует заданию:

```text
.
├── README.md
├── dns/
│   ├── zone.dc.local        # файл зоны или конфиг dnsmasq (при использовании DNS)
│   └── named.conf.local     # опциональный фрагмент bind9
├── proxy/
│   └── nginx.conf.d/
│       └── app.conf
├── app/
│   ├── app.py
│   └── systemd/
│       └── simple-backend@.service
├── firewall/
│   ├── app01.rules          # вывод/фиксация настроек fw для app01 (при наличии)
│   └── app02.rules          # вывод/фиксация настроек fw для app02 (при наличии)
└── checks/
    ├── dns.txt
    ├── backend.txt
    ├── proxy-roundrobin.txt
    ├── access-sample.json
    ├── failover.txt
    └── run_all.sh
```

---

## 8. Вывод

По итогам работы:

* развернуты три узла во внутренней сети с именами `proxy01.dc.local`, `app01.dc.local`, `app02.dc.local`;
* на `app01` и `app02` запущены HTTP-бэкенды по `app/app.py`, управляемые через `app/systemd/simple-backend@.service` как `simple-backend@app01` и `simple-backend@app02`;
* на `proxy01` установлен и настроен Nginx с конфигом `proxy/nginx.conf.d/app.conf`, реализующим reverse-proxy, round-robin балансировку и JSON-логи с информацией об upstream;
* с помощью ufw настроены сетевые ограничения: бэкенды доступны по порту `8080` только с `proxy01`, наружу открыт только `proxy01:80`;
* с помощью скрипта `checks/run_all.sh` сформированы текстовые доказательства работоспособности: DNS, доступность бэкендов, балансировка, корректность логов и сценарий failover.

Все требования задания «Nginx-прокси во внутренней сети с двумя бэкендами» выполнены.
