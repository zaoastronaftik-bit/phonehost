#!/usr/bin/env bash
# PhoneHost 0.5 • Debian on Termux, without flashing Android.
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
import fcntl
import getpass
import hashlib
import http.client
import ipaddress
import json
import math
import os
import platform
from pathlib import Path
import queue
import random
import re
import secrets
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
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from concurrent.futures import ThreadPoolExecutor

VERSION = "0.5.0"
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


def public_address():
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, *_args):
            raise UserError("Проверка внешнего IP неожиданно попросила перенаправление.")

    print("Внешняя проверка · запрос к api64.ipify.org", flush=True)
    with build_opener(NoRedirect()).open("https://api64.ipify.org?format=json", timeout=8) as response:
        payload = json.loads(response.read(2048))
    address = ipaddress.ip_address(payload["ip"])
    print(f"IP, который увидел сервис: {address}")


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
    # The raw dump may contain Wi-Fi configuration; only parsed fields are displayed.
    dump = system_probe(["/system/bin/dumpsys", "-t", "8", "wifi"], root)
    state, active = parse_softap(dump)
    if state == "off":
        print("Точка доступа выключена. Включи «Мобильная точка доступа» в настройках Android и повтори проверку.")
    elif state == "unknown":
        print("Не удалось надёжно определить состояние точки. Проверь его в настройках Android.")
    else:
        print("Точка доступа включена.")
        for iface, count in sorted(active.items()):
            suffix = f" · подключено по данным Android: {count}" if count is not None else ""
            print(f"Интерфейс: {iface}{suffix}")
            if count != 0:
                print_neighbours(iface, root)
        print("Адреса взяты из кэша этой точки и могут покрывать не всех клиентов.")


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
            except (UserError, OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
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
                ("Своя точка доступа", lambda: self.inventory("hotspot")),
                ("Быстрый сервер · IP и пароль", lambda: self.job("Быстрый сервер", "quick-server")),
                ("Управление сервером", self.servers),
                ("Коробки Debian", self.boxes),
                ("Инструменты Shark", self.options),
            ), root=True)
        except EOFError:
            if not self.full:
                print()
        finally:
            self.mode(False)


def console_view(argv):
    views = {
        "local": (0, local_network), "public": (0, public_address), "clients": (0, show_clients),
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
    except (UserError, OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"PhoneHost: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nPhoneHost: прервано.", file=sys.stderr)
        sys.exit(130)
PHONEHOST_PY

chmod 700 "$launcher"
mv -f -- "$launcher" "$PREFIX/bin/phonehost"
export PHONEHOST_BOOTSTRAP_SECS="$SECONDS"
exec "$PREFIX/bin/phonehost" install "$@"
