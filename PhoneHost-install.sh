#!/usr/bin/env bash
# PhoneHost 0.3 • Debian on Termux, without flashing Android.
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
from collections import Counter
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
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from concurrent.futures import ThreadPoolExecutor

VERSION = "0.3.0"
INSTALL_SECONDS = 300
PREFIX = Path(os.environ.get("PREFIX") or Path(__file__).resolve().parent.parent)
STATE = Path.home() / ".phonehost"
CONTAINER = "phonehost"
IMAGE = "debian:trixie-slim"
CONTROL = STATE / "run.sock"
CONFIG = STATE / "config.json"
SERVICES = STATE / "services.json"
MARKER = STATE / "container-owned"
HEALTH = "/__phonehost_health"
HEALTH_BODY = b"phonehost-ok"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
GUEST_WEB = "/opt/phonehost/nginx.conf"
GUEST_LOGS = "/var/log/phonehost"
ACCESS = STATE / "nginx" / "access.jsonl"
BASE_LOGS = ("access", "web", "ssh", "supervisor", "install", "boot")
LOGO = "◢━━◣  PHONEHOST / SHARK"
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


def guest(*args, logs=False):
    command = [binary("proot-distro"), "login", "--isolated"]
    if logs:
        ACCESS.parent.mkdir(exist_ok=True, mode=0o700)
        command += ["--bind", f"{ACCESS.parent}:{GUEST_LOGS}"]
    command.append(CONTAINER)
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


def debian_install_command(log):
    pd = binary("proot-distro")
    result = subprocess.run([pd, "install", "--help"], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    help_text = "\n".join(clean(line) for line in result.stdout.splitlines())
    with log.open("a", encoding="utf-8") as file:
        file.write(f"\n--- proot-distro install --help (код {result.returncode}) ---\n{help_text}\n")
    if result.returncode != 0:
        raise UserError(f"Не удалось получить справку proot-distro (код {result.returncode}). Журнал: phonehost logs install.")
    if re.search(r"(?<![\w-])--name\b", help_text):
        return [pd, "install", "--name", CONTAINER, IMAGE]
    if re.search(r"(?<![\w-])--override-alias\b", help_text):
        return [pd, "install", "--override-alias", CONTAINER, "debian"]
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
        ui.run(5, "Debian · устанавливаем Nginx и сертификаты", guest("/bin/sh", "-s"), """set -eu
own_policy=0
if [ ! -e /usr/sbin/policy-rc.d ] && [ ! -L /usr/sbin/policy-rc.d ]; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    own_policy=1
fi
cleanup() {
    if [ "$own_policy" = 1 ]; then rm -f /usr/sbin/policy-rc.d; fi
}
trap cleanup EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends nginx ca-certificates
mkdir -p /var/log/phonehost
""")
        ui.run(6, "Nginx · сайт, журналы и личная папка", guest("/bin/sh", "-s", logs=True), web_setup(web_port, prepare=True))
        atomic_write(CONFIG, json.dumps({"web_port": web_port, "ssh_port": ssh_port}) + "\n")
        ui.finish(opts.fast)
    print("\n  [━━━━━━━━━━━━]  ГОТОВО\n\n  phonehost start  ·  запуск\n  phonehost shell  ·  вход в Debian\n  phonehost --help ·  все команды")
    print(f"\n  Полный лог: {ui.log}\n")


def probe_web(port, timeout=0.7):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
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
                line = response.readline(4096)
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


def supervise():
    config = read_config()
    CONTROL.unlink(missing_ok=True)
    running = True
    children = {}
    retry = {}
    specs = {"web": guest("/usr/sbin/nginx", "-c", GUEST_WEB, logs=True)}
    for name, path in read_services().items():
        specs["app-" + name] = guest("/bin/sh", path)
    if (STATE / "authorized_keys").is_file():
        specs["ssh"] = [binary("sshd"), "-D", "-e", "-f", str(STATE / "sshd_config")]

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
                        active = {name: name in children and children[name].poll() is None for name in specs}
                        payload = {"running": running, "workers": active, "ports": config}
                        conn.sendall(json.dumps(payload).encode() + b"\n")
                    except OSError:
                        pass
    finally:
        stop_children(children.values())
        CONTROL.unlink(missing_ok=True)


def port_free(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", port))
        except OSError as exc:
            raise UserError(f"Не могу открыть порт {port}: {exc.strerror}") from exc


def update_ports(web, ssh):
    with serial():
        config = read_config()
        selected = {"web_port": web or config["web_port"], "ssh_port": ssh or config["ssh_port"]}
        if selected != config:
            if rpc("status"):
                raise UserError("Сначала останови PhoneHost: phonehost stop.")
            if selected["web_port"] == selected["ssh_port"]:
                raise UserError("Для HTTP и SSH нужны разные порты.")
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
        if rpc("status"):
            print("PhoneHost уже запущен. Подробности: phonehost status.")
            return
        port_free(conf["web_port"])
        with_ssh = (STATE / "authorized_keys").is_file()
        if with_ssh:
            port_free(conf["ssh_port"])
            render_sshd(conf["ssh_port"])
        proc = start_child("supervisor", [sys.executable, str(Path(__file__).resolve()), "_supervise"])
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline:
            if (rpc("status") and probe_web(conf["web_port"])
                    and (not with_ssh or probe_ssh(conf["ssh_port"]))):
                status()
                return
            if proc.poll() is not None:
                break
            time.sleep(0.25)
        called = rpc("stop")
        if called is None:
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
        names = dict.fromkeys((*BASE_LOGS, *("app-" + n for n in read_services()), *live))
        return {n: ACCESS if n == "access" else STATE / (n + ".log") for n in names}
    if name not in BASE_LOGS and not re.fullmatch(r"app-[a-z][a-z0-9-]{0,31}", name):
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
        print("install  Пакеты bind9-dnsutils, jq и openssl в Debian")
    elif opts.action == "install":
        read_config()
        subprocess.run(guest("/usr/bin/apt-get", "update"), check=True)
        subprocess.run(guest("/usr/bin/apt-get", "install", "-y", "--no-install-recommends",
                             "bind9-dnsutils", "jq", "openssl"), check=True)
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


def main(argv):
    os.umask(0o077)
    raw = argv[0] if argv else ""
    if raw == "_supervise":
        supervise()
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
    dns.add_argument("--type", default="A", choices=("A", "AAAA", "MX", "NS", "TXT", "CAA", "SOA"))
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
    else:
        menu.print_help()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (UserError, OSError, subprocess.CalledProcessError, ValueError) as exc:
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
