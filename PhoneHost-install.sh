#!/usr/bin/env bash
# PhoneHost 0.7 • Debian on Termux, without flashing Android.
set -euo pipefail
umask 077

case "${PREFIX:-}" in
  /data/data/*/files/usr|/data/user/0/*/files/usr) ;;
  *) printf 'Запусти этот файл в обычном Termux: bash PhoneHost-install.sh\n' >&2; exit 1 ;;
esac
if [ "$(id -u)" -eq 0 ]; then
  printf 'Выйди из su. Эта версия устанавливается из обычной сессии Termux.\n' >&2
  exit 1
fi

if [ ! -x "$PREFIX/bin/python" ]; then
  printf '\n  PHONEHOST / SHARK  ·  Подготовка Python в Termux\n\n'
  pkg install -y python
fi

launcher="$(mktemp "$PREFIX/bin/.phonehost.XXXXXXXX")"
trap 'rm -f -- "$launcher"' EXIT
printf '#!%s/bin/python\n' "$PREFIX" > "$launcher"
cat >> "$launcher" <<'PHONEHOST_PY'
"""PhoneHost command-line manager for Termux."""
import argparse
import base64
import binascii
from collections import Counter, deque
import contextlib
import csv
import fcntl
import getpass
import hashlib
import http.client
from html.parser import HTMLParser
import ipaddress
import io
import itertools
import json
import math
import os
import platform
from pathlib import Path
import queue
import random
import re
import secrets
import select
import shlex
import shutil
import signal
import socket
import ssl
import statistics
import subprocess
import sys
import threading
import time
import textwrap
import unicodedata
from urllib.error import HTTPError
from urllib.parse import quote, unquote, urlencode, urljoin, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from concurrent.futures import ThreadPoolExecutor

VERSION = "0.7.0"
INSTALL_SECONDS = 300
PREFIX = Path(os.environ.get("PREFIX") or Path(__file__).resolve().parent.parent)
STATE = Path.home() / ".phonehost"
CONTAINER = "phonehost"
IMAGE = "debian:trixie-slim"
CONTROL = STATE / "run.sock"
CONFIG = STATE / "config.json"
SERVICES = STATE / "services.json"
BOXES = STATE / "boxes.json"
BOX_CONFIG = "/opt/phonebox/nginx.conf"
MARKER = STATE / "container-owned"
HEALTH = "/__phonehost_health"
HEALTH_BODY = b"phonehost-ok"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
GUEST_WEB = "/opt/phonehost/nginx.conf"
GUEST_LOGS = "/var/log/phonehost"
ACCESS = STATE / "nginx" / "access.jsonl"
BASE_LOGS = ("access", "web", "ssh", "supervisor", "install", "boot")
LOGO = "◢━━◣  PHONEHOST / SHARK"
TOOL_PACKAGES = ("bind9-dnsutils", "jq", "openssl", "file", "libimage-exiftool-perl")
FILE_SCRIPT = r"""set -eu
case "$1" in
    root) root=/root/phonehost ;;
    web) root=/srv/phonehost/www ;;
    *) exit 2 ;;
esac
op=$2
path=$(realpath -m -- "$root/$3")
case "$path" in
    "$root"|"$root"/*) ;;
    *) echo 'Путь выходит за пределы рабочей папки' >&2; exit 2 ;;
esac
case "$op" in
    ls) ls -lah -- "$path" ;;
    mkdir) mkdir -p -- "$path" ;;
    touch) touch -- "$path" ;;
    cat) cat -- "$path" ;;
    write)
        temp=$(mktemp -- "$(dirname -- "$path")/.phonehost.XXXXXXXX")
        trap 'rm -f -- "$temp"' EXIT
        cat > "$temp"
        mv -fT -- "$temp" "$path" ;;
    *) exit 2 ;;
esac
"""

SITE = """<!doctype html>
<html lang="ru"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PhoneHost</title>
<style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;align-items:center;
background:#111416;color:#f2f4f5;font:16px system-ui,sans-serif;padding:24px}
main{width:min(100%,640px);margin:auto;border-top:1px solid #455056;padding-top:26px}
.mark{display:block;width:72px;height:72px;margin-bottom:22px;color:#83ebcb}
small{color:#97edbc;font:700 12px ui-monospace,monospace;letter-spacing:.14em}
h1{font-size:clamp(44px,10vw,78px);letter-spacing:-.07em;line-height:1;margin:18px 0}
p{color:#afb8bd;line-height:1.6}code{color:#e2e7ea}
</style><main>
<svg class="mark" viewBox="0 0 80 80" role="img" aria-label="Логотип Shark">
<rect x="1" y="1" width="78" height="78" rx="17" fill="#182523" stroke="#496762"/>
<path d="M13 58h54M17 50h46L46 23l-5 16-8-4-10 15" fill="none" stroke="currentColor"
stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg><small>● ONLINE / SHARK</small><h1>PhoneHost</h1>
<p>Этот ответ пришёл с Nginx внутри Debian, запущенного в Termux.</p>
<p>Файлы сайта лежат в <code>/srv/phonehost/www</code> внутри Debian.</p>
</main></html>
"""

class UserError(Exception):
    pass


def binary(name):
    return str(PREFIX / "bin" / name)


def guest(*args, logs=False, container=CONTAINER):
    command = [binary("proot-distro"), "login", "--isolated"]
    if logs:
        ACCESS.parent.mkdir(exist_ok=True, mode=0o700)
        command += ["--bind", f"{ACCESS.parent}:{GUEST_LOGS}"]
    command.append(container)
    return command + ["--", *args] if args else command


def atomic_write(path, contents, mode=0o600):
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(contents)
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


@contextlib.contextmanager
def serial():
    with (STATE / "operation.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def read_config():
    if not CONFIG.is_file():
        raise UserError("Сначала выполни phonehost install.")
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def read_services():
    return json.loads(SERVICES.read_text(encoding="utf-8")) if SERVICES.exists() else {}


def read_boxes():
    try:
        return json.loads(BOXES.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}


def box_stamp():
    try:
        return BOXES.stat().st_mtime_ns
    except FileNotFoundError:
        return 0


def box_ip(box):
    return f"127.77.0.{box['slot']}"


def box_tag(name):
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,23}", name):
        raise UserError("Имя коробки: до 24 строчных латинских букв, цифр и дефисов, сначала буква.")
    return "phonebox-" + name


def check_box_ports(*ports):
    occupied = {box["port"] for box in read_boxes().values()}
    if occupied.intersection(ports):
        raise UserError("Этот порт выделен локальной коробке. Выбери другой порт PhoneHost.")


def box_specs():
    return {"box-" + name: guest("/usr/sbin/nginx", "-c", BOX_CONFIG, container=box_tag(name))
            for name, box in read_boxes().items() if box["ready"] and box["enabled"]}


def box_setup_script(name, address, port, secret_hash=None):
    if secret_hash is not None and not re.fullmatch(r"\$apr1\$[A-Za-z0-9./]{1,8}\$[A-Za-z0-9./]{22}", secret_hash):
        raise UserError("Не удалось проверить формат хэша пароля.")
    auth = '''auth_basic "PhoneHost";
        auth_basic_user_file /opt/phonebox/htpasswd;''' if secret_hash else ""
    credentials = f"""umask 077
cat > /opt/phonebox/htpasswd <<'CREDENTIALS'
host:{secret_hash}
CREDENTIALS
""" if secret_hash else ""
    return f"""set -eu
if [ ! -x /usr/sbin/nginx ]; then
    own_policy=0
    if [ ! -e /usr/sbin/policy-rc.d ] && [ ! -L /usr/sbin/policy-rc.d ]; then
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod 755 /usr/sbin/policy-rc.d
        own_policy=1
    fi
    trap '[ "$own_policy" = 0 ] || rm -f /usr/sbin/policy-rc.d' EXIT
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends nginx ca-certificates
fi
mkdir -p /opt/phonebox /srv/phonebox/www /run /var/lib/nginx
{credentials}
next=$(mktemp /opt/phonebox/.nginx.XXXXXX)
cat > "$next" <<'NGINX'
daemon off;
master_process off;
worker_processes 1;
pid /run/phonebox-nginx.pid;
error_log stderr notice;
events {{ worker_connections 256; }}
http {{
    include /etc/nginx/mime.types;
    access_log off;
    server_tokens off;
    server {{
        listen {address}:{port};
        {auth}
        root /srv/phonebox/www;
        index index.html;
        location = {HEALTH} {{ auth_basic off; return 200 "{HEALTH_BODY.decode()}"; }}
        location / {{ try_files $uri $uri/ =404; }}
    }}
}}
NGINX
/usr/sbin/nginx -t -c "$next" || {{ rm -f "$next"; exit 1; }}
mv -f "$next" {BOX_CONFIG}
if [ ! -e /srv/phonebox/www/index.html ]; then
    printf '%s\n' '<!doctype html><html><meta charset="utf-8"><title>{name} · PhoneBox</title><h1>{name}</h1><p>PhoneBox · {address}:{port}</p></html>' \
        > /srv/phonebox/www/index.html
fi
"""


def manage_box(action, name=None, secret_hash=None):
    conf = read_config()
    if action == "list":
        boxes = read_boxes()
        workers = (rpc("status") or {}).get("workers", {})
        if not boxes:
            print("Коробок пока нет. Создать: phonehost box create myapp")
        for item, box in sorted(boxes.items()):
            state = ("процесс запущен" if workers.get("box-" + item) else "ожидает запуска") if box["enabled"] else "остановлена"
            print(f"  {item:24} http://{box_ip(box)}:{box['port']}  {state if box['ready'] else 'не завершена установка'}")
        return
    tag = box_tag(name)
    with serial():
        boxes = read_boxes()
        box = boxes.get(name)
        if action == "create":
            if box is not None and box["ready"]:
                raise UserError(f"Коробка {name} уже существует.")
            if box is not None and box.get("protected", False) != bool(secret_hash):
                raise UserError("Повтори создание тем же способом: обычная коробка или быстрый сервер с паролем.")
            exists = subprocess.run(guest("/usr/bin/test", "-r", "/etc/debian_version", container=tag),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if box is None:
                if exists:
                    raise UserError(f"Среда {tag} не принадлежит PhoneHost.")
                used = {row["slot"] for row in boxes.values()}
                slot = next((i for i in range(2, 255) if i not in used), None)
                if slot is None:
                    raise UserError("В пуле локальных адресов не осталось свободных мест.")
                port = next(p for p in (8177, 8178, 8179) if p not in (conf["web_port"], conf["ssh_port"]))
                box = {"slot": slot, "port": port, "ready": False, "enabled": False, "protected": bool(secret_hash)}
                port_free(port, box_ip(box))
                boxes[name] = box
                atomic_write(BOXES, json.dumps(boxes) + "\n")
            if not exists:
                subprocess.run(debian_install_command(STATE / "install.log", tag), check=True)
            subprocess.run(guest("/bin/sh", "-s", container=tag),
                           input=box_setup_script(name, box_ip(box), box["port"], secret_hash), text=True, check=True)
            box["ready"] = True
            atomic_write(BOXES, json.dumps(boxes) + "\n")
            print(f"Коробка {name} готова · http://{box_ip(box)}:{box['port']}")
            return
        if box is None or not box["ready"]:
            raise UserError("Коробка не готова. Сначала выполни phonehost box create.")
        if action in ("start", "stop"):
            if action == "start" and not box["enabled"]:
                port_free(box["port"], box_ip(box))
            box["enabled"] = action == "start"
            atomic_write(BOXES, json.dumps(boxes) + "\n")
            if action == "start" and not rpc("status"):
                launch_box_manager()
    if action == "shell":
        subprocess.run(guest(container=tag), check=True)
    elif action == "stop":
        print(f"Остановка коробки {name} запрошена.")
    else:
        until = time.monotonic() + 12
        while time.monotonic() < until:
            if probe_web(box["port"], host=box_ip(box)):
                print(f"Коробка на связи · http://{box_ip(box)}:{box['port']}")
                return
            time.sleep(0.35)
        raise UserError(f"Коробка не ответила. Посмотри phonehost logs box-{name}.")


def quick_server(name=None):
    read_config()
    name = name or "quick-" + secrets.token_hex(3)
    box_tag(name)
    password = secrets.token_urlsafe(15)
    generated = subprocess.run(guest("/usr/bin/openssl", "passwd", "-apr1", "-stdin"),
                               input=password + "\n", text=True, capture_output=True, check=True, timeout=12)
    digest = generated.stdout.strip()
    if not re.fullmatch(r"\$apr1\$[A-Za-z0-9./]{1,8}\$[A-Za-z0-9./]{22}", digest):
        raise UserError("OpenSSL не вернул хэш в ожидаемом формате.")
    manage_box("create", name, secret_hash=digest)
    box = read_boxes()[name]

    def response(auth=None):
        headers = {"Authorization": "Basic " + auth} if auth else {}
        with contextlib.closing(http.client.HTTPConnection(box_ip(box), box["port"], timeout=3)) as conn:
            conn.request("GET", "/", headers=headers)
            return conn.getresponse().status

    token = base64.b64encode(f"host:{password}".encode()).decode()
    try:
        manage_box("start", name)
        if response() != 401 or response(token) != 200:
            raise UserError("Проверка доступа не прошла. Быстрый сервер остановлен.")
    except (UserError, OSError, http.client.HTTPException):
        manage_box("stop", name)
        raise
    print(f"\nСервер  {name}\nАдрес   http://{box_ip(box)}:{box['port']}\nЛогин   host\nПароль  {password}")
    print("Работает внутри телефона. Сохрани пароль: он показывается один раз.")


def manage_service(action, name=None, script=None):
    read_config()
    if action == "list":
        active = (rpc("status") or {}).get("workers", {})
        for app, path in sorted(read_services().items()):
            state = "запущен" if active.get("app-" + app) else "остановлен"
            print(f"{app}  {state}  {path}")
        if not read_services():
            print("Свои службы ещё не добавлены.")
        return
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name):
        raise UserError("Имя службы: 1–32 строчные латинские буквы, цифры и дефисы. Начни с буквы.")
    with serial():
        if rpc("status"):
            raise UserError("Сначала останови PhoneHost: phonehost stop.")
        services = read_services()
        if action == "add":
            if not re.fullmatch(r"/[A-Za-z0-9_./-]+", script) or script.startswith("//"):
                raise UserError("Укажи абсолютный путь к стартовому скрипту внутри Debian.")
            check = subprocess.run(guest("/usr/bin/test", "-f", script), check=False)
            if check.returncode:
                raise UserError(f"Нет файла в Debian: {script}")
            services[name] = script
        else:
            if name not in services:
                raise UserError(f"Служба {name} не найдена.")
            del services[name]
        atomic_write(SERVICES, json.dumps(services, sort_keys=True) + "\n")
    print("Список служб обновлён. Запуск: phonehost start.")


def clean(line):
    return "".join(ch if ch.isprintable() else " " for ch in ANSI.sub("", line)).strip()


def terminal_frame(line, color=80):
    width = shutil.get_terminal_size((80, 24)).columns
    line = line[:max(1, width - 1)]
    tone = f"\033[38;5;{color}m" if "NO_COLOR" not in os.environ else ""
    print("\r\033[2K" + tone + line + ("\033[0m" if tone else ""), end="", flush=True)


class Shark:
    def __init__(self, verbose):
        self.tty = sys.stdout.isatty() and not verbose and os.environ.get("TERM") != "dumb"
        self.color = self.tty and "NO_COLOR" not in os.environ
        self.verbose = verbose
        self.log = STATE / "install.log"
        self.started = time.monotonic() - int(os.environ.pop("PHONEHOST_BOOTSTRAP_SECS", "0"))

    def banner(self):
        color = "\033[38;5;80m" if self.color else ""
        reset = "\033[0m" if color else ""
        print(f"\n  {color}{LOGO}{reset}  {VERSION}\n  Debian поверх Android · Termux\n", flush=True)

    def finish(self, fast):
        if fast:
            return
        left = max(0, math.ceil(self.started + INSTALL_SECONDS - time.monotonic()))
        if not left:
            return
        print(f"  SHARK · финальный экран установки ({left // 60:02}:{left % 60:02})", flush=True)
        if not self.tty:
            time.sleep(max(0, self.started + INSTALL_SECONDS - time.monotonic()))
            return
        tick = 0
        try:
            while (left := self.started + INSTALL_SECONDS - time.monotonic()) > 0:
                marks = list("━" * 16)
                marks[tick % len(marks)] = "◢"
                seconds = math.ceil(left)
                terminal_frame(f"  [{''.join(marks)}] {seconds // 60:02}:{seconds % 60:02}  ·  SHARK")
                tick += 1
                time.sleep(min(left, 0.16))
        finally:
            print("\r\033[2K", end="", flush=True)

    def run(self, index, title, argv, data=None):
        total = 6
        print(f"  [{index:02}/{total:02}] {title}", flush=True)
        with self.log.open("a", encoding="utf-8") as log:
            log.write(f"\n--- [{index}/{total}] {title} ---\n")
            with subprocess.Popen(
                argv, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace",
                env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"},
            ) as proc:
                def collect():
                    for raw in proc.stdout:
                        msg = clean(raw)
                        if msg:
                            messages.put(msg)
                    messages.put(None)

                messages = queue.Queue()
                reader = threading.Thread(target=collect, daemon=True)
                reader.start()
                if data is not None:
                    try:
                        proc.stdin.write(data)
                        proc.stdin.close()
                    except BrokenPipeError:
                        pass
                tick, last = 0, "ожидаем вывод…"
                try:
                    while True:
                        try:
                            msg = messages.get(timeout=0.14)
                        except queue.Empty:
                            msg = ""
                        if msg is None:
                            break
                        if msg:
                            last = msg
                            log.write(msg + "\n")
                            log.flush()
                            if self.verbose:
                                print(f"      {msg}", flush=True)
                        if self.tty:
                            width = shutil.get_terminal_size((80, 24)).columns
                            steps = 12
                            done = (index - 1) * steps // total
                            filler = ["━"] * done + ["─"] * (steps - done)
                            filler[done + tick % (steps - done)] = "◢"
                            bar = "".join(filler)
                            elapsed = int(time.monotonic() - self.started)
                            frame = f"  [{bar}] {elapsed // 60:02}:{elapsed % 60:02}  "
                            frame = (frame + last)[:max(1, width - 1)]
                            if self.color and "]" in frame:
                                frame = "\033[38;5;80m" + frame.replace("]", "]\033[0m", 1)
                            print("\r\033[2K" + frame, end="", flush=True)
                            tick += 1
                except KeyboardInterrupt:
                    proc.terminate()
                    raise
                finally:
                    if self.tty:
                        print("\r\033[2K", end="", flush=True)
                result = proc.wait()
                if result:
                    raise UserError(f"Этап {index} завершился с кодом {result}. Последний вывод: {last}\nЖурнал: {self.log}")
        print(f"      ✓ Готово", flush=True)


def nginx_config(port):
    return f"""daemon off;
master_process off;
worker_processes 1;
pid /run/phonehost-nginx.pid;
error_log stderr notice;
events {{ worker_connections 1024; }}
http {{
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format phonehost escape=json
        '{{"time":"$time_iso8601","epoch":$msec,"ip":"$remote_addr",'
        '"method":"$request_method","path":"$uri","status":"$status",'
        '"bytes":"$body_bytes_sent","seconds":"$request_time"}}';
    access_log {GUEST_LOGS}/access.jsonl phonehost;
    server_tokens off;
    server {{
        listen 0.0.0.0:{port};
        root /srv/phonehost/www;
        index index.html;
        location = {HEALTH} {{
            default_type text/plain;
            return 200 "phonehost-ok";
        }}
        location / {{ try_files $uri $uri/ =404; }}
    }}
}}
"""


def web_setup(port, prepare=False):
    data = f"""set -eu
mkdir -p /opt/phonehost /srv/phonehost/www /run /var/lib/nginx /root/phonehost
next=$(mktemp /opt/phonehost/.nginx.XXXXXXXX)
trap 'rm -f -- "$next"' EXIT
cat > "$next" <<'NGINX'
{nginx_config(port)}NGINX
/usr/sbin/nginx -t -c "$next"
mv -f -- "$next" {GUEST_WEB}
"""
    if prepare:
        data += f"""cat > /opt/phonehost/files.sh <<'FILES'
{FILE_SCRIPT}FILES
if [ ! -e /srv/phonehost/www/index.html ] || grep -Fq 'ONLINE / NGINX</small><h1>PhoneHost' /srv/phonehost/www/index.html; then
    cat > /srv/phonehost/www/index.html <<'SITE'
{SITE}SITE
fi
"""
    return data


def debian_install_command(log, container=CONTAINER):
    pd = binary("proot-distro")
    result = subprocess.run([pd, "install", "--help"], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    help_text = "\n".join(clean(line) for line in result.stdout.splitlines())
    with log.open("a", encoding="utf-8") as file:
        file.write(f"\n--- proot-distro install --help (код {result.returncode}) ---\n{help_text}\n")
    if result.returncode != 0:
        raise UserError(f"Не удалось получить справку proot-distro (код {result.returncode}). Журнал: phonehost logs install.")
    if re.search(r"(?<![\w-])--name\b", help_text):
        return [pd, "install", "--name", container, IMAGE]
    if re.search(r"(?<![\w-])--override-alias\b", help_text):
        return [pd, "install", "--override-alias", container, "debian"]
    raise UserError("В справке proot-distro не нашлись параметры имени контейнера. Журнал: phonehost logs install.")


def install(opts):
    with serial():
        if rpc("status"):
            raise UserError("Сначала останови службы: phonehost stop.")
        old = read_config() if CONFIG.exists() else {}
        web_port = opts.web_port or old.get("web_port", 8080)
        ssh_port = opts.ssh_port or old.get("ssh_port", 8022)
        if web_port == ssh_port:
            raise UserError("Для HTTP и SSH нужны разные порты.")
        check_box_ports(web_port, ssh_port)
        if shutil.disk_usage(STATE).free < 800 * 1024**2:
            print("PhoneHost: свободно меньше 800 МБ. Образ и пакеты могут не поместиться.", file=sys.stderr)
        ui = Shark(opts.verbose)
        ui.banner()
        ui.run(1, "Termux · обновляем списки пакетов", [binary("pkg"), "update", "-y"])
        ui.run(2, "Termux · PRoot и OpenSSH", [binary("pkg"), "install", "-y", "proot-distro", "openssh"])
        exists = subprocess.run(guest("/usr/bin/test", "-r", "/etc/debian_version"),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if exists:
            if not MARKER.exists():
                raise UserError("Среда phonehost уже существует и не принадлежит этому установщику.")
            ui.run(3, "Debian · используем уже установленную среду", guest("/bin/cat", "/etc/debian_version"))
        else:
            ui.run(3, "Debian · скачиваем и распаковываем образ", debian_install_command(ui.log))
            atomic_write(MARKER, "phonehost\n")
        ui.run(4, "Debian · индекс пакетов", guest("/usr/bin/apt-get", "update"))
        ui.run(5, "Debian · Nginx, сертификаты и инструменты", guest("/bin/sh", "-s"), f"""set -eu
own_policy=0
if [ ! -e /usr/sbin/policy-rc.d ] && [ ! -L /usr/sbin/policy-rc.d ]; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    own_policy=1
fi
cleanup() {{
    if [ "$own_policy" = 1 ]; then rm -f /usr/sbin/policy-rc.d; fi
}}
trap cleanup EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends nginx ca-certificates {' '.join(TOOL_PACKAGES)}
mkdir -p /var/log/phonehost
""")
        ui.run(6, "Nginx · сайт, журналы и личная папка", guest("/bin/sh", "-s", logs=True), web_setup(web_port, prepare=True))
        atomic_write(CONFIG, json.dumps({"web_port": web_port, "ssh_port": ssh_port}) + "\n")
        ui.finish(opts.fast)
    print("\n  [━━━━━━━━━━━━]  ГОТОВО\n\n  phonehost console · панель\n  phonehost start · запуск\n  phonehost shell · вход в Debian")
    print(f"\n  Полный лог: {ui.log}\n")


def probe_web(port, timeout=0.7, host="127.0.0.1"):
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", HEALTH, headers={"Connection": "close"})
        res = conn.getresponse()
        ok = res.status == 200 and res.read(64) == HEALTH_BODY
        return ok
    except (OSError, http.client.HTTPException):
        return False
    finally:
        conn.close()


def probe_ssh(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.6) as sock:
            sock.settimeout(0.6)
            return sock.recv(64).startswith(b"SSH-")
    except OSError:
        return False


def rpc(message):
    try:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(2)
            client.connect(str(CONTROL))
            client.sendall(message.encode("ascii") + b"\n")
            with client.makefile("rb") as response:
                line = response.readline(65536)
            return json.loads(line) if line else None
    except (OSError, ValueError):
        return None


def stop_children(processes):
    procs = [proc for proc in processes if proc.poll() is None]
    for proc in procs:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGTERM)
    deadline = time.monotonic() + 3
    for proc in procs:
        try:
            proc.wait(timeout=max(0, deadline - time.monotonic()))
            continue
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()


def start_child(name, argv):
    log = STATE / (name + ".log")
    if log.exists() and log.stat().st_size > 4 * 1024**2:
        log.replace(log.with_name(f"{log.name}.{time.time_ns()}"))
    with log.open("ab") as file:
        file.write(f"\n--- {time.strftime('%Y-%m-%d %H:%M:%S')} ---\n".encode())
        return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=file, stderr=file, start_new_session=True)


def launch_box_manager():
    proc = start_child("supervisor", [sys.executable, str(Path(__file__).resolve()), "_supervise_boxes"])
    limit = time.monotonic() + 5
    while time.monotonic() < limit:
        if rpc("status"):
            return
        if proc.poll() is not None:
            break
        time.sleep(0.1)
    stop_children([proc])
    raise UserError("Локальный менеджер не запустился. Посмотри phonehost logs supervisor.")


def supervise(boxes_only=False):
    config = read_config()
    CONTROL.unlink(missing_ok=True)
    running = True
    children = {}
    retry = {}
    specs = {}
    mode = "boxes" if boxes_only else "all"
    box_version = -1

    def base_specs():
        if mode == "boxes":
            return {}
        base = {"web": guest("/usr/sbin/nginx", "-c", GUEST_WEB, logs=True)}
        for name, path in read_services().items():
            base["app-" + name] = guest("/bin/sh", path)
        if (STATE / "authorized_keys").is_file():
            base["ssh"] = [binary("sshd"), "-D", "-e", "-f", str(STATE / "sshd_config")]
        return base

    def halt(*_):
        nonlocal running
        running = False

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, halt)
    try:
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(CONTROL))
            server.listen(4)
            server.settimeout(0.3)
            while running:
                stamp = box_stamp()
                if stamp != box_version:
                    desired = {**base_specs(), **box_specs()}
                    for name in specs.keys() - desired.keys():
                        if name in children:
                            stop_children([children.pop(name)])
                        retry.pop(name, None)
                    specs, box_version = desired, stamp
                for name, argv in specs.items():
                    proc = children.get(name)
                    if (proc is None or proc.poll() is not None) and time.monotonic() >= retry.get(name, 0):
                        retry[name] = time.monotonic() + 5
                        try:
                            children[name] = start_child(name, argv)
                        except OSError as exc:
                            print(f"{name}: {exc}", file=sys.stderr, flush=True)
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                with conn:
                    try:
                        conn.settimeout(0.3)
                        with conn.makefile("rb") as stream:
                            cmd = stream.readline(64)
                        if cmd == b"stop\n":
                            halt()
                        elif cmd in (b"web-start\n", b"web-stop\n"):
                            mode = "all" if cmd == b"web-start\n" else "boxes"
                            box_version = -1
                        active = {name: name in children and children[name].poll() is None for name in specs}
                        payload = {"running": running, "workers": active, "ports": config, "mode": mode}
                        conn.sendall(json.dumps(payload).encode() + b"\n")
                    except OSError:
                        pass
    finally:
        stop_children(children.values())
        CONTROL.unlink(missing_ok=True)


def port_free(port, host="0.0.0.0"):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((host, port))
        except OSError as exc:
            raise UserError(f"Не могу открыть порт {port} на {host}: {exc.strerror}") from exc


def update_ports(web, ssh):
    with serial():
        config = read_config()
        selected = {"web_port": web or config["web_port"], "ssh_port": ssh or config["ssh_port"]}
        if selected != config:
            if rpc("status"):
                raise UserError("Сначала останови PhoneHost: phonehost stop.")
            if selected["web_port"] == selected["ssh_port"]:
                raise UserError("Для HTTP и SSH нужны разные порты.")
            check_box_ports(*selected.values())
            for key, port in selected.items():
                if port != config[key]:
                    port_free(port)
            if selected["web_port"] != config["web_port"]:
                subprocess.run(guest("/bin/sh", "-s", logs=True), input=web_setup(selected["web_port"]), text=True, check=True)
            atomic_write(CONFIG, json.dumps(selected) + "\n")
    print(f"HTTP {selected['web_port']} · SSH {selected['ssh_port']}")


def guest_files(options):
    read_config()
    relative = options.path
    if relative != "." or options.action != "ls":
        parts = relative.split("/")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", relative) or any(p in (".", "..") for p in parts):
            raise UserError("Нужен относительный путь внутри рабочей папки, без '..'.")
    argv = guest("/bin/sh", "/opt/phonehost/files.sh", "web" if options.web else "root", options.action, relative)
    if options.action != "write":
        subprocess.run(argv, stdin=subprocess.DEVNULL, check=True)
    elif options.text is not None:
        subprocess.run(argv, input=options.text.encode("utf-8"), check=True)
    elif sys.stdin.isatty():
        raise UserError("Передай содержимое через --text или подай файл на stdin.")
    else:
        subprocess.run(argv, check=True)


def start():
    with serial():
        conf = read_config()
        running = rpc("status")
        if running and running.get("mode") != "boxes":
            print("PhoneHost уже запущен. Подробности: phonehost status.")
            return
        port_free(conf["web_port"])
        with_ssh = (STATE / "authorized_keys").is_file()
        if with_ssh:
            port_free(conf["ssh_port"])
            render_sshd(conf["ssh_port"])
        if running:
            if not rpc("web-start"):
                raise UserError("Менеджер коробок не ответил.")
            proc = None
        else:
            proc = start_child("supervisor", [sys.executable, str(Path(__file__).resolve()), "_supervise"])
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline:
            if (rpc("status") and probe_web(conf["web_port"])
                    and (not with_ssh or probe_ssh(conf["ssh_port"]))):
                status()
                return
            if proc is not None and proc.poll() is not None:
                break
            time.sleep(0.25)
        if proc is None:
            rpc("web-stop")
        elif rpc("stop") is None:
            stop_children([proc])
        raise UserError("Сервисы не ответили после запуска. Проверь phonehost logs web, ssh и supervisor.")


def stop():
    with serial():
        if rpc("stop") is None:
            print("PhoneHost не запущен.")
            return
        deadline = time.monotonic() + 9
        while CONTROL.exists() and time.monotonic() < deadline:
            time.sleep(0.15)
        if CONTROL.exists():
            raise UserError("Остановка ещё не завершилась. Проверь phonehost status.")
        print("PhoneHost остановлен.")


def current_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            # connect() chooses the route; UDP sends nothing until send().
            sock.connect(("192.0.2.1", 9))
            return sock.getsockname()[0]
    except OSError:
        return None


def status():
    conf = read_config()
    running = rpc("status")
    if not running:
        print("PhoneHost остановлен. Запуск: phonehost start.")
        return
    ip = current_ip()
    web_ok = running["workers"].get("web") and probe_web(conf["web_port"])
    ssh_on = "ssh" in running["workers"]
    ssh_ok = ssh_on and running["workers"]["ssh"] and probe_ssh(conf["ssh_port"])
    print(f"PhoneHost {VERSION} · Debian в Termux")
    if running.get("mode") == "boxes":
        print("  Менеджер коробок запущен. Основной HTTP-сервер и SSH выключены.")
        return
    print(f"  HTTP  {'OK' if web_ok else 'нет ответа'}   http://127.0.0.1:{conf['web_port']}")
    if ip and ip != "127.0.0.1":
        print(f"  IPv4 выбранной сети   http://{ip}:{conf['web_port']}")
    if ssh_ok:
        print(f"  SSH   OK   ssh -p {conf['ssh_port']} {getpass.getuser()}@{ip or '<IP-телефона>'}")
    elif ssh_on:
        print("  SSH   нет ответа · phonehost logs ssh")
    else:
        print("  SSH   отключён · перед запуском добавь публичный ключ: phonehost ssh-key /путь/к/ключу.pub")
    for name, active in sorted(running["workers"].items()):
        if name.startswith("app-"):
            print(f"  {name}   {'процесс запущен' if active else 'процесс остановлен'}")


def quote_sshd(value):
    if any(ch in value for ch in ('\n', '\r', '"', "\\")):
        raise UserError("Путь установки содержит символы, которые нельзя использовать в sshd_config.")
    return f'"{value}"'


def render_sshd(port):
    host_key = STATE / "ssh_host_ed25519_key"
    if not host_key.is_file():
        subprocess.run([binary("ssh-keygen"), "-q", "-t", "ed25519", "-N", "", "-f", str(host_key)], check=True)
    runner = PREFIX / "bin" / "phonehost"
    conf = STATE / "sshd_config"
    conf_text = f"""Port {port}
AddressFamily inet
ListenAddress 0.0.0.0
HostKey {quote_sshd(str(host_key))}
PidFile {quote_sshd(str(STATE / "sshd.pid"))}
AuthorizedKeysFile {quote_sshd(str(STATE / "authorized_keys"))}
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
StrictModes yes
PermitUserEnvironment no
AllowUsers {getpass.getuser()}
DisableForwarding yes
ForceCommand {quote_sshd(str(runner))} _shell_remote
LogLevel INFO
"""
    atomic_write(conf, conf_text)
    subprocess.run([binary("sshd"), "-t", "-f", str(conf)], check=True)


def add_key(path):
    read_config()
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1:
        raise UserError("Нужна одна строка из файла публичного SSH-ключа (.pub).")
    parts = lines[0].split(maxsplit=2)
    if len(parts) < 2 or not re.fullmatch(r"ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)", parts[0]):
        raise UserError("Укажи публичный SSH-ключ Ed25519, RSA или ECDSA, не приватный файл.")
    try:
        raw = base64.b64decode(parts[1], validate=True)
        size = int.from_bytes(raw[:4], "big")
        if raw[4:4 + size] != parts[0].encode() or len(raw) <= 4 + size:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise UserError("Файл не похож на корректный публичный SSH-ключ.") from None
    value = " ".join(parts[:2])
    with serial():
        authorized = STATE / "authorized_keys"
        keys = authorized.read_text(encoding="utf-8").splitlines() if authorized.exists() else []
        if value not in keys:
            atomic_write(authorized, "\n".join([*keys, value]) + "\n")
    print("Публичный ключ добавлен. Если PhoneHost уже запущен, выполни phonehost stop, затем phonehost start.")


def boot(enable):
    target = Path.home() / ".termux" / "boot" / "phonehost"
    if not enable:
        target.unlink(missing_ok=True)
        print("Автозапуск PhoneHost выключен.")
        return
    read_config()
    target.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(target, f'#!{PREFIX}/bin/sh\nexec "{PREFIX}/bin/phonehost" start >> "{STATE}/boot.log" 2>&1\n', 0o700)
    print("Скрипт автозапуска готов. Установи Termux:Boot из того же источника, что и Termux, и открой его один раз.")


def bench(count, workers):
    conf = read_config()
    if not rpc("status") or not probe_web(conf["web_port"]):
        raise UserError("Тестовый Nginx не отвечает. Сначала выполни phonehost start.")
    port = conf["web_port"]

    def hit(batch):
        ok = []
        errors = 0
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            for _ in range(batch):
                t0 = time.perf_counter()
                try:
                    conn.request("GET", "/")
                    response = conn.getresponse()
                    response.read()
                    if response.status == 200:
                        ok.append((time.perf_counter() - t0) * 1000)
                    else:
                        errors += 1
                except (OSError, http.client.HTTPException):
                    conn.close()
                    errors += 1
        finally:
            conn.close()
        return ok, errors

    workers = min(workers, count)
    print(f"HTTP localhost · {count} запросов · параллельность {workers}", flush=True)
    started = time.perf_counter()
    latencies, failures = [], 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for samples, errors in pool.map(hit, [count // workers + (i < count % workers) for i in range(workers)]):
            latencies.extend(samples)
            failures += errors
    elapsed = time.perf_counter() - started
    print(f"Успешно: {len(latencies)}/{count} · ошибок: {failures} · {len(latencies) / elapsed:.1f} успешных запросов/с")
    if latencies:
        latencies.sort()
        p95 = latencies[math.ceil(len(latencies) * 0.95) - 1]
        print(f"Задержка p50: {statistics.median(latencies):.2f} мс · p95: {p95:.2f} мс")
    print("Замер только для локальной веб-страницы. Он не измеряет Wi-Fi, API или базу данных.")


def log_paths(name):
    if name == "all":
        live = (p.name[:-4] for p in sorted(STATE.glob("app-*.log")))
        names = dict.fromkeys((*BASE_LOGS, *("app-" + n for n in read_services()),
                               *("box-" + n for n in read_boxes()), *live))
        return {n: ACCESS if n == "access" else STATE / (n + ".log") for n in names}
    if name not in BASE_LOGS and not re.fullmatch(r"(?:app|box)-[a-z][a-z0-9-]{0,31}", name):
        raise UserError("Неизвестный журнал. Пример: phonehost logs access.")
    return {name: ACCESS if name == "access" else STATE / (name + ".log")}


def tail_start(file, count):
    end = file.seek(0, os.SEEK_END)
    if not end:
        return 0
    file.seek(end - 1)
    count += file.read(1) == b"\n"
    pos = end
    while pos:
        start = max(0, pos - 16384)
        file.seek(start)
        block = file.read(pos - start)
        found = block.count(b"\n")
        if found >= count:
            remainder = len(block.rsplit(b"\n", count)[0])
            return start + remainder + 1
        count -= found
        pos = start
    return 0


def logs(name, lines, history, follow):
    paths = log_paths(name)
    positions = {}
    shown = False

    def read_new(src, path, initial=False):
        nonlocal shown
        try:
            with path.open("rb") as file:
                stat = os.fstat(file.fileno())
                inode = (stat.st_dev, stat.st_ino)
                prev, offset = positions.get(src, (inode, 0))
                if initial:
                    offset = 0 if history else tail_start(file, lines)
                elif prev != inode or offset > stat.st_size:
                    offset = 0
                file.seek(offset)
                while raw := file.readline():
                    if follow and not raw.endswith(b"\n"):
                        break
                    offset = file.tell()
                    text = clean(raw.decode("utf-8", "replace"))
                    print(f"[{src}] {text}" if name == "all" else text, flush=follow)
                    shown = True
                positions[src] = (inode, offset)
        except FileNotFoundError:
            return

    for src, path in paths.items():
        if history and src != "access":
            for archive in sorted(path.parent.glob(path.name + ".*")):
                read_new(src, archive, initial=True)
        read_new(src, path, initial=True)
    if follow:
        while True:
            for src, path in log_paths(name).items():
                read_new(src, path)
            time.sleep(0.35)
    elif not shown:
        print(f"Журнал {name} пока пуст.")


def traffic(minutes, top):
    addresses, codes = Counter(), Counter()
    boundary = time.time() - minutes * 60 if minutes else 0
    total_bytes, seconds, ignored = 0, 0.0, 0
    if ACCESS.is_file():
        with ACCESS.open("r", encoding="utf-8", errors="replace") as file:
            for row in file:
                try:
                    event = json.loads(row)
                    if event["path"] == HEALTH or float(event["epoch"]) < boundary:
                        continue
                    ip, status = event["ip"], int(event["status"])
                    size, duration = int(event["bytes"]), float(event["seconds"])
                except (ValueError, TypeError, KeyError):
                    ignored += 1
                    continue
                addresses[ip] += 1
                codes[status] += 1
                total_bytes += size
                seconds += duration
    total = sum(addresses.values())
    period = f"последние {minutes} мин." if minutes else "весь журнал"
    print(f"HTTP · {period} · {total} запросов · {len(addresses)} уникальных IP")
    if total:
        print(f"  Ответы: {'  '.join(f'{code} × {count}' for code, count in sorted(codes.items()))}")
        print(f"  Тела ответов: {total_bytes:,} байт · среднее время: {1000 * seconds / total:.1f} мс")
        for ip, count in addresses.most_common(top):
            print(f"  {clean(ip):>18}  {count:,}")
    if ignored:
        print(f"  Пропущены неполные или нечитаемые строки: {ignored}")


def doctor():
    usage = shutil.disk_usage(STATE)
    print(f"{LOGO}\n  Версия {VERSION} · {platform.machine()} · ядро {platform.release()}")
    print(f"  Память устройства: свободно {usage.free / 1024**3:.1f} из {usage.total / 1024**3:.1f} ГиБ")
    try:
        memory = Path("/proc/meminfo").read_text()
        total = re.search(r"^MemTotal:\s+(\d+)", memory, re.M)
        if total:
            print(f"  RAM: {int(total[1]) / 1024**2:.1f} ГиБ")
    except OSError:
        pass
    print("  Debian: " + ("настроен" if CONFIG.exists() else "не настроен"))
    print("  Журнал HTTP: " + (f"{ACCESS.stat().st_size:,} байт" if ACCESS.exists() else "пока пуст"))
    if CONFIG.exists():
        status()


def shark_show(mode, seconds):
    tty = sys.stdout.isatty() and os.environ.get("TERM") != "dumb"
    heading = {"ddos": "DDoS / INBOUND", "sonar": "SONAR / SWEEP", "prank": "SHARK / OPERATOR"}[mode]
    print(f"\n  {LOGO}  ·  {heading}\n", flush=True)
    if mode == "prank":
        lines = ("Оператор найден.", "Проверяю наличие кофе…", "Кофе не найден.",
                 "Перехожу на резервный протокол.", "Акуле выдано право на мемы.")
        for index, line in enumerate(lines):
            if index:
                time.sleep(seconds / (len(lines) - 1))
            print(f"  [{index + 1:02}] {line}", flush=True)
        return
    rng = random.Random()
    started = time.monotonic()
    packets, tick = 0, 0
    while (elapsed := time.monotonic() - started) < seconds:
        if mode == "ddos":
            packet_rate = rng.randrange(9000, 92000)
            packets += round(packet_rate * (0.13 if tty else 1))
            source = rng.choice(("192.0.2.", "198.51.100.", "203.0.113.")) + str(rng.randrange(1, 255))
            level = min(18, math.ceil(packet_rate / 5200))
            frame = f"  RX {source:<15} {'━' * level}{'─' * (18 - level)} {packet_rate:>6,} pkt/s"
            color = 203
        else:
            position = tick % 18
            sweep = "·" * position + "◢" + "·" * (17 - position)
            frame = f"  SONAR  [{sweep}]  сектор {position + 1:02}/18  {int(elapsed):02}s"
            color = 80
        if tty:
            terminal_frame(frame, color)
        else:
            print(frame, flush=True)
        tick += 1
        time.sleep(min(0.13 if tty else 1.0, max(0, seconds - elapsed)))
    if tty:
        print("\r\033[2K", end="")
    summary = f" · RX {packets:,} pkt" if mode == "ddos" else ""
    print(f"  ■ Сеанс завершён{summary}", flush=True)


def int_range(low, high):
    def parse(value):
        try:
            number = int(value)
        except ValueError:
            number = -1
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"нужно целое число от {low} до {high}")
        return number
    return parse


RDAP_REGISTRIES = frozenset((
    "data.iana.org", "rdap.arin.net", "rdap.apnic.net",
    "rdap.db.ripe.net", "rdap.lacnic.net", "rdap.afrinic.net",
))


def registry_url(url):
    parts = urlsplit(url)
    return (parts.scheme == "https" and parts.hostname in RDAP_REGISTRIES
            and parts.username is None and parts.password is None and parts.port in (None, 443))


class RegistryRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not registry_url(newurl):
            raise UserError("RDAP ответил перенаправлением за пределы поддерживаемых реестров.")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def registry_json(url):
    if not registry_url(url):
        raise UserError("Поддерживаются только HTTPS-адреса реестров IANA и RIR.")
    with build_opener(RegistryRedirect()).open(
        Request(url, headers={"Accept": "application/rdap+json, application/json", "User-Agent": f"PhoneHost/{VERSION}"}),
        timeout=8,
    ) as response:
        data = response.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise UserError("Ответ реестра слишком большой.")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise UserError("Реестр не вернул JSON-объект.")
    return value


def rdap_endpoint(address, bootstrap):
    match = None
    for group in bootstrap.get("services", ()):
        if not isinstance(group, list) or len(group) != 2:
            continue
        ranges, urls = group
        base = next((url for url in urls if registry_url(url)), None)
        if not base:
            continue
        for raw in ranges:
            network = ipaddress.ip_network(raw)
            if address in network and (match is None or network.prefixlen > match[0]):
                match = (network.prefixlen, base)
    if match is None:
        raise UserError("Реестр для этого IP не найден.")
    return match[1].rstrip("/") + "/ip/" + str(address)


def rdap_lookup(raw_ip):
    address = ipaddress.ip_address(raw_ip)
    if address.version == 6 and address.ipv4_mapped:
        address = address.ipv4_mapped
    if (not address.is_global or address.is_multicast or address.is_reserved
            or getattr(address, "scope_id", None)):
        raise UserError("У локального или специального адреса нет провайдера в RDAP. Запрос не отправлен.")
    bootstrap = registry_json(f"https://data.iana.org/rdap/ipv{address.version}.json")
    url = rdap_endpoint(address, bootstrap)
    record = registry_json(url)
    print(f"IP             {address}")
    print(f"Регистрация    {clean(str(record.get('name') or record.get('handle') or 'не указана'))}")
    if record.get("startAddress") and record.get("endAddress"):
        print(f"Диапазон       {clean(str(record['startAddress']))} — {clean(str(record['endAddress']))}")
    holders = set()
    for entity in record.get("entities", []):
        if not isinstance(entity, dict) or "registrant" not in entity.get("roles", ()):
            continue
        cards = entity.get("vcardArray")
        if not isinstance(cards, list) or len(cards) != 2 or not isinstance(cards[1], list):
            continue
        fields = {row[0]: row[3] for row in cards[1] if isinstance(row, list) and len(row) >= 4}
        name = fields.get("org") or (fields.get("fn") if fields.get("kind") == "org" else None)
        if isinstance(name, list):
            name = next((n for n in name if isinstance(n, str) and n.strip()), None)
        if isinstance(name, str) and clean(name):
            holders.add(clean(name)[:160])
    if holders:
        print("Организация    " + ", ".join(sorted(holders)))
    print(f"Реестр         {urlsplit(url).hostname}")
    print("Это регистрация диапазона, а не имя владельца устройства или обязательно его оператор.")


def dns_domain(raw):
    text = raw.rstrip(".").encode("idna").decode("ascii")
    label = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    if len(text) > 253 or not re.fullmatch(rf"{label}(?:\.{label})*", text):
        raise UserError("Укажи имя домена без URL, порта и параметров.")
    return text + "."


def toolbox(opts):
    if opts.action == "list":
        print("dns    DNS-записи · dig из Debian")
        print("rdap   Регистрация публичного IP · IANA/RDAP")
        print("hash   SHA-256 локального файла · Python")
        print("console  Инвентарь, TLS, формат файла, EXIF и управление")
        print("install  Восстановить стандартный набор пакетов Debian")
    elif opts.action == "install":
        read_config()
        subprocess.run(guest("/usr/bin/apt-get", "update"), check=True)
        subprocess.run(guest("/usr/bin/apt-get", "install", "-y", "--no-install-recommends",
                             *TOOL_PACKAGES), check=True)
    elif opts.action == "dns":
        read_config()
        domain = dns_domain(opts.domain)
        probe = subprocess.run(guest("/usr/bin/test", "-x", "/usr/bin/dig"), check=False)
        if probe.returncode != 0:
            raise UserError("Установи DNS-инструменты командой phonehost toolbox install.")
        subprocess.run(guest("/usr/bin/dig", domain, opts.type, "+time=3", "+tries=1",
                             "+noall", "+comments", "+answer"), check=True)
    elif opts.action == "rdap":
        rdap_lookup(opts.ip)
    elif opts.action == "hash":
        digest = hashlib.sha256()
        with opts.path.open("rb") as file:
            for block in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(block)
        print(f"{digest.hexdigest()}  {clean(str(opts.path))}")


def public_ip():
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, *_args):
            raise UserError("Проверка внешнего IP неожиданно попросила перенаправление.")

    print("Внешняя проверка · запрос к api64.ipify.org", flush=True)
    with build_opener(NoRedirect()).open("https://api64.ipify.org?format=json", timeout=8) as response:
        payload = json.loads(response.read(2048))
    return ipaddress.ip_address(payload["ip"])


def public_address():
    print(f"IP, который увидел сервис: {public_ip()}")


def ap_public_provider():
    address = public_ip()
    print(f"Внешний IP самого телефона · {address}")
    print("Это адрес выхода Termux. Маршрут раздачи и подключённого устройства может отличаться.")
    rdap_lookup(str(address))


def local_network():
    print("Адрес выбранного маршрута: " + (current_ip() or "недоступен"))
    ip_tool = Path("/system/bin/ip") if Path("/system/bin/ip").is_file() else shutil.which("ip")
    if not ip_tool:
        print("Системная команда маршрутов недоступна.")
        return
    result = subprocess.run([str(ip_tool), "-4", "route", "show", "default"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=4)
    routes = result.stdout.splitlines() if result.returncode == 0 else []
    if not routes:
        print("Android не показал маршрут по умолчанию. Адрес шлюза можно посмотреть в настройках сети.")
    for route in routes:
        fields = route.split()
        if len(fields) >= 3 and fields[0:2] == ["default", "via"]:
            print(f"Шлюз: {ipaddress.ip_address(fields[2])}")
        if "dev" in fields and fields.index("dev") + 1 < len(fields):
            print("Интерфейс: " + clean(fields[fields.index("dev") + 1]))


IFACE_NAME = r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}"
NEIGH_STATES = ("REACHABLE", "STALE", "DELAY", "PROBE", "PERMANENT", "NOARP")


def system_probe(argv, root):
    if root:
        su = shutil.which("su") or ("/system/bin/su" if Path("/system/bin/su").is_file() else None)
        if not su:
            raise UserError("На этом Android не найден su.")
        args = [su, "-c", shlex.join(argv)]
    else:
        args = argv
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, encoding="utf-8", errors="replace", timeout=18)
    if result.returncode or re.search(r"permission denial|permission denied|not permitted",
                                      result.stdout[:256] + "\n" + result.stderr, re.I):
        if not root:
            raise UserError("Android не дал прочитать системные данные. Можно проверить из меню с root, если он есть.")
        raise UserError("Android или менеджер root не дал прочитать системные данные.")
    return result.stdout


def selected_wifi_iface(routes):
    for row in routes.splitlines():
        fields = row.split()
        if "dev" not in fields or fields.index("dev") + 1 >= len(fields):
            continue
        iface = fields[fields.index("dev") + 1]
        if re.fullmatch(r"(?:wlan|swlan|wifi)\d{1,3}", iface):
            return iface
    return None


def parse_neighbours(raw, iface):
    rows = {}
    for line in raw.splitlines():
        fields = line.split()
        if not fields or "lladdr" not in fields:
            continue
        if "dev" in fields:
            at = fields.index("dev") + 1
            if at >= len(fields) or fields[at] != iface:
                continue
        state = next((value for value in reversed(fields) if value in NEIGH_STATES), None)
        if not state or any(value in fields for value in ("FAILED", "INCOMPLETE")):
            continue
        try:
            ip = ipaddress.ip_address(fields[0].split("%", 1)[0])
        except ValueError:
            continue
        if not (ip.is_loopback or ip.is_multicast or ip.is_unspecified):
            rows[ip] = state
    return sorted(rows.items(), key=lambda row: (row[0].version, int(row[0])))


def parse_softap(dump):
    matches = list(re.finditer(r"(?m)^[ \t]*Dump of SoftApManager(?:[ \t][^\r\n]*)?$", dump))
    active = {}
    for header in matches:
        lines = []
        for line in dump[header.end():].splitlines()[1:23]:
            if re.match(r"^[ \t]*Dump of ", line):
                break
            lines.append(line)
        block = "\n".join(lines)
        iface = re.search(rf"(?m)^[ \t]*mApInterfaceName:[ \t]*({IFACE_NAME})[ \t]*$", block)
        up = re.search(r"(?m)^[ \t]*mIfaceIsUp:[ \t]*true[ \t]*$", block)
        if not iface or not up or iface[1] == "null":
            continue
        count = re.search(r"(?m)^[ \t]*getConnectedClientList\(\)\.size\(\):[ \t]*(\d{1,4})[ \t]*$", block)
        active[iface[1]] = int(count[1]) if count else None
    if active:
        return "on", active
    complete = all(marker in dump for marker in ("Dump of ActiveModeWarden", "NumActiveModeManagers:",
                                                "STA + STA Concurrency Supported:"))
    if complete and not matches:
        return "off", {}
    return "unknown", {}


def print_neighbours(iface, root):
    if not re.fullmatch(IFACE_NAME, iface):
        raise UserError("Android вернул неизвестное имя интерфейса.")
    rows = parse_neighbours(system_probe(["/system/bin/ip", "neigh", "show", "dev", iface], root), iface)
    print(f"IP в кэше Android · {iface} · {len(rows)}")
    for ip, state in rows:
        print(f"  {str(ip):39} {state}")
    if not rows:
        print("Записей пока нет. Это не означает, что других устройств нет.")


def network_inventory(mode, root=False):
    if not Path("/system/bin").is_dir():
        raise UserError("Системный инвентарь доступен в Termux на Android.")
    if mode == "wifi":
        routes = system_probe(["/system/bin/ip", "-4", "route", "get", "192.0.2.1"], root)
        iface = selected_wifi_iface(routes)
        if iface is None:
            print("Android не показал Wi-Fi как активный маршрут. Проверь подключение или используй DHCP-таблицу своего роутера.")
            return
        print_neighbours(iface, root)
        print("Пассивный просмотр кэша · записи могут быть устаревшими, полного списка нет.")
        return
    ap_print_status(ap_snapshot(root), False)


AP_MAC = r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"
AP_ERRORS = (UserError, OSError, subprocess.SubprocessError)


def ap_probe(argv, root):
    try:
        return system_probe(argv, root)
    except AP_ERRORS:
        return ""


def ap_status(root):
    if not Path("/system/bin/dumpsys").is_file():
        return "unknown", {}
    state, active = parse_softap(ap_probe(["/system/bin/dumpsys", "-t", "4", "wifi"], root))
    if not active:
        tether = ap_probe(["/system/bin/dumpsys", "-t", "4", "tethering", "--short"], root)
        visible = dict.fromkeys(m[1] for m in re.finditer(
            r"(?m)^[ \t]*((?:wlan|swlan|wifi|ap|softap)\d{1,3}) - (?:TetheredState|LocalHotspotState) -", tether))
        if visible:
            return "on", visible
    return state, active


def ap_settings():
    am = "/system/bin/am"
    if not Path(am).is_file():
        raise UserError("Настройки точки доступа доступны только на Android.")
    for action in ("com.android.settings.WIFI_TETHER_SETTINGS", "android.settings.TETHER_SETTINGS",
                   "android.settings.WIRELESS_SETTINGS"):
        try:
            reply = system_probe([am, "start", "-a", action], False)
            if not re.search(r"Error|unable to resolve|Exception", reply, re.I):
                return
        except AP_ERRORS:
            continue
    raise UserError("Android не открыл настройки. Открой «Мобильная точка доступа» вручную.")


def ap_start():
    if ap_status(True)[0] != "off":
        raise UserError("Точка уже включена или её состояние неизвестно. Используй настройки Android.")
    ssid = "Shark-" + secrets.token_hex(2).upper()
    password = secrets.token_hex(7)
    # Prefer Android's LocalOnlyHotspot when present. Neither shell path promises Internet tethering.
    base = ["/system/bin/cmd", "wifi"]
    help_text = ap_probe(base + ["help"], True)
    action = "start-lohs" if re.search(r"(?m)^\s*start-lohs\s+<ssid>", help_text) else "start-softap"
    system_probe(base + [action, ssid, "wpa2", password, "-b", "2"], True)
    for attempt in range(4):
        if ap_status(True)[0] == "on":
            return ssid, password
        if attempt < 3:
            time.sleep(0.4)
    raise UserError("Android не подтвердил запуск. Проверь состояние в настройках перед повтором.")


def ap_interfaces(raw, active):
    networks = {iface: [] for iface in active}
    for line in raw.splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[2] not in ("inet", "inet6"):
            continue
        iface = fields[1].split("@")[0]
        if iface in networks:
            try:
                networks[iface].append(ipaddress.ip_interface(fields[3]))
            except ValueError:
                continue
    return networks


def ap_local_ip(raw):
    try:
        ip = ipaddress.ip_address(raw.split("%", 1)[0])
    except ValueError:
        return None
    if not (ip.is_unspecified or ip.is_loopback or ip.is_multicast):
        return ip
    return None


def ap_hostname(raw):
    value = case_text(raw, 64)
    return value if value.casefold() not in ("null", "<unknown>", "unknown", "*", "-") else ""


def ap_names(tether, leases, now):
    names = {}
    # Only explicit TYPE_WIFI client records are used (Android TETHERING_WIFI == 0).
    # Some builds don't include client records in dumpsys at all.
    for row in re.finditer(rf"TetheredClient\s*\{{hwAddr\s+({AP_MAC}),\s*addresses\s*\[([^\]]{{0,1800}})\]"
                           r"\s*,\s*tetheringType\s+0\s*\}", tether):
        for item in re.finditer(r"AddressInfo\s*\{([0-9A-Fa-f:.%]+)/(\d+),\s*hostname\s+([^}]{1,96})\}", row[2]):
            ip, name = ap_local_ip(item[1]), ap_hostname(item[3])
            if ip and name:
                names[(row[1].lower(), str(ip))] = (name, "Android DHCP")
    # Older Android can expose the actual dnsmasq lease file. Never use hostname without matching MAC+IP.
    for line in leases.splitlines()[:1024]:
        fields = line.split()
        if len(fields) != 5 or not fields[0].isdecimal() or not re.fullmatch(AP_MAC, fields[1]):
            continue
        if len(fields[0]) > 12:
            continue
        expiry = int(fields[0])
        ip, name = ap_local_ip(fields[2]), ap_hostname(fields[3])
        if ip and name and (expiry == 0 or expiry > now):
            names.setdefault((fields[1].lower(), str(ip)), (name, "аренда DHCP"))
    return names


def ap_neighbours(raw, iface, networks, names, count):
    if count == 0:
        return []
    current = {str(entry.ip) for entry in networks}
    rows = {}
    for row in raw.splitlines():
        parts = row.split()
        if len(parts) < 4 or "lladdr" not in parts or "FAILED" in parts or "INCOMPLETE" in parts:
            continue
        state = next((p for p in reversed(parts) if p in ("REACHABLE", "STALE", "DELAY", "PROBE")), None)
        if not state or ("dev" in parts and parts[parts.index("dev") + 1:parts.index("dev") + 2] != [iface]):
            continue
        mac = parts[parts.index("lladdr") + 1:parts.index("lladdr") + 2]
        ip = ap_local_ip(parts[0])
        if not ip or str(ip) in current or not mac or not re.fullmatch(AP_MAC, mac[0]):
            continue
        matching = next((entry for entry in networks if ip.version == entry.version and ip in entry.network), None)
        if networks and not matching:
            continue
        key = mac[0].lower()
        name, name_source = names.get((key, str(ip)), ("", ""))
        rows[str(ip)] = {"ip": str(ip), "iface": iface, "state": state, "mac": key,
                         "name": name, "name_source": name_source, "source": "кэш соседей Android",
                         "network": str(matching.network) if matching else "",
                         "gateway": str(matching.ip) if matching else ""}
    # Clients with a matching, current Android lease but no neighbour cache entry are shown separately.
    for (mac, raw_ip), (name, source) in names.items():
        ip = ap_local_ip(raw_ip)
        if not ip or raw_ip in current or raw_ip in rows:
            continue
        matching = next((entry for entry in networks if ip.version == entry.version and ip in entry.network), None)
        if matching and count is not None and count > 0:
            rows[raw_ip] = {"ip": raw_ip, "iface": iface, "state": "DHCP", "mac": mac, "name": name,
                            "name_source": source, "source": "аренда, подключение не подтверждено",
                            "network": str(matching.network), "gateway": str(matching.ip)}
    return sorted(rows.values(), key=lambda row: (":" in row["ip"], int(ipaddress.ip_address(row["ip"]))))


def ap_upstream(dump, carrier):
    match = re.search(r"(?m)^\s*Current upstream interface\(s\):[^\S\n]*(.{1,240})$", dump)
    if not match:
        return ""
    interfaces = set(re.findall(IFACE_NAME, match[1])) - {"null", "none", "None"}
    if not interfaces:
        return ""
    if any(iface.startswith(("rmnet", "ccmni", "pdp", "wwan", "cell", "v4-rmnet")) for iface in interfaces):
        operators = list(dict.fromkeys(case_text(p, 48) for p in carrier.strip().split(",") if case_text(p, 48)))
        return "Сотовая сеть хотспота" + (" · Android сообщает: " + ", ".join(operators[:3]) if operators else "")
    return "Внешний интерфейс хотспота · " + ", ".join(sorted(interfaces))


def ap_snapshot(root):
    state, active = ap_status(root)
    data = {"state": state, "active": active, "upstream": "", "clients": []}
    if state != "on":
        return data
    tether = ap_probe(["/system/bin/dumpsys", "-t", "4", "tethering", "--short"], root)
    carrier = ""
    if ap_upstream(tether, "").startswith("Сотовая"):
        carrier = ap_probe(["/system/bin/getprop", "gsm.operator.alpha"], False)
    tethered_ifaces = {m[1] for m in re.finditer(rf"(?m)^[ \t]*({IFACE_NAME}) - TetheredState -", tether)}
    if tethered_ifaces.intersection(active):
        data["upstream"] = ap_upstream(tether, carrier)
    addresses = ap_probe(["/system/bin/ip", "-o", "address", "show"], root)
    networks = ap_interfaces(addresses, active)
    leases = ""
    if root and not any("TetheredClient {hwAddr " in line for line in tether.splitlines()):
        leases = ap_probe(["/system/bin/head", "-c", "65536", "/data/misc/dhcp/dnsmasq.leases"], True)
    names = ap_names(tether, leases, time.time())
    for iface, count in sorted(active.items()):
        if count != 0:
            raw = ap_probe(["/system/bin/ip", "neigh", "show", "dev", iface], root)
            data["clients"].extend(ap_neighbours(raw, iface, networks[iface], names, count))
    return data


def ap_print_status(snapshot, as_json):
    if as_json:
        print(json.dumps(snapshot, ensure_ascii=False, indent=2))
        return
    print({"on": "Точка доступа включена.", "off": "Точка доступа выключена.",
           "unknown": "Android не показал состояние точки доступа."}[snapshot["state"]])
    if snapshot["upstream"]:
        print(snapshot["upstream"])
    for row in snapshot["clients"]:
        print(f"  {row['ip']:39} {row['name'] or 'имя не сообщено'} · {row['state']}")
    if snapshot["state"] == "on":
        print("Показаны доступные записи, а не гарантированно все подключения.")


def ap_card(client, upstream):
    mac = client["mac"]
    randomized = int(mac[:2], 16) & 2
    return [
        "IP · " + client["ip"],
        "Устройство · " + (client["name"] or "имя не сообщено"),
        "Интерфейс · " + client["iface"],
        "Состояние · " + client["state"],
        "Источник IP · " + client["source"],
        "Источник имени · " + (client["name_source"] or "—"),
        "MAC · " + mac + (" (локальный, возможно случайный)" if randomized else ""),
        "Подсеть · " + (client["network"] or "—"),
        "Адрес точки · " + (client["gateway"] or "—"),
        "",
        upstream or "Провайдер точки · неизвестен",
        "Это сеть раздающего телефона, не оператор SIM клиента.",
    ]


def recent_clients(path, limit=1500):
    counts, last = Counter(), {}
    try:
        file = path.open("rb")
    except FileNotFoundError:
        return []
    with file:
        file.seek(tail_start(file, limit))
        for line in file:
            try:
                row = json.loads(line)
                if row["path"] == HEALTH:
                    continue
                ip = str(ipaddress.ip_address(row["ip"]))
                when = float(row["epoch"])
                if not math.isfinite(when) or not 0 <= when < 253402300799:
                    continue
            except (ValueError, TypeError, KeyError):
                continue
            counts[ip] += 1
            last[ip] = max(last.get(ip, 0), when)
    return sorted(((ip, counts[ip], when) for ip, when in last.items()),
                  key=lambda row: row[2], reverse=True)


def show_clients():
    rows = recent_clients(ACCESS)
    print(f"Уникальных адресов в последних 1500 записях HTTP: {len(rows)}")
    for ip, count, when in rows:
        print(f"  {ip:39} {count:5}  {time.strftime('%d.%m %H:%M:%S', time.localtime(when))}")
    print("Это клиенты PhoneHost, а не список всех устройств Wi-Fi.")


def own_leases(path, now):
    with path.open("rb") as f:
        raw = f.read(512 * 1024 + 1)
    if len(raw) > 512 * 1024:
        raise UserError("Файл аренд превышает 512 КБ.")
    rows = {}
    local_ranges = tuple(ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"))
    for line in raw.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) != 5:
            continue
        try:
            expiry, address = int(parts[0]), ipaddress.ip_address(parts[2])
        except ValueError:
            continue
        if (expiry == 0 or expiry > now) and any(address in network for network in local_ranges):
            rows[address] = clean(parts[3])[:48] if parts[3] != "*" else ""
    return sorted(rows.items(), key=lambda row: (row[0].version, int(row[0])))


def show_leases(path):
    rows = own_leases(path, time.time())
    for ip, name in rows:
        print(f"  {str(ip):39} {name or '—'}")
    print(f"Действующих аренд: {len(rows)}. Аренда не означает, что устройство сейчас на связи.")


def subnet_info(raw):
    interface = ipaddress.ip_interface(raw)
    net = interface.network
    print(f"IP      {interface.ip}")
    print(f"Подсеть {net}  ·  {net.num_addresses:,} адресов")
    print(f"Первый и последний адрес: {net.network_address} — {net.broadcast_address}")


def reverse_dns(raw):
    read_config()
    address = ipaddress.ip_address(raw)
    if not address.is_global or address.is_multicast or getattr(address, "scope_id", None):
        raise UserError("Для локальных адресов используй таблицу своего роутера.")
    subprocess.run(guest("/usr/bin/dig", "-x", str(address), "+time=3", "+tries=1",
                         "+noall", "+comments", "+answer"), timeout=15, check=True)


def check_tls(raw):
    domain = dns_domain(raw).rstrip(".")
    context = ssl.create_default_context()
    with socket.create_connection((domain, 443), timeout=8) as connection:
        with context.wrap_socket(connection, server_hostname=domain) as tls:
            cert = tls.getpeercert()
            digest = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
            print(f"{domain} · {tls.version()} · сертификат проверен")
            print(f"Действует до: {cert.get('notAfter', 'не указано')}")
            print(f"SHA-256: {digest}")


def inspect_file(path, metadata=False):
    read_config()
    if not path.is_file():
        raise UserError("Укажи обычный файл в Termux.")
    args = ("/usr/bin/exiftool", "-fast2", "-s", "-FileType", "-ImageSize",
            "-DateTimeOriginal", "-Make", "-Model", "-Software", "-GPSLatitude",
            "-GPSLongitude", "-") if metadata else ("/usr/bin/file", "-b", "--mime-type", "-")
    with path.open("rb") as file:
        result = subprocess.run(guest(*args), stdin=file, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=40)
    for line in (result.stdout + result.stderr).splitlines():
        if clean(line):
            print(clean(line)[:240])
    if result.returncode:
        raise UserError(f"Инструмент завершился с кодом {result.returncode}.")
    if metadata and not result.stdout.strip():
        print("Из выбранных метаданных ничего не найдено.")


CASE_LV_RESOURCE = "25e80bf3-f107-4ab4-89ef-251b5b9374e9"
CASE_FNS = "https://egrul.nalog.ru/"
CASE_GOV_LV = "https://data.gov.lv/dati/dataset/uz/resource/" + CASE_LV_RESOURCE
CASE_MAX_BODY = 1536 * 1024
CASE_SOCIAL = {
    "t.me": 1, "telegram.me": 1, "vk.com": 1, "instagram.com": 1, "facebook.com": 1,
    "youtube.com": 1, "tiktok.com": 1, "x.com": 1, "twitter.com": 1, "linkedin.com": 2,
    "github.com": 1, "gitlab.com": 1, "codeberg.org": 1,
}
CASE_SOCIAL_RESERVED = {
    "share", "share.php", "intent", "login", "explore", "accounts", "reel", "reels",
    "stories", "search", "watch", "shorts", "videos", "i", "home", "joinchat", "s", "p", "repost",
}
CASE_LEI_CATEGORIES = {"GENERAL", "FUND", "BRANCH", "RESIDENT_GOVERNMENT_ENTITY", "INTERNATIONAL_ORGANIZATION"}
CASE_ORGANIZATIONS = {
    "organization", "corporation", "localbusiness", "store", "onlinestore", "onlinebusiness",
    "professionalservice", "restaurant", "foodestablishment", "financialservice", "bankorcreditunion",
    "hotel", "medicalorganization", "educationalorganization", "automotivebusiness", "softwarecompany",
}
CASE_LABELS = {
    "organization": "Название на сайте", "description": "Деятельность по описанию сайта",
    "activity": "Категория на сайте", "phone": "Публичный телефон", "profile": "Ссылка на профиль",
    "identifier": "Реквизит на сайте",
}


CASE_LABELED_IDS = re.compile(
    r"(?<!\w)(?:ИНН|ОГРН|LEI|reģistrācijas\s+(?:numurs|nr\.?)|reg\.\s*nr\.?)"
    r"\s*[:№#]?\s*((?:[A-Z0-9]{18}[0-9]{2}|(?:LV)?[0-9]{10,13}))(?![A-Z0-9])", re.I
)
CASE_LABELED_PHONE = re.compile(
    r"(?<!\w)(?:тел(?:ефон)?\.?|phone|tālrunis|tel\.?)\s*[:☎]?\s*(\+?[0-9(][0-9(). -]{6,25}[0-9])",
    re.I
)


def case_text(value, limit=240):
    if not isinstance(value, str):
        return ""
    value = "".join(c if c.isspace() else " " if unicodedata.category(c)[0] == "C" else c for c in value)
    return " ".join(value.split())[:limit]


def case_url(raw):
    if not isinstance(raw, str) or not raw or len(raw) > 900 or "\\" in raw:
        raise ValueError("Некорректный HTTPS-адрес.")
    if any(c.isspace() or unicodedata.category(c)[0] == "C" for c in raw):
        raise ValueError("Некорректный HTTPS-адрес.")
    if "://" not in raw:
        raw = "https://" + raw
    parts = urlsplit(raw)
    host = (parts.hostname or "").rstrip(".").encode("idna").decode("ascii").lower()
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if (parts.scheme != "https" or parts.username is not None or parts.password is not None
            or parts.port not in (None, 443) or len(host) > 253
            or not re.fullmatch(rf"(?:{label}\.)+[a-z](?:[a-z0-9-]{{0,61}}[a-z0-9])?", host)
            or host.endswith((".localhost", ".local", ".internal", ".test", ".invalid", ".example", ".onion"))):
        raise ValueError("Нужен публичный HTTPS-адрес без логина и нестандартного порта.")
    path = quote(parts.path or "/", safe="/:@!$&'()*+,;=-._~%")
    return urlunsplit(("https", host, path, "", ""))


def case_host(url):
    host = urlsplit(url).hostname or ""
    return host.removeprefix("www.")


def case_profile(raw):
    if not raw.startswith("https://"):
        return ""
    try:
        url = case_url(raw)
    except (ValueError, UnicodeError):
        return ""
    host = case_host(url)
    count = CASE_SOCIAL.get(host)
    if count is None:
        return ""
    path = urlsplit(url).path.strip("/").split("/")
    if host == "linkedin.com" and (not path or path[0] not in ("company", "school")):
        return ""
    if len(path) != count or path[0].lower() in CASE_SOCIAL_RESERVED:
        return ""
    if not re.fullmatch(r"@?[A-Za-z0-9_.-]{2,80}", path[-1]):
        return ""
    return f"https://{'t.me' if host == 'telegram.me' else host}/" + "/".join(path)


def case_phone(raw, country):
    if not isinstance(raw, str) or not re.fullmatch(r"\+?[0-9(). \u00a0-]{7,28}", raw.strip()):
        return ""
    raw = raw.strip()
    digits = re.sub(r"[^0-9]", "", raw)
    if raw.startswith("+"):
        return "+" + digits if re.fullmatch(r"[1-9][0-9]{7,14}", digits) else ""
    if digits.startswith("00") and re.fullmatch(r"00[1-9][0-9]{7,14}", digits):
        return "+" + digits[2:]
    if country == "RU" and re.fullmatch(r"[78][0-9]{10}", digits):
        return "+7" + digits[1:]
    if country == "RU" and re.fullmatch(r"[3489][0-9]{9}", digits):
        return "+7" + digits
    if country == "LV" and re.fullmatch(r"[26][0-9]{7}", digits):
        return "+371" + digits
    return ""


def case_identifier(raw):
    value = re.sub(r"[\s-]+", "", str(raw or "")).upper()
    if re.fullmatch(r"[A-Z0-9]{18}[0-9]{2}", value):
        expanded = "".join(str(ord(c) - 55) if c.isalpha() else c for c in value)
        return ("LEI", value) if int(expanded) % 97 == 1 else ("", "")
    if re.fullmatch(r"LV[0-9]{11}", value):
        value = value[2:]
    if re.fullmatch(r"[1-9][0-9]{10}", value):
        return "LV", value
    if re.fullmatch(r"[0-9]{10}", value) and value != "0000000000":
        checksum = sum(int(d) * w for d, w in zip(value, (2, 4, 10, 3, 5, 9, 4, 6, 8))) % 11 % 10
        if checksum == int(value[-1]):
            return "RU", value
    if re.fullmatch(r"[15][0-9]{12}", value) and int(value[:-1]) % 11 % 10 == int(value[-1]):
        return "RU", value
    return "", ""


class CaseNoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def case_json(url, *, headers=None, data=None):
    req = Request(url, headers={"Accept": "application/json", "User-Agent": f"PhoneHost/{VERSION}",
                                **(headers or {})}, data=data)
    try:
        with build_opener(CaseNoRedirect()).open(req, timeout=12) as response:
            raw = case_read(response, time.monotonic() + 12)
        value = json.loads(raw)
    except HTTPError as exc:
        raise UserError(f"HTTP {exc.code}") from None
    except (OSError, ValueError, http.client.HTTPException):
        raise UserError("источник недоступен или вернул неожиданный ответ") from None
    if not isinstance(value, dict):
        raise UserError("неожиданный формат ответа")
    return value


def case_read(response, deadline):
    chunks = bytearray()
    while time.monotonic() < deadline:
        chunk = response.read1(min(65536, CASE_MAX_BODY + 1 - len(chunks)))
        if not chunk:
            return bytes(chunks)
        chunks.extend(chunk)
        if len(chunks) > CASE_MAX_BODY:
            raise ValueError("Ответ слишком большой.")
    raise TimeoutError("Источник долго отвечает.")


def case_public_ips(host):
    addresses = []
    for info in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM):
        ip = ipaddress.ip_address(info[4][0])
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        if (not ip.is_global or ip.is_multicast or ip.is_reserved or getattr(ip, "scope_id", None)
                or (ip.version == 6 and any(ip in n for n in CASE_TRANSITION_NETWORKS))):
            continue
        if str(ip) not in addresses:
            addresses.append(str(ip))
    if not addresses:
        raise ValueError("Нет общедоступного адреса.")
    return sorted(addresses, key=lambda ip: ":" in ip)


CASE_TRANSITION_NETWORKS = tuple(map(ipaddress.ip_network, (
    "64:ff9b::/96", "64:ff9b:1::/48", "2001::/32", "2002::/16",
)))


class CaseConnection(http.client.HTTPSConnection):
    def __init__(self, hostname, ip, timeout):
        super().__init__(hostname, timeout=timeout, context=ssl.create_default_context())
        self.ip = ip

    def connect(self):
        raw = socket.create_connection((self.ip, 443), self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def case_html(url):
    url = case_url(url)
    host = case_host(url)
    deadline = time.monotonic() + 10
    for _ in range(3):
        parts = urlsplit(url)
        response = None
        for ip in case_public_ips(parts.hostname)[:3]:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            conn = CaseConnection(parts.hostname, ip, min(4, remaining))
            try:
                conn.request("GET", parts.path, headers={"Accept": "text/html, application/xhtml+xml",
                             "User-Agent": f"PhoneHost/{VERSION}"})
                response = conn.getresponse()
            except (OSError, http.client.HTTPException):
                conn.close()
                continue
            break
        if response is None:
            raise UserError("страница не ответила по HTTPS")
        try:
            if response.status in (301, 302, 303, 307, 308):
                jump = response.getheader("Location")
                if not jump:
                    raise UserError("перенаправление без адреса")
                target = case_url(urljoin(url, jump))
                if case_host(target) != host:
                    raise UserError("страница перенаправляет на другой сайт")
                url = target
                continue
            if response.status != 200:
                raise UserError(f"HTTP {response.status}")
            msg = response.headers
            if msg.get_content_type() not in ("text/html", "application/xhtml+xml"):
                raise UserError("адрес не вернул HTML-страницу")
            raw = case_read(response, deadline)
            try:
                return url, raw.decode(msg.get_content_charset() or "utf-8", "replace")
            except LookupError:
                return url, raw.decode("utf-8", "replace")
        finally:
            response.close()
            conn.close()
    raise UserError("слишком много перенаправлений")


def case_dict(value):
    return value if isinstance(value, dict) else {}


def case_list(value):
    return value if isinstance(value, list) else [] if value is None else [value]


class CasePage(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []
        self.jsonld = []
        self.script = None
        self.hidden = 0
        self.visible = []
        self.meta = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("script", "style", "noscript", "template"):
            self.hidden += 1
        if tag == "meta":
            field = (attrs.get("property") or attrs.get("name") or "").lower()
            if field in ("og:site_name", "og:description", "description"):
                self.meta[field] = attrs.get("content")
        if not self.hidden and tag == "a" and attrs.get("href") and len(self.links) < 500:
            self.links.append(attrs["href"])
        if tag == "script" and (attrs.get("type") or "").lower().strip() == "application/ld+json":
            self.script = []

    def handle_data(self, data):
        if self.script is not None:
            self.script.append(data)
        elif not self.hidden and len(self.visible) < 12000:
            self.visible.append(data.strip())

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript", "template") and self.hidden:
            self.hidden -= 1
        if tag != "script" or self.script is None:
            return
        if len(self.jsonld) < 25:
            try:
                self.jsonld.append(json.loads("".join(self.script)))
            except (ValueError, RecursionError):
                pass
        self.script = None


def case_organizations(values):
    candidates = deque(values)
    inspected = 0
    while candidates and inspected < 250:
        value = candidates.popleft()
        inspected += 1
        if isinstance(value, list):
            candidates.extend(value[:40])
        elif isinstance(value, dict):
            kinds = {case_text(t).rsplit("/", 1)[-1].lower() for t in case_list(value.get("@type"))}
            if kinds & CASE_ORGANIZATIONS:
                yield value
            for key in ("@graph", "publisher", "provider", "mainEntity"):
                if key in value:
                    candidates.append(value[key])


def case_evidence(url, html, country, *, supplied):
    page = CasePage()
    page.feed(html)
    page.close()
    facts = set()
    internal = set()

    def add(kind, value):
        value = case_text(value, 360)
        if value:
            facts.add((kind, value))

    for obj in case_organizations(page.jsonld):
        for key in ("legalName", "name"):
            add("organization", obj.get(key))
        add("description", obj.get("description"))
        for key in ("industry", "category", "serviceType", "naics", "isicV4", "knowsAbout"):
            for activity in case_list(obj.get(key))[:8]:
                add("activity", activity)
        for key in ("leiCode", "taxID", "vatID", "identifier"):
            for ident in case_list(obj.get(key))[:5]:
                kind, value = case_identifier(case_dict(ident).get("value") if isinstance(ident, dict) else ident)
                if kind:
                    add("identifier", value)
        for contact in (obj, *case_list(obj.get("contactPoint"))[:8]):
            for number in case_list(case_dict(contact).get("telephone"))[:6]:
                add("phone", case_phone(number, country))
        for remote in case_list(obj.get("sameAs"))[:20]:
            if isinstance(remote, str):
                add("profile", case_profile(remote))

    if supplied:
        add("organization", page.meta.get("og:site_name"))
        if not any(k == "description" for k, _ in facts):
            add("description", page.meta.get("og:description") or page.meta.get("description"))
        visible = " ".join(page.visible)
        for match in CASE_LABELED_IDS.finditer(visible):
            kind, value = case_identifier(match[1])
            if kind:
                add("identifier", value)
        for match in CASE_LABELED_PHONE.finditer(visible):
            add("phone", case_phone(match[1], country))
        for href in page.links:
            if len(href) > 900:
                continue
            if href.lower().startswith("tel:"):
                add("phone", case_phone(unquote(href[4:]), country))
                continue
            try:
                target = case_url(urljoin(url, href))
            except (ValueError, UnicodeError):
                continue
            profile = case_profile(target)
            if profile:
                add("profile", profile)
            elif case_host(target) == case_host(url) and re.search(
                    r"(?:^|[/_-])(contact[s]?|about|impressum|kontakti|kontakty|rekvizity|"
                    r"контакты|реквизиты|о-компании)(?=$|[/_.-])", unquote(urlsplit(target).path), re.I):
                internal.add(target)
    return sorted(facts), sorted(internal, key=lambda u: (len(u), u))


def case_registry(kind, identifier):
    if kind == "LV":
        fields = "regcode,name,type,type_text,regtype,registered,terminated,closed"
        url = "https://data.gov.lv/dati/api/3/action/datastore_search?" + urlencode({
            "resource_id": CASE_LV_RESOURCE, "filters": json.dumps({"regcode": int(identifier)}),
            "fields": fields, "limit": 1, "include_total": "false",
        })
        data = case_json(url)
        rows = case_dict(data.get("result")).get("records")
        if data.get("success") is not True or not isinstance(rows, list):
            raise UserError("реестр не вернул список записей")
        for r in map(case_dict, rows):
            if str(r.get("regcode")) != identifier:
                continue
            # Keep company types only. No individual merchants, farms or sole traders.
            if r.get("type") not in ("SIA", "AS", "PS", "KS", "SE"):
                return {"status": "outside_scope", "source": CASE_GOV_LV, "id": identifier}
            name = case_text(r.get("name"))
            if not name:
                raise UserError("неполная запись реестра")
            return {"status": "found", "source": CASE_GOV_LV, "id": identifier, "name": name,
                    "form": case_text(r.get("type_text")), "registered": case_text(r.get("registered"))[:10],
                    "state": ("исключена из реестра" if r.get("terminated") else
                              "причина закрытия указана" if case_text(r.get("closed")) else
                              "в записи нет даты исключения")}
        return {"status": "not_found", "source": CASE_GOV_LV, "id": identifier}
    if kind == "LEI":
        url = "https://api.gleif.org/api/v1/lei-records/" + identifier
        source = "https://search.gleif.org/#/record/" + identifier
        try:
            row = case_dict(case_json(url).get("data"))
        except UserError as exc:
            if str(exc) == "HTTP 404":
                return {"status": "not_found", "source": source, "id": identifier}
            raise
        attrs = case_dict(row.get("attributes"))
        entity = case_dict(attrs.get("entity"))
        if row.get("id") != identifier or not entity:
            raise UserError("неожиданный ответ GLEIF")
        if entity.get("category") not in CASE_LEI_CATEGORIES:
            return {"status": "outside_scope", "source": source, "id": identifier}
        name = case_text(case_dict(entity.get("legalName")).get("name"))
        if not name:
            raise UserError("неполная запись GLEIF")
        return {"status": "found", "source": source, "id": identifier, "name": name,
                "state": case_text(entity.get("status")), "jurisdiction": case_text(entity.get("jurisdiction")),
                "registered": case_text(entity.get("creationDate"))[:10]}
    if kind == "RU":
        token = os.environ.get("PHONEHOST_DADATA_KEY", "").strip()
        if not token:
            return {"status": "manual", "source": CASE_FNS, "id": identifier}
        data = case_json("https://suggestions.dadata.ru/suggestions/api/4_1/rs/findById/party",
                         headers={"Authorization": "Token " + token, "Content-Type": "application/json"},
                         data=json.dumps({"query": identifier, "type": "LEGAL", "count": 8}).encode())
        rows = data.get("suggestions")
        if not isinstance(rows, list):
            raise UserError("DaData не вернула список записей")
        for suggestion in map(case_dict, rows):
            row = case_dict(suggestion.get("data"))
            if row.get("type") != "LEGAL" or identifier not in (row.get("inn"), row.get("ogrn")):
                continue
            name = case_text(case_dict(row.get("name")).get("full_with_opf"))
            if not name:
                raise UserError("неполная запись DaData")
            return {"status": "found", "source": "https://dadata.ru/api/find-party/",
                    "official": CASE_FNS, "id": identifier, "name": name, "jurisdiction": "RU",
                    "state": case_text(case_dict(row.get("state")).get("status")),
                    "activity": case_text(row.get("okved")), "activity_type": "ОКВЭД"}
        return {"status": "not_found", "source": "https://dadata.ru/api/find-party/",
                "official": CASE_FNS, "id": identifier}
    raise ValueError("Неизвестный реестр.")


def case_registry_name(name):
    url = "https://api.gleif.org/api/v1/lei-records?" + urlencode({
        "filter[entity.legalName]": name, "page[size]": 8,
    })
    rows = case_json(url).get("data")
    if not isinstance(rows, list):
        raise UserError("GLEIF не вернул список записей")
    matches = []
    for row in map(case_dict, rows):
        entity = case_dict(case_dict(row.get("attributes")).get("entity"))
        candidate = case_text(case_dict(entity.get("legalName")).get("name"))
        _, identifier = case_identifier(row.get("id"))
        if not identifier or case_key(candidate) != case_key(name):
            continue
        if entity.get("category") not in CASE_LEI_CATEGORIES:
            continue
        matches.append({"status": "name_match", "source": "https://search.gleif.org/#/record/" + identifier,
                        "id": identifier, "name": candidate, "state": case_text(entity.get("status")),
                        "jurisdiction": case_text(entity.get("jurisdiction"))})
    return matches


PROFILE_IMPORT_LIMIT = 512 * 1024


def case_profile_key(url):
    profile = case_profile(url)
    if not profile:
        return ""
    parts = urlsplit(profile)
    alias = {"twitter.com": "x.com"}.get(parts.hostname, parts.hostname)
    return alias + parts.path.casefold()


def case_import_profiles(path):
    path = path.expanduser()
    if path.suffix.casefold() not in (".csv", ".txt") or not path.is_file():
        raise UserError("Для импорта укажи локальный отчёт CSV или TXT.")
    with path.open("rb") as file:
        raw = file.read(PROFILE_IMPORT_LIMIT + 1)
    if len(raw) > PROFILE_IMPORT_LIMIT:
        raise UserError("Отчёт профилей больше 512 КБ.")
    text = raw.decode("utf-8-sig", "replace")
    candidates = set()
    if path.suffix.casefold() == ".txt":
        records = ((line.strip(), "") for line in text.splitlines()[:2000])
    else:
        reader = csv.DictReader(io.StringIO(text))
        columns = {name.strip().casefold(): name for name in reader.fieldnames or []}
        # Sherlock and Maigret have url_user/exists. Blackbird has an exported URL column.
        key = next((columns[k] for k in ("url_user", "url", "profile url", "profile_url", "link")
                    if k in columns), None)
        if not key:
            raise UserError("В CSV нет столбца url_user или URL.")
        records = ((row.get(key, ""), row.get(columns.get("exists", ""), ""))
                   for row in itertools.islice(reader, 2000))
    for url, status in records:
        if status and status.strip().casefold() not in ("claimed", "found", "yes", "true", "exists"):
            continue
        if isinstance(url, str) and (key := case_profile_key(url.strip().strip("<>"))):
            candidates.add(key)
    return candidates


WIKIDATA_COMPANIES = {"Q4830453", "Q783794", "Q167037", "Q6881511", "Q891723", "Q161726"}


def case_wikidata_sites(name):
    def wikidata(**params):
        return case_json("https://www.wikidata.org/w/api.php?" + urlencode({"format": "json", **params}),
                         headers={"User-Agent": f"PhoneHost/{VERSION} (https://github.com/zaoastronaftik-bit/phonehost)"})

    language = "ru" if re.search(r"[А-Яа-яЁё]", name) else "en"
    result = wikidata(action="wbsearchentities", search=name, language=language, type="item", limit=8)
    rows = result.get("search")
    if not isinstance(rows, list):
        raise UserError("Wikidata не вернула результаты поиска.")
    hits = {}
    for row in map(case_dict, rows):
        qid = case_text(row.get("id"), 12)
        label = case_text(row.get("label"))
        matched = case_text(case_dict(row.get("match")).get("text"))
        if re.fullmatch(r"Q[1-9][0-9]{0,10}", qid) and any(case_key(v) == case_key(name)
                                                         for v in (label, matched) if v):
            hits[qid] = label
    if not hits:
        return []
    entities = case_dict(wikidata(action="wbgetentities", ids="|".join(list(hits)[:4]), props="claims").get("entities"))

    def values(claims, prop):
        for claim in map(case_dict, case_list(claims.get(prop))[:20]):
            if claim.get("rank") != "deprecated":
                yield case_dict(case_dict(claim.get("mainsnak")).get("datavalue")).get("value")

    sources = []
    for qid, raw in entities.items():
        if qid not in hits:
            continue
        claims = case_dict(case_dict(raw).get("claims"))
        if not any(case_dict(c).get("id") in WIKIDATA_COMPANIES for c in values(claims, "P31")):
            continue
        for website in values(claims, "P856"):
            try:
                url = case_url(website)
            except (ValueError, UnicodeError):
                continue
            if case_host(url) not in CASE_SOCIAL:
                sources.append({"url": url, "source": "https://www.wikidata.org/wiki/" + qid,
                                "name": hits[qid]})
    return list({row["url"]: row for row in sources}.values())[:3]


def case_org_accounts(handle):
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?", handle):
        return [], []
    accounts, failures = [], []
    jobs = (
        ("GitHub", "https://api.github.com/orgs/" + handle, "https://github.com/" + handle),
        ("GitLab", "https://gitlab.com/api/v4/groups/" + handle, "https://gitlab.com/" + handle),
    )
    def lookup(job):
        platform_name, endpoint, profile = job
        try:
            row = case_json(endpoint)
        except UserError as exc:
            return None, None if str(exc) == "HTTP 404" else f"{platform_name} · {exc}"
        if platform_name == "GitHub":
            if row.get("type") != "Organization" or case_text(row.get("login")).casefold() != handle:
                return None, None
        elif row.get("visibility") != "public" or case_text(row.get("full_path")).casefold() != handle:
            return None, None
        website = ""
        if platform_name == "GitHub" and case_text(row.get("blog"), 900):
            try:
                target = case_url(row["blog"])
                if case_host(target) not in CASE_SOCIAL:
                    website = target
            except (ValueError, UnicodeError):
                pass
        return {"platform": platform_name, "url": profile, "endpoint": endpoint,
                "name": case_text(row.get("name"), 100), "website": website}, None

    with ThreadPoolExecutor(max_workers=2) as pool:
        for account, failure in pool.map(lookup, jobs):
            if account:
                accounts.append(account)
            if failure:
                failures.append(failure)
    return accounts, failures


def case_account_links(report, accounts, imported):
    published = {}
    hosts = set()
    for page in report["pages"]:
        if "facts" not in page:
            continue
        hosts.add(case_host(page["url"]))
        for kind, value in page["facts"]:
            if kind == "profile" and (key := case_profile_key(value)):
                published[key] = (value, page["url"])
    for account in accounts:
        match = published.get(case_profile_key(account["url"]))
        if match:
            account["link_state"] = "опубликован на сайте"
            account["evidence"] = match[1]
        elif account["website"] and case_host(account["website"]) in hosts:
            account["link_state"] = "сам профиль ведёт на проверенный сайт"
            account["evidence"] = account["website"]
        else:
            account["link_state"] = "публичная организация/группа; связь не подтверждена"
    matches = []
    for profile_key in sorted(imported.keys() & published.keys()):
        url, source = published[profile_key]
        matches.append({"url": url, "source": source, "reports": sorted(imported[profile_key])})
    return matches


def case_discovery(name, phone, handle):
    token = os.environ.get("PHONEHOST_BRAVE_KEY", "").strip()
    if not token:
        return [], "Веб-поиск не запущен · настрой PHONEHOST_BRAVE_KEY или укажи сайт."
    alternatives = [name, phone, handle]
    if phone.startswith("+371") and len(phone) == 12:
        alternatives.append(f"+371 {phone[4:8]} {phone[8:]}")
    elif phone.startswith("+7") and len(phone) == 12:
        alternatives.append(f"+7 {phone[2:5]} {phone[5:8]}-{phone[8:10]}-{phone[10:]}")
    terms = ['"' + value.replace('"', '') + '"' for value in dict.fromkeys(alternatives) if value]
    if not terms:
        return [], "Для веб-поиска укажи название компании, рабочий телефон или деловой @ник."
    query = "(" + " OR ".join(terms) + ")" if len(terms) > 1 else terms[0]
    data = case_json("https://api.search.brave.com/res/v1/web/search?" + urlencode({
        "q": query, "count": 16, "country": "ALL",
    }), headers={"X-Subscription-Token": token})
    rows = case_dict(data.get("web")).get("results", [])
    if not isinstance(rows, list):
        raise UserError("веб-поиск не вернул список страниц")
    results = {}
    for row in map(case_dict, rows[:16]):
        try:
            url = case_url(row.get("url", ""))
        except (ValueError, UnicodeError):
            continue
        host = case_host(url)
        if host not in CASE_SOCIAL:
            results.setdefault(host, url)
    return list(results.values())[:6], None


def case_key(value):
    value = unicodedata.normalize("NFKC", value).casefold().replace("ё", "е")
    return " ".join(re.findall(r"[^\W_]+", value))


def case_match(facts, name, phone, handle):
    if phone and ("phone", phone) in facts:
        return True
    if handle and any(kind == "profile" and url.rsplit("/", 1)[-1].lstrip("@").casefold() == handle
                      for kind, url in facts):
        return True
    return bool(name and any(kind == "organization" and case_key(value) == case_key(name)
                             for kind, value in facts))


def case_bill(path, country):
    path = path.expanduser().resolve()
    if not path.is_file() or path.stat().st_size > 15 * 1024 * 1024:
        raise UserError("Для сверки нужен локальный файл размером до 15 МБ.")
    if path.suffix.lower() == ".txt":
        with path.open("rb") as file:
            raw = file.read(64 * 1024 + 1)
        if len(raw) > 64 * 1024:
            raise UserError("Текст счёта больше 64 КБ.")
        text = raw.decode("utf-8-sig", "replace")
    elif path.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp"):
        tesseract = shutil.which("tesseract")
        if not tesseract:
            raise UserError("Для фото нужен локальный Tesseract. Можно подать текст счёта в .txt.")
        lang = os.getenv("PHONEHOST_OCR_LANG", "eng")
        if not re.fullmatch(r"[a-z_]{2,16}(?:\+[a-z_]{2,16}){0,3}", lang):
            raise UserError("Некорректный язык OCR в PHONEHOST_OCR_LANG.")
        result = subprocess.run([tesseract, str(path), "stdout", "-l", lang], capture_output=True,
                                timeout=22, check=False)
        if result.returncode:
            raise UserError("Tesseract не прочитал изображение. Проверь, установлен ли выбранный язык.")
        text = result.stdout[:64 * 1024].decode("utf-8", "replace")
    else:
        raise UserError("Поддерживаются TXT, PNG, JPEG и WebP.")
    facts = set()
    for line in text.splitlines():
        for match in CASE_LABELED_IDS.finditer(line):
            _, value = case_identifier(match[1])
            if value:
                facts.add(("identifier", value))
        for match in CASE_LABELED_PHONE.finditer(line):
            if value := case_phone(match[1], country):
                facts.add(("phone", value))
    return sorted(facts)[:12]


def case_phone_region(country, phone, url):
    if country in ("RU", "LV"):
        return country
    if phone.startswith("+371") or case_host(url).endswith(".lv"):
        return "LV"
    if phone.startswith("+7") or case_host(url).endswith((".ru", ".su", ".xn--p1ai")):
        return "RU"
    return ""


def case_collect(opts):
    raw_handle = opts.handle or ""
    handle = raw_handle.lstrip("@").casefold()
    if raw_handle and not re.fullmatch(r"@?[a-zA-Z0-9_.-]{2,50}", raw_handle):
        raise UserError("Укажи короткий публичный @ник без пробелов.")
    name = case_text(opts.company)
    country, number = case_identifier(opts.registration)
    if opts.registration and not number:
        raise UserError("Реквизит не распознан. Укажи ИНН юрлица, ОГРН, регномер Латвии или LEI.")
    phone = case_phone(opts.phone, country)
    if opts.phone and not phone:
        raise UserError("Введи рабочий телефон в международном формате, начиная с +.")
    sites = list(dict.fromkeys(case_url(s) for s in (opts.site or [])))
    if len(sites) > 2:
        raise UserError("Укажи не больше двух публичных сайтов за одну проверку.")
    if any(case_host(site) in CASE_SOCIAL for site in sites):
        raise UserError("В поле сайта укажи сайт компании. Соцсеть можно указать как @ник.")
    if not any((name, phone, handle, number, sites, opts.bill)):
        raise UserError("Укажи хотя бы один исходный реквизит или сайт компании.")
    report = {"schema": 1, "checked_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "input": {"company": name, "phone": phone, "handle": handle, "registration": number, "sites": sites},
              "pages": [], "notes": [], "registry": []}
    if opts.bill:
        bill_country = case_phone_region(country, phone, sites[0] if sites else "")
        report["bill"] = [list(row) for row in case_bill(opts.bill, bill_country)]
        if not report["bill"]:
            report["notes"].append("В локальном счёте не распознаны телефон или регистрационный номер.")

    reports = opts.profile_report or []
    if len(reports) > 5:
        raise UserError("За один раз можно добавить до пяти отчётов профилей.")
    imported = {}
    for path in reports:
        for key in case_import_profiles(path):
            imported.setdefault(key, set()).add(case_text(path.name, 96))

    def collect(url, supplied):
        try:
            actual, html = case_html(url)
            page_region = case_phone_region(country, phone, actual)
            facts, extra = case_evidence(actual, html, page_region, supplied=supplied)
            looks_business = any(k == "organization" for k, _ in facts)
            if not supplied and not (looks_business and case_match(facts, name, phone, handle)):
                # Plain HTML is eligible only with an explicitly labelled company identifier
                # and a matching business input. Search snippets alone aren't evidence.
                more, _ = case_evidence(actual, html, page_region, supplied=True)
                looks_business = any(k == "identifier" for k, _ in more)
                if looks_business:
                    facts = more
            if supplied or (looks_business and case_match(facts, name, phone, handle)):
                return {"url": actual, "source": "supplied" if supplied else "discovered",
                        "facts": [list(f) for f in facts[:90]]}, extra
        except (UserError, OSError, ValueError, http.client.HTTPException) as exc:
            if supplied:
                return {"url": url, "source": "supplied", "error": case_text(str(exc))}, []
        return None, []

    def add_page(item):
        if item and not any(page["url"] == item["url"] for page in report["pages"]):
            report["pages"].append(item)

    for site in sites:
        page, extra = collect(site, True)
        add_page(page)
        visited = {site, page["url"]} if page else {site}
        for link in [url for url in extra if url not in visited][:2]:
            add_page(collect(link, True)[0])
    if opts.discover:
        try:
            candidates, note = case_discovery(name, phone, "@" + handle if handle else "")
            if note:
                report["notes"].append(note)
            tested = {case_host(p["url"]) for p in report["pages"]}
            with ThreadPoolExecutor(max_workers=3) as pool:
                for page, _ in pool.map(lambda url: collect(url, False),
                                        [url for url in candidates if case_host(url) not in tested]):
                    add_page(page)
            if candidates and not any(p["source"] == "discovered" for p in report["pages"]):
                report["notes"].append("Веб-поиск не подтвердил дополнительных деловых страниц.")
            if not candidates and not note:
                report["notes"].append("Веб-поиск не вернул кандидатов для проверки.")
        except UserError as exc:
            report["notes"].append(f"Веб-поиск недоступен · {exc}.")
    elif not sites and (name or phone or handle):
        report["notes"].append("Для проверки контактов добавь сайт или включи веб-поиск.")
    if name and opts.profiles and not any("facts" in page for page in report["pages"]):
        try:
            report["wikidata_sites"] = case_wikidata_sites(name)
            for item in report["wikidata_sites"]:
                add_page(collect(item["url"], False)[0])
        except UserError as exc:
            report["notes"].append(f"Wikidata недоступна · {exc}.")
    if handle and opts.profiles:
        report["org_accounts"], failures = case_org_accounts(handle)
        if failures:
            report["notes"].extend(f"Источник профилей недоступен · {message}." for message in failures)
        if not report["org_accounts"] and not failures:
            report["notes"].append("GitHub и GitLab не вернули публичную организацию или группу по этому нику.")
    if reports or "org_accounts" in report:
        report["profile_matches"] = case_account_links(report, report.get("org_accounts", []), imported)
        if reports and not report["profile_matches"]:
            report["notes"].append("В импортированных отчётах нет ссылок, подтверждённых публикациями на проверенных сайтах.")
    bill_ids = [value for kind, value in report.get("bill", []) if kind == "identifier"]
    identifiers = list(dict.fromkeys((([number] if number else []) + bill_ids) + sorted({
        value for p in report["pages"] for kind, value in p.get("facts", []) if kind == "identifier"
    })))
    # Auto-detected identifiers are only claims made on the source page.
    names = [name] if name else list(dict.fromkeys(
        value for p in report["pages"] for kind, value in p.get("facts", []) if kind == "organization"
    ))
    if not identifiers and names:
        try:
            report["registry"].extend(case_registry_name(names[0])[:4])
            if not report["registry"]:
                report["notes"].append("Точного совпадения по имени в GLEIF нет. LEI есть не у всех компаний.")
        except UserError as exc:
            report["notes"].append(f"Поиск названия в GLEIF недоступен · {exc}.")
    for identifier in identifiers[:3]:
        kind, _ = case_identifier(identifier)
        try:
            record = case_registry(kind, identifier)
        except UserError as exc:
            record = {"status": "unavailable", "id": identifier, "error": str(exc)}
            if kind == "RU":
                record["official"] = CASE_FNS
            elif kind == "LV":
                record["source"] = CASE_GOV_LV
            elif kind == "LEI":
                record["source"] = "https://search.gleif.org/#/record/" + identifier
        report["registry"].append(record)
    return report


def case_changes(previous, report):
    if not isinstance(previous, dict) or previous.get("schema") != 1 or previous.get("input") != report["input"]:
        return ["Исходные данные поменялись или формат истории устарел. Сравнение пропущено."]
    old = {p["url"]: p for p in previous["pages"] if "facts" in p}
    new = {p["url"]: p for p in report["pages"] if "facts" in p}
    changes = []
    for url in sorted(old.keys() & new.keys()):
        before = {tuple(p) for p in old[url]["facts"]}
        after = {tuple(p) for p in new[url]["facts"]}
        for flag, delta in (("+", after - before), ("−", before - after)):
            for kind, value in sorted(delta):
                changes.append(f"{flag} {CASE_LABELS[kind]} · {value} · {url}")
    if not (old.keys() & new.keys()):
        return ["Нет страниц, прочитанных в обеих проверках. Удаление контакта не предполагалось."]
    return changes[:30] or ["На повторно прочитанных страницах изменений не обнаружено."]


def case_present(report):
    seed = report["input"]
    print(f"SHARK / ДЕЛОВОЕ РАССЛЕДОВАНИЕ   {report['checked_utc']}")
    print(f"Исходные данные · {seed['company'] or '—'} · {seed['phone'] or '—'} · "
          f"{'@' + seed['handle'] if seed['handle'] else '—'}")
    print("\nРЕЕСТРЫ")
    states = {"found": "Запись найдена", "not_found": "Не найдено в этом источнике",
              "manual": "Ручная проверка в ФНС", "outside_scope": "Не входит в проверяемые формы юрлиц",
              "unavailable": "Источник недоступен", "name_match": "Кандидат в GLEIF по названию"}
    for row in report["registry"]:
        print(f"  {row['id']} · {states[row['status']]} · {row.get('name') or row.get('error') or ''}".rstrip(" ·"))
        details = " · ".join(row[k] for k in ("form", "state", "jurisdiction", "registered") if row.get(k))
        if details:
            print("  " + details)
        if row.get("activity"):
            print(f"  {row.get('activity_type', 'Деятельность')} · {row['activity']}")
        if row.get("source"):
            print(f"  Источник · {row['source']}")
        if row.get("official"):
            print(f"  Официальная сверка · {row['official']}")
    if not report["registry"]:
        print("  Регистрационный номер не известен. Сайт или ник не доказывает регистрацию.")
    print("\nСВЯЗИ И ИСТОЧНИКИ")
    matched_phone = False
    matched_nick = False
    discovered_ids = set()
    publications = {}
    for row in report["pages"]:
        print("  " + ("Указанный сайт" if row["source"] == "supplied" else "Кандидат из поиска") + " · " + row["url"])
        if "error" in row:
            print(f"    Не прочитан · {row['error']}")
        elif not row["facts"]:
            print("    Не найдены структурированные деловые реквизиты или публичные контактные ссылки.")
        for kind, value in row.get("facts", []):
            marker = ""
            if kind == "phone" and value == seed["phone"]:
                matched_phone = True
                marker = " [совпадает с вводом]"
            if kind == "profile" and value.rsplit("/", 1)[-1].lstrip("@").casefold() == seed["handle"]:
                matched_nick = True
                marker = " [ник совпадает с вводом]"
            if kind in ("phone", "profile", "identifier"):
                publications.setdefault((kind, value), set()).add(case_host(row["url"]))
            if kind == "identifier":
                discovered_ids.add(value)
                if value == seed["registration"]:
                    marker = " [совпадает с вводом]"
            print(f"    {CASE_LABELS[kind]} · {value}{marker}")
    if not report["pages"]:
        print("  Подтверждённых публикаций нет в пределах этой проверки.")
    if report.get("wikidata_sites"):
        print("\nСАЙТЫ-КАНДИДАТЫ ИЗ WIKIDATA · не выписка из реестра")
        for item in report["wikidata_sites"]:
            print(f"  {item['name']} · {item['url']} · {item['source']}")
    if report.get("org_accounts") or report.get("profile_matches"):
        print("\nПУБЛИЧНЫЕ ПРОФИЛИ")
        for item in report.get("org_accounts", []):
            print(f"  {item['platform']} · {item['name'] or '—'} · {item['url']}")
            print(f"    {item['link_state']} · {item.get('evidence', item['endpoint'])}")
        for item in report.get("profile_matches", []):
            print(f"  {item['url']} · {', '.join(item['reports'])}")
            print(f"    Опубликован на проверенной странице · {item['source']}")
    if report.get("bill"):
        print("\nЛОКАЛЬНЫЙ СЧЁТ · распознано, не подтверждено")
        for kind, value in report["bill"]:
            if kind == "identifier":
                reference = seed["registration"]
            else:
                reference = seed["phone"]
            verdict = ("совпадает с вводом" if value == reference else "не совпадает с вводом") if reference else ""
            if (kind, value) in publications:
                verdict = (verdict + " · " if verdict else "") + "также опубликовано на сайте"
            label = "Реквизит" if kind == "identifier" else "Телефон"
            print(f"  {label} · {value}" + (f" [{verdict}]" if verdict else ""))
    print("\nВЫВОД")
    if seed["phone"]:
        print("  " + ("Введённый телефон опубликован на показанной странице." if matched_phone else
                      "Публикация введённого телефона не подтверждена."))
    if seed["handle"]:
        print("  " + ("Найдена публичная ссылка с этим ником." if matched_nick else
                      "Связь введённого ника с проверенными сайтами не подтверждена."))
    reference_id = seed["registration"]
    if reference_id:
        comparable = {value for value in discovered_ids if len(value) == len(reference_id)}
        if comparable and reference_id not in comparable:
            print("  На сайте указан другой номер того же формата. Сверь его с реестром.")
    for (kind, value), hosts in sorted(publications.items()):
        if len(hosts) > 1:
            print(f"  {CASE_LABELS[kind]} {value} опубликован на доменах {', '.join(sorted(hosts))}.")
    if len(discovered_ids) > 1:
        print("  На страницах несколько идентификаторов. Не объединяй компании по одному контакту.")
    registry_found = any(r["status"] == "found" for r in report["registry"])
    if registry_found and not discovered_ids:
        print("  Компания найдена, но привязка проверенного сайта к записи реестра не видна.")
    if not registry_found and not seed["registration"]:
        print("  Следующий шаг · взять регистрационный номер из официальных реквизитов и повторить проверку.")
    elif seed["sites"]:
        print("  Следующий шаг · сверить контакт с независимо найденным официальным источником.")
    if seed["phone"].startswith("+31"):
        print("  Ручная проверка сообщений · https://www.politie.nl/aangifte-of-melding-doen/controleer-handelspartij.html/")
    print("  Публикация контакта не доказывает, кто тебе пишет или принимает оплату.")
    if "changes" in report:
        print("\nИЗМЕНЕНИЯ")
        for change in report["changes"]:
            print("  " + change)
    for note in report["notes"]:
        print("  " + note)


def case_investigate(opts):
    if opts.case and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,47}", opts.case):
        raise UserError("Имя истории должно состоять из букв A–Z, цифр, дефиса или подчёркивания.")
    report = case_collect(opts)
    if opts.case:
        folder = STATE / "investigations"
        folder.mkdir(mode=0o700, exist_ok=True)
        filename = folder / (opts.case + ".json")
        if filename.is_file():
            try:
                with filename.open("rb") as f:
                    previous = json.loads(f.read(2 * CASE_MAX_BODY))
                report["changes"] = case_changes(previous, report)
            except (OSError, ValueError, TypeError, KeyError):
                report["notes"].append("Предыдущий снимок не удалось прочитать.")
        atomic_write(filename, json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        report["notes"].append(f"Локальный снимок · {filename}")
    if opts.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        case_present(report)


SCYTHE = r"""
    @@@@@@@@@%%%%%%%%%%%%%%%%%%%%%%&&&&&&
  @@@╯         ╰───────────────╮      ╲&&&
                                ╲      ╲&&
           P H O N E H O S T     ╲      #&
             S H A R K            ╲     #&
                                   ╲   ##
                                    ╲##╯
                                     ║
                                     ║
"""


class MenuBack(Exception):
    pass


class SharkConsole:
    def __init__(self, root_network=False):
        self.full = sys.stdin.isatty() and sys.stdout.isatty() and os.environ.get("TERM") != "dumb"
        self.color = self.full and "NO_COLOR" not in os.environ
        self.root_network = root_network

    def mode(self, enter):
        if self.full:
            print("\033[?1049h" if enter else "\033[?1049l", end="", flush=True)

    def frame(self, title, lines, logo=False):
        width, height = shutil.get_terminal_size((54, 24))
        width = max(1, width - 1)
        tint = "\033[38;5;80m" if self.color else ""
        reset = "\033[0m" if tint else ""
        if self.full:
            print("\033[H\033[J", end="")
        if logo and height >= 23 and width >= 41:
            print(tint + SCYTHE.strip("\n") + reset)
        print(f"{tint}◢━━◣  SHARK / PHONEHOST  {VERSION}{reset}")
        print(tint + f"━━ {title} "[:width].ljust(width, "━") + reset)
        print("\n".join(line[:width] for line in lines), flush=True)

    def prompt(self, label):
        value = input(f"  {label} › ").strip()
        if not value:
            raise MenuBack()
        return value

    def pick(self, title, items, root=False):
        notice = ""
        while True:
            rows = [f" {index:2}. {label}" for index, (label, _) in enumerate(items, 1)]
            rows.append(f"  0. {'Выход' if root else 'Назад'}")
            if notice:
                rows.append(notice)
            self.frame(title, rows, logo=root)
            notice = ""
            value = input("  SHARK › ").strip()
            if value == "0":
                return
            if not value.isascii() or not value.isdecimal() or len(value) > 2 or not 1 <= int(value) <= len(items):
                notice = "  Выбери номер из меню."
                continue
            try:
                items[int(value) - 1][1]()
            except MenuBack:
                pass
            except KeyboardInterrupt:
                self.result("Отменено", ("Действие остановлено.",), 130)
            except (UserError, OSError, subprocess.SubprocessError, ValueError, KeyError, csv.Error) as exc:
                self.result("Ошибка", (clean(str(exc)),), 1)

    def result(self, title, lines, code=0):
        page = 0
        while True:
            width, height = shutil.get_terminal_size((54, 24))
            width = max(8, width - 4)
            stride = max(2, height - 7)
            wrapped = [part for line in lines for part in textwrap.wrap(line, width) or [""]]
            pages = max(1, (len(wrapped) + stride - 1) // stride)
            page = min(page, pages - 1)
            stamp = "Готово" if code == 0 else f"Код завершения: {code}"
            controls = " ⏎ Назад" if pages == 1 else f" {page + 1}/{pages} · n дальше · p назад · Enter выход"
            self.frame(title, [stamp, "", *wrapped[page * stride:(page + 1) * stride], "", controls])
            key = input("  › ").strip().lower()
            if key in ("n", ">") and page + 1 < pages:
                page += 1
            elif key in ("p", "<") and page > 0:
                page -= 1
            elif key in ("", "0", "q") or pages == 1:
                return

    def job(self, title, *args):
        cmd = [sys.executable, "-u", str(Path(__file__).resolve()), *args]
        with subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                              errors="replace", start_new_session=True) as proc:
            messages = queue.Queue()

            def read():
                try:
                    for line in proc.stdout:
                        messages.put(clean(line))
                finally:
                    messages.put(None)

            reader = threading.Thread(target=read, daemon=True)
            reader.start()
            output = deque(maxlen=2000)
            truncated = False
            shown_at = -1.0
            started = time.monotonic()
            frames = ("▱▱▱▱▰", "▱▱▱▰▱", "▱▱▰▱▱", "▱▰▱▱▱", "▰▱▱▱▱")
            try:
                if not self.full:
                    print(f"\n{title} · выполняется", flush=True)
                while True:
                    now = time.monotonic()
                    if self.full and now - shown_at >= 0.20:
                        recent = [line for line in list(output)[-4:] if not line.startswith("Пароль")]
                        phase = frames[int((now - started) * 5) % len(frames)]
                        self.frame(title, [f"{phase}  В работе · {int(now - started)} c", "",
                                           *recent[-2:], "", "Ctrl+C — остановить"])
                        shown_at = now
                    try:
                        line = messages.get(timeout=0.08)
                    except queue.Empty:
                        continue
                    if line is None:
                        break
                    truncated |= len(output) == output.maxlen
                    output.append(line)
            except KeyboardInterrupt:
                stop_children([proc])
                raise
            status = proc.wait()
        results = list(output)
        if truncated:
            results.insert(0, "Показаны последние 2000 строк.")
        self.result(title, results or ["Нет вывода."], status)

    def open_box_shell(self):
        name = self.prompt("Имя коробки")
        self.mode(False)
        try:
            subprocess.run([sys.executable, str(Path(__file__).resolve()), "box", "shell", name], check=True)
        finally:
            self.mode(True)

    def path(self):
        return str(Path(self.prompt("Путь к файлу")).expanduser())

    def hotspot(self):
        title = "Точка доступа / Shark"
        root = self.root_network
        notice = ""
        credentials = None
        page = 0
        snapshot = ap_snapshot(root)
        while True:
            clients = snapshot["clients"]
            height = shutil.get_terminal_size((54, 24)).lines
            span = max(1, min(8, height - 15))
            pages = max(1, (len(clients) + span - 1) // span)
            page = min(page, pages - 1)
            shown = clients[page * span:(page + 1) * span]
            label = {"off": "Выключена", "on": "Включена", "unknown": "Статус недоступен"}
            lines = ["● " + label[snapshot["state"]] + (" · root" if root else "")]
            if snapshot["upstream"]:
                lines.append(snapshot["upstream"])
            if credentials and snapshot["state"] == "on":
                lines += [f"Wi-Fi · {credentials[0]}", f"Пароль · {credentials[1]}"]
            counts = list(snapshot["active"].values())
            if counts and None not in counts:
                lines.append(f"По данным Android · устройств {sum(counts)}")
            lines += [f"Видимых адресов · {len(clients)}", ""]
            for idx, client in enumerate(shown, 1):
                name = client["name"] or "без имени"
                lines.append(f" {idx}. {client['ip']} · {name}")
            if not clients and snapshot["state"] == "on":
                lines.append("Android пока не показал адреса клиентов.")
            if pages > 1:
                lines.append(f" {page + 1}/{pages} · n дальше · p назад")
            lines += [" a  Включить локальную точку (root)",
                      " s  Раздача интернета / настройки Android",
                      " i  Внешний IP телефона и его сеть",
                      " r  Обновить    0  Назад"]
            if not root:
                lines.append(" v  Читать данные Android через root")
            if notice:
                lines.append(notice)
            self.frame(title, lines)
            print("  › ", end="", flush=True)
            if self.full and os.name == "posix":
                # No background scans: just refresh the current Android snapshot while the panel is open.
                while not select.select([sys.stdin], [], [], 6)[0]:
                    fresh = ap_snapshot(root)
                    if fresh != snapshot:
                        if fresh["state"] == "off":
                            credentials = None
                        snapshot = fresh
                        break
                else:
                    fresh = None
                if fresh is not None:
                    continue
            line = sys.stdin.readline()
            if not line:
                return
            key = line.strip().casefold()
            notice = ""
            if key in ("0", "q"):
                return
            if key == "n" and page + 1 < pages:
                page += 1
                continue
            if key == "p" and page > 0:
                page -= 1
                continue
            if len(key) == 1 and key in "12345678" and int(key) <= len(shown):
                client = shown[int(key) - 1]
                self.result("Карточка IP", ap_card(client, snapshot["upstream"]))
            elif key == "s":
                ap_settings()
            elif key == "i":
                self.job("Внешний IP телефона", "_console-view", "ap-public")
            elif key == "a":
                if snapshot["state"] == "on":
                    notice = "Точка уже включена."
                else:
                    self.frame(title, ("Android запускает защищённую локальную точку…",))
                    try:
                        credentials = ap_start()
                        root = True
                    except AP_ERRORS as exc:
                        notice = case_text(str(exc), 240) + " Клавиша s открывает настройки."
            elif key == "v":
                root = True
            elif key not in ("r", ""):
                notice = "Введи номер IP или команду из меню."
            snapshot = ap_snapshot(root)
            if snapshot["state"] == "off":
                credentials = None

    def inventory(self, mode):
        title = "Текущий Wi-Fi" if mode == "wifi" else "Своя точка доступа"
        if self.root_network:
            return self.job(title, "network", mode, "--root")
        self.pick(title, (
            ("Посмотреть IP из кэша Android", lambda: self.job(title, "network", mode)),
            ("Проверить с root, только чтение", lambda: self.job(title, "network", mode, "--root")),
        ))

    def network(self):
        self.pick("IP / Локальная сеть", (
            ("Мои адрес и шлюз", lambda: self.job("Адрес и шлюз", "_console-view", "local")),
            ("Мой внешний IP", lambda: self.job("Внешний IP", "_console-view", "public")),
            ("Кто обращался к PhoneHost", lambda: self.job("Клиенты PhoneHost", "_console-view", "clients")),
            ("Аренды DHCP своего роутера", lambda: self.job("Аренды DHCP", "_console-view", "leases", self.path())),
            ("Калькулятор подсети", lambda: self.job("Подсеть", "_console-view", "subnet",
                                                   self.prompt("IP/маска, например 192.168.1.42/24"))),
        ))

    def lookup(self):
        def dns():
            domain = self.prompt("Домен")
            kind = input("  Тип записи [A] › ").strip().upper() or "A"
            if kind not in DNS_TYPES:
                raise UserError("Доступны " + ", ".join(DNS_TYPES))
            self.job("DNS", "toolbox", "dns", domain, "--type", kind)
        self.pick("DNS / Реестры / TLS", (
            ("Записи домена", dns),
            ("Владелец диапазона публичного IP", lambda: self.job("Регистрация IP", "toolbox", "rdap", self.prompt("Публичный IP"))),
            ("Обратная DNS-запись", lambda: self.job("Обратный DNS", "_console-view", "reverse", self.prompt("Публичный IP"))),
            ("Проверка TLS-сертификата", lambda: self.job("TLS", "_console-view", "tls", self.prompt("Домен"))),
        ))

    def files(self):
        self.pick("Анализ файлов", (
            ("Отпечаток SHA-256", lambda: self.job("SHA-256", "toolbox", "hash", self.path())),
            ("Распознать формат", lambda: self.job("Формат", "_console-view", "format", self.path())),
            ("Прочитать метаданные своего файла", lambda: self.job("Метаданные", "_console-view", "metadata", self.path())),
        ))

    def services(self):
        self.pick("Мои проекты", (
            ("Список служб", lambda: self.job("Службы", "service", "list")),
            ("Добавить службу", lambda: self.job("Добавление", "service", "add", self.prompt("Имя"),
                                                        self.prompt("Абсолютный путь к стартовому скрипту в Debian"))),
            ("Убрать из запуска", lambda: self.job("Служба", "service", "remove", self.prompt("Имя службы"))),
        ))

    def servers(self):
        self.pick("Управление PhoneHost", (
            ("Запустить сервер", lambda: self.job("Запуск PhoneHost", "start")),
            ("Остановить сервер", lambda: self.job("Остановка PhoneHost", "stop")),
            ("Перезапустить сервер", lambda: self.job("Перезапуск PhoneHost", "restart")),
            ("Статус и адреса", lambda: self.job("Статус", "status")),
            ("Мои фоновые службы", self.services),
            ("Статистика HTTP за час", lambda: self.job("Статистика", "stats", "--minutes", "60", "--top", "10")),
        ))

    def boxes(self):
        actions = (("Создать отдельный Debian", "create"), ("Запустить коробку", "start"),
                   ("Остановить коробку", "stop"))
        self.pick("Коробки Debian", (
            ("Список и локальные адреса", lambda: self.job("Коробки", "box", "list")),
            *((label, lambda action=action, label=label: self.job(label, "box", action, self.prompt("Имя коробки")))
              for label, action in actions),
            ("Терминал коробки", self.open_box_shell),
        ))

    def investigate(self):
        title = "Расследование / Компания"
        self.frame(title, ("Проверка публичных деловых реквизитов.",
                           "Заполни то, что известно. Enter пропускает поле.", ""))
        fields = (("--handle", "Деловой @ник"), ("--phone", "Рабочий телефон (+код)"),
                  ("--site", "Сайт или страница компании"), ("--company", "Название компании"),
                  ("--registration", "ИНН юрлица / ОГРН / номер LV / LEI"))
        args = []
        for flag, label in fields:
            value = input(f"  {label} › ").strip()
            if value:
                args.append(f"{flag}={value}")
        bill = input("  Путь к счёту TXT / фото [необязательно] › ").strip()
        if bill:
            args.append(f"--bill={bill}")
        profile_report = input("  CSV Blackbird / Sherlock / Maigret [необязательно] › ").strip()
        if profile_report:
            args.append(f"--profile-report={profile_report}")
        if any(arg.startswith(("--handle=", "--company=")) for arg in args):
            args.append("--profiles")
        if not args:
            return
        if os.environ.get("PHONEHOST_BRAVE_KEY", "").strip():
            answer = input("  Искать деловые страницы через Brave? [y/N] › ").strip().casefold()
            if answer in ("y", "yes", "д", "да"):
                args.append("--discover")
        snapshot = input("  Имя истории [Enter — не сохранять] › ").strip()
        if snapshot:
            args.append(f"--case={snapshot}")
        self.job(title, "investigate", *args)

    def options(self):
        self.pick("Инструменты Shark", (
            ("IP и локальная сеть", self.network),
            ("Домены, реестры и сертификаты", self.lookup),
            ("Анализ файлов", self.files),
            ("Диагностика устройства", lambda: self.job("Устройство", "doctor")),
        ))

    def run(self):
        self.mode(True)
        try:
            self.pick("Пульт управления", (
                ("Текущий Wi-Fi", lambda: self.inventory("wifi")),
                ("Точка доступа · запуск и клиенты", self.hotspot),
                ("Быстрый сервер · IP и пароль", lambda: self.job("Быстрый сервер", "quick-server")),
                ("Управление сервером", self.servers),
                ("Коробки Debian", self.boxes),
                ("Инструменты Shark", self.options),
                ("Расследование · номер, ник, компания", self.investigate),
            ), root=True)
        except EOFError:
            if not self.full:
                print()
        finally:
            self.mode(False)


def console_view(argv):
    views = {
        "local": (0, local_network), "public": (0, public_address), "clients": (0, show_clients),
        "ap-public": (0, ap_public_provider),
        "leases": (1, lambda path: show_leases(Path(path))),
        "subnet": (1, subnet_info), "reverse": (1, reverse_dns), "tls": (1, check_tls),
        "format": (1, lambda path: inspect_file(Path(path))),
        "metadata": (1, lambda path: inspect_file(Path(path), metadata=True)),
    }
    if not argv or argv[0] not in views or len(argv) - 1 != views[argv[0]][0]:
        raise UserError("Неизвестное действие панели.")
    views[argv[0]][1](*argv[1:])


DNS_TYPES = ("A", "AAAA", "MX", "NS", "TXT", "CAA", "SOA")


def main(argv):
    os.umask(0o077)
    raw = argv[0] if argv else ""
    if raw == "_console-view":
        console_view(argv[1:])
        return
    if raw in ("_supervise", "_supervise_boxes"):
        supervise(boxes_only=raw == "_supervise_boxes")
        return
    if raw == "_shell_remote":
        if os.environ.get("SSH_ORIGINAL_COMMAND") or not os.environ.get("SSH_TTY"):
            raise UserError("SSH в PhoneHost открывает интерактивную сессию Debian. Подключись с TTY.")
        os.environ["PREFIX"] = str(PREFIX)
        os.environ["PATH"] = f"{PREFIX}/bin:{os.environ.get('PATH', '/system/bin')}"
        args = guest()
        os.execv(args[0], args)
    menu = argparse.ArgumentParser(prog="phonehost", description="Debian-сервер внутри Termux. Android и прошивка не меняются.")
    menu.add_argument("--version", action="version", version=f"PhoneHost {VERSION}")
    sub = menu.add_subparsers(dest="cmd")
    p = sub.add_parser("install", help="установить Debian и Nginx")
    p.add_argument("--web-port", type=int_range(1024, 65535))
    p.add_argument("--ssh-port", type=int_range(1024, 65535))
    p.add_argument("--verbose", action="store_true", help="показать весь вывод пакетных менеджеров")
    p.add_argument("--fast", action="store_true", help="пропустить финальный экран с отсчётом")
    sub.add_parser("start", help="запустить Nginx и SSH, если добавлен ключ")
    sub.add_parser("stop", help="остановить службы PhoneHost")
    sub.add_parser("restart", help="перезапустить службы PhoneHost")
    sub.add_parser("status", help="проверить службы и показать IP и порты")
    p = sub.add_parser("console", help="открыть интерактивную панель Shark")
    p.add_argument("--root-network", action="store_true", help="разрешить чтение системных данных сети через su")
    p = sub.add_parser("investigate", help="деловая проверка по сайту, рабочему номеру, нику и реестрам")
    p.add_argument("--handle", help="публичный деловой @ник")
    p.add_argument("--phone", help="рабочий телефон с международным кодом")
    p.add_argument("--company", help="название компании для сверки и веб-поиска")
    p.add_argument("--site", action="append", help="сайт компании, до двух адресов")
    p.add_argument("--registration", help="ИНН юрлица, ОГРН, регистрационный номер LV или LEI")
    p.add_argument("--bill", type=Path, help="сверить реквизиты локального счёта в TXT или фото")
    p.add_argument("--discover", action="store_true", help="искать деловые страницы через Brave с API-ключом")
    p.add_argument("--profiles", action="store_true", help="проверить публичные организации GitHub/GitLab и сайты компаний из Wikidata")
    p.add_argument("--profile-report", type=Path, action="append", help="сверить локальный CSV Blackbird, Sherlock или Maigret")
    p.add_argument("--case", help="имя локальной истории для сравнения проверок")
    p.add_argument("--json", action="store_true", help="вывести структурированный JSON-отчёт")
    p = sub.add_parser("hotspot", help="открыть настройки или посмотреть клиентов своей точки доступа")
    p.add_argument("action", choices=("status", "settings", "start"), default="status", nargs="?")
    p.add_argument("--root", action="store_true", help="читать привилегированные системные данные через su")
    p.add_argument("--json", action="store_true", help="JSON-снимок для команды status")
    p = sub.add_parser("network", help="посмотреть текущий Wi-Fi или свою точку доступа")
    p.add_argument("kind", choices=("wifi", "hotspot"))
    p.add_argument("--root", action="store_true", help="только чтение системных данных через su")
    p = sub.add_parser("quick-server", help="создать локальный веб-сервер с паролем")
    p.add_argument("--name", help="имя новой коробки")
    boxes = sub.add_parser("box", help="отдельные среды Debian и локальные веб-серверы")
    box_commands = boxes.add_subparsers(dest="action", required=True)
    box_commands.add_parser("list", help="список коробок")
    for verb in ("create", "start", "stop", "shell"):
        box_commands.add_parser(verb).add_argument("name")
    sub.add_parser("doctor", help="показать архитектуру, память, место и состояние служб")
    sub.add_parser("shell", help="открыть локальный терминал Debian")
    p = sub.add_parser("ssh-key", help="добавить публичный ключ для SSH")
    p.add_argument("path", type=Path)
    p = sub.add_parser("logs", help="читать журналы HTTP, SSH и служб")
    p.add_argument("name", default="install", nargs="?")
    selection = p.add_mutually_exclusive_group()
    selection.add_argument("--lines", type=int_range(1, 5000), default=80)
    selection.add_argument("--all", action="store_true", help="прочитать весь журнал")
    p.add_argument("-f", "--follow", action="store_true", help="следить за новыми строками")
    p = sub.add_parser("stats", help="HTTP-запросы, уникальные IP и коды ответов")
    p.add_argument("--minutes", type=int_range(1, 525600), help="ограничить окно по времени")
    p.add_argument("--top", type=int_range(1, 100), default=10)
    p = sub.add_parser("ports", help="показать или изменить порты HTTP и SSH")
    p.add_argument("--web", type=int_range(1024, 65535))
    p.add_argument("--ssh", type=int_range(1024, 65535))
    p = sub.add_parser("files", help="управлять файлами в Debian")
    p.add_argument("--web", action="store_true", help="работать с папкой сайта вместо /root/phonehost")
    file_commands = p.add_subparsers(dest="action", required=True)
    file_commands.add_parser("ls").add_argument("path", nargs="?", default=".")
    for action in ("mkdir", "touch", "cat"):
        file_commands.add_parser(action).add_argument("path")
    write = file_commands.add_parser("write")
    write.add_argument("path")
    write.add_argument("--text", help="по умолчанию данные читаются из stdin")
    p = sub.add_parser("shark", help="открыть режим Shark")
    p.add_argument("mode", choices=("ddos", "sonar", "prank"))
    p.add_argument("--seconds", type=int_range(1, 60), default=8)
    p = sub.add_parser("boot", help="настроить автозапуск через Termux:Boot")
    p.add_argument("switch", choices=("on", "off"))
    p = sub.add_parser("bench", help="измерить локальную производительность тестового сайта")
    p.add_argument("--requests", type=int_range(1, 5000), default=500)
    p.add_argument("--workers", type=int_range(1, 32), default=8)
    p = sub.add_parser("service", help="запускать свои службы в Debian")
    service = p.add_subparsers(dest="action", required=True)
    add = service.add_parser("add", help="поставить скрипт на автозапуск вместе с PhoneHost")
    add.add_argument("name")
    add.add_argument("script", help="путь внутри Debian к скрипту, который не уходит в фон")
    remove = service.add_parser("remove", help="убрать службу из автозапуска без удаления файлов")
    remove.add_argument("name")
    service.add_parser("list", help="перечислить свои службы")
    p = sub.add_parser("toolbox", help="диагностика сети и проверка файлов")
    tools = p.add_subparsers(dest="action", required=True)
    tools.add_parser("list", help="показать доступные инструменты")
    tools.add_parser("install", help="установить диагностические пакеты Debian")
    dns = tools.add_parser("dns", help="посмотреть DNS-записи домена")
    dns.add_argument("domain")
    dns.add_argument("--type", default="A", choices=DNS_TYPES)
    tools.add_parser("rdap", help="найти регистрацию публичного IP").add_argument("ip")
    tools.add_parser("hash", help="посчитать SHA-256 файла в Termux").add_argument("path", type=Path)
    opts = menu.parse_args(argv)
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if opts.cmd == "install":
        install(opts)
    elif opts.cmd == "start":
        start()
    elif opts.cmd == "stop":
        stop()
    elif opts.cmd == "restart":
        stop()
        start()
    elif opts.cmd == "status":
        status()
    elif opts.cmd == "console":
        SharkConsole(opts.root_network).run()
    elif opts.cmd == "investigate":
        case_investigate(opts)
    elif opts.cmd == "hotspot":
        if opts.action == "settings":
            ap_settings()
        elif opts.action == "start":
            ssid, password = ap_start()
            print(f"Точка запущена · {ssid}\nПароль · {password}\nРаздача интернета не подтверждена.")
        else:
            ap_print_status(ap_snapshot(opts.root), opts.json)
    elif opts.cmd == "network":
        network_inventory(opts.kind, opts.root)
    elif opts.cmd == "quick-server":
        quick_server(opts.name)
    elif opts.cmd == "box":
        manage_box(opts.action, getattr(opts, "name", None))
    elif opts.cmd == "doctor":
        doctor()
    elif opts.cmd == "shell":
        read_config()
        args = guest()
        os.execv(args[0], args)
    elif opts.cmd == "ssh-key":
        add_key(opts.path)
    elif opts.cmd == "logs":
        logs(opts.name, opts.lines, opts.all, opts.follow)
    elif opts.cmd == "stats":
        traffic(opts.minutes, opts.top)
    elif opts.cmd == "ports":
        update_ports(opts.web, opts.ssh)
    elif opts.cmd == "files":
        guest_files(opts)
    elif opts.cmd == "shark":
        shark_show(opts.mode, opts.seconds)
    elif opts.cmd == "boot":
        boot(opts.switch == "on")
    elif opts.cmd == "bench":
        bench(opts.requests, opts.workers)
    elif opts.cmd == "service":
        manage_service(opts.action, getattr(opts, "name", None), getattr(opts, "script", None))
    elif opts.cmd == "toolbox":
        toolbox(opts)
    elif sys.stdin.isatty() and sys.stdout.isatty():
        SharkConsole().run()
    else:
        menu.print_help()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (UserError, OSError, subprocess.SubprocessError, ValueError, csv.Error) as exc:
        print(f"PhoneHost: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nPhoneHost: прервано.", file=sys.stderr)
        sys.exit(130)
PHONEHOST_PY

chmod 700 "$launcher"
mv -f -- "$launcher" "$PREFIX/bin/phonehost"
if [ "$#" -eq 1 ] && [ "$1" = "--launcher-only" ]; then
  printf '\nPhoneHost 0.7 · команда обновлена. Открой панель: phonehost console\n'
  exit 0
fi
export PHONEHOST_BOOTSTRAP_SECS="$SECONDS"
exec "$PREFIX/bin/phonehost" install "$@"
