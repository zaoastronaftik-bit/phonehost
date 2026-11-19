#!/usr/bin/env python3
"""PhoneHost LAN companion. Run on your own hotspot host with Python 3."""
import argparse
from datetime import datetime
from html import escape
from http import HTTPStatus
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import IPv4Address, IPv6Address, ip_address, ip_network
from pathlib import Path
import secrets
import threading
import time
from urllib.parse import parse_qs

PRIVATE_V4 = tuple(ip_network(cidr) for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
PRIVATE_V6 = ip_network("fc00::/7")
TTL = 1800
CSS = """
:root{color-scheme:dark;--bg:#131617;--card:#1b2021;--line:#303738;--fg:#f3f5f4;--muted:#a3b0ac;--mint:#97eabf}
*{box-sizing:border-box}body{margin:0;padding:clamp(20px,6vw,72px) 18px;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,sans-serif}
main{max-width:800px;margin:auto}header{display:flex;align-items:center;gap:10px;color:var(--mint);font:600 13px ui-monospace,monospace;letter-spacing:.12em}
h1{font-size:clamp(34px,7vw,58px);line-height:1.03;letter-spacing:-.055em;margin:26px 0 9px}p{margin:0 0 18px;color:var(--muted)}section{margin:22px 0;padding:18px;border:1px solid var(--line);border-radius:14px;background:var(--card)}
h2{font-size:17px;margin:0 0 12px}.ip{font:600 clamp(22px,5vw,36px) ui-monospace,monospace;overflow-wrap:anywhere}.badge{color:var(--mint);font-size:13px}.meta{font:600 13px ui-monospace,monospace;color:var(--muted)}
table{width:100%;border-collapse:collapse;text-align:left;font-size:14px}th,td{padding:7px 12px 7px 0;border-bottom:1px solid var(--line);overflow-wrap:anywhere}th{color:var(--muted)}code{font-family:ui-monospace,monospace}.actions{display:flex;gap:9px;align-items:center;flex-wrap:wrap}
button,input,a.button{padding:9px 13px;border:1px solid var(--line);border-radius:8px;font:inherit;color:var(--fg);background:var(--bg)}
button,a.button{background:var(--mint);color:#13231b;text-decoration:none;cursor:pointer;font-weight:700}button.secondary{background:var(--bg);color:var(--fg)}
a{color:var(--mint)}small{color:var(--muted)}.scroll{overflow:auto}
"""


def lan_address(addr):
    if isinstance(addr, IPv4Address):
        return any(addr in network for network in PRIVATE_V4)
    return isinstance(addr, IPv6Address) and addr in PRIVATE_V6


def host_ip(raw):
    try:
        addr = ip_address(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("укажи IPv4-адрес интерфейса раздачи") from exc
    if not isinstance(addr, IPv4Address) or not lan_address(addr):
        raise argparse.ArgumentTypeError("ожидается локальный IPv4 точки доступа")
    return str(addr)


def port_number(raw):
    port = int(raw)
    if not 1024 <= port <= 65535:
        raise argparse.ArgumentTypeError("порт должен быть в диапазоне 1024–65535")
    return port


def local_time(value):
    return datetime.fromtimestamp(value).strftime("%H:%M:%S")


def pretty_name(raw):
    return "".join(char for char in raw if char.isprintable()).strip()[:48]


class Visitors:
    def __init__(self):
        self.rows = {}
        self.lock = threading.Lock()

    def prune(self, now):
        for key in tuple(self.rows):
            if now - self.rows[key][2] >= TTL:
                del self.rows[key]

    def mark(self, token, addr, name):
        now = time.time()
        with self.lock:
            self.prune(now)
            if token not in self.rows or self.rows[token][0] != addr:
                token = secrets.token_urlsafe(24)
            if len(self.rows) >= 256 and token not in self.rows:
                del self.rows[min(self.rows, key=lambda key: self.rows[key][2])]
            self.rows[token] = (addr, pretty_name(name), now)
        return token

    def leave(self, token, addr):
        with self.lock:
            row = self.rows.get(token)
            if row and row[0] == addr:
                self.rows.pop(token)

    def snapshot(self):
        with self.lock:
            self.prune(time.time())
            return dict(self.rows)


def leases(path):
    """Read an explicit local dnsmasq export without exposing MAC addresses."""
    now = time.time()
    result = {}
    with path.open("rb") as file:
        data = file.read(512 * 1024 + 1)
    if len(data) > 512 * 1024:
        raise ValueError("таблица DHCP превышает 512 КБ")
    for line in data.decode("utf-8", "replace").splitlines():
        fields = line.split()
        if len(fields) != 5:
            continue
        try:
            expiry, ip = int(fields[0]), ip_address(fields[2])
        except ValueError:
            continue
        if (expiry > now or expiry == 0) and lan_address(ip):
            name = pretty_name(fields[3]) if fields[3] != "*" else ""
            result[str(ip)] = (name, expiry)
    return sorted(result.items(), key=lambda row: (ip_address(row[0]).version, int(ip_address(row[0]))))


def document(title, body):
    return ("<!doctype html><html lang='ru'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            f"<title>{escape(title)} · PhoneHost LAN</title><style>{CSS}</style></head>"
            "<body><main><header><span>◢━━◣</span> PHONEHOST / LAN</header>"
            f"{body}</main></body></html>").encode("utf-8")


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, host, port, visitors, lan, admin_key=None, lease_path=None):
        self.address = f"{host}:{port}"
        self.lan = lan
        self.visitors = visitors
        self.admin_key = admin_key
        self.lease_path = lease_path
        super().__init__((host, port), Handler)

    def get_request(self):
        sock, addr = super().get_request()
        sock.settimeout(5)
        return sock, addr


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def send(self, status, body=b"", *, cookie=None, redirect=None):
        self.send_response(status)
        for key, val in (
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Length", str(len(body))),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "same-origin"),
            ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; "
             "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"),
        ):
            self.send_header(key, val)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        if redirect:
            self.send_header("Location", redirect)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def valid_host(self):
        if self.headers.get_all("Host") != [self.server.address]:
            self.send(HTTPStatus.BAD_REQUEST)
            return False
        return True

    def guest_id(self):
        try:
            return SimpleCookie(self.headers.get("Cookie", ""))["phlan"].value
        except (KeyError, CookieError):
            return None

    def do_GET(self):
        if not self.valid_host():
            return
        if self.server.admin_key is not None:
            if not secrets.compare_digest(self.path.encode(), self.server.admin_key.encode()):
                return self.send(HTTPStatus.NOT_FOUND)
            return self.admin_page()
        if self.path != "/":
            return self.send(HTTPStatus.NOT_FOUND)
        self.guest_page()

    def guest_page(self):
        addr = self.client_address[0]
        entry = self.server.visitors.snapshot().get(self.guest_id())
        active = entry is not None and entry[0] == addr
        form = (
            "<p class='badge'>Ты отметился в этой сети. Запись видит администратор этой точки.</p>"
            "<form method='post' action='/leave'><button class='secondary'>Убрать свою отметку</button></form>"
        ) if active else (
            "<p>Если отметишься, администратор точки увидит этот локальный IP и имя, которое ты укажешь. "
            "Отметка видна 30 минут.</p>"
            "<form class='actions' method='post' action='/join'>"
            "<input name='name' aria-label='Имя устройства' placeholder='Имя устройства, не обязательно' maxlength='48'>"
            "<button>Отметиться</button></form>"
        )
        self.send(HTTPStatus.OK, document("Это ты",
            f"<h1>Твоё подключение</h1><p>Адрес с точки зрения сервера в локальной сети.</p>"
            f"<section><div class='badge'>● ЭТО ТЫ</div><div class='ip'>{escape(addr)}</div>"
            f"<div class='meta'>Сервер &nbsp; {escape(self.server.lan)}</div></section>{form}"))

    def admin_page(self):
        marks = sorted(self.server.visitors.snapshot().values(), key=lambda row: row[2], reverse=True)
        rows = "".join(
            f"<tr><td>{escape(name or 'Без имени')}</td><td><code>{escape(ip)}</code></td>"
            f"<td>{local_time(stamp)}</td></tr>" for ip, name, stamp in marks
        ) or "<tr><td colspan='3'>Пока никто не отметился</td></tr>"
        extra = ""
        if self.server.lease_path is not None:
            try:
                dhcp = leases(self.server.lease_path)
                dhcp_rows = "".join(
                    f"<tr><td>{escape(name or 'Без имени')}</td><td><code>{escape(ip)}</code></td></tr>"
                    for ip, (name, _expires) in dhcp
                ) or "<tr><td colspan='2'>Нет действующих аренд в файле</td></tr>"
                extra = ("<section><h2>DHCP · таблица роутера</h2>"
                         "<p>Действующая аренда не означает, что устройство сейчас на связи.</p>"
                         f"<table><thead><tr><th>Имя</th><th>IP</th></tr></thead><tbody>{dhcp_rows}</tbody></table></section>")
            except (OSError, ValueError):
                extra = "<section><h2>DHCP · таблица роутера</h2><p>Не удалось прочитать указанный файл.</p></section>"
        self.send(HTTPStatus.OK, document("Панель",
            f"<h1>Кто отметился</h1><p>Локальный список · {len(marks)} записей</p>"
            f"<div class='actions'><a class='button' href='{escape(self.server.admin_key)}'>Обновить</a>"
            f"<small>Гостевая страница: <code>http://{escape(self.server.lan)}/</code></small></div>"
            f"<section class='scroll'><table><thead><tr><th>Устройство</th><th>Локальный IP</th><th>Время</th></tr>"
            f"</thead><tbody>{rows}</tbody></table></section>{extra}"))

    def do_POST(self):
        if not self.valid_host():
            return
        if self.server.admin_key is not None or self.path not in ("/join", "/leave"):
            return self.send(HTTPStatus.NOT_FOUND)
        origin = f"http://{self.server.address}"
        if self.headers.get("Origin") != origin:
            return self.send(HTTPStatus.FORBIDDEN)
        if self.headers.get("Content-Type") != "application/x-www-form-urlencoded":
            return self.send(HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
        lengths = self.headers.get_all("Content-Length")
        raw_len = lengths[0] if lengths and len(lengths) == 1 else ""
        if not raw_len.isascii() or not raw_len.isdecimal() or len(raw_len) > 4 or int(raw_len) > 2048:
            return self.send(HTTPStatus.BAD_REQUEST)
        try:
            values = parse_qs(self.rfile.read(int(raw_len)).decode("utf-8"), max_num_fields=2)
        except ValueError:
            return self.send(HTTPStatus.BAD_REQUEST)
        addr = self.client_address[0]
        existing = self.guest_id()
        if self.path == "/leave":
            self.server.visitors.leave(existing, addr)
            cookie = "phlan=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict"
        else:
            token = self.server.visitors.mark(existing, addr, values.get("name", [""])[0])
            cookie = f"phlan={token}; Max-Age={TTL}; Path=/; HttpOnly; SameSite=Strict"
        self.send(HTTPStatus.SEE_OTHER, cookie=cookie, redirect="/")


def main():
    parser = argparse.ArgumentParser(description="LAN-помощник PhoneHost для своей точки доступа.")
    parser.add_argument("--host", required=True, type=host_ip, help="локальный IPv4 хоста на интерфейсе раздачи")
    parser.add_argument("--port", type=port_number, default=8081, help="порт гостевой страницы (8081)")
    parser.add_argument("--admin-port", type=port_number, default=8082, help="локальный порт панели (8082)")
    parser.add_argument("--leases", type=Path, help="файл dnsmasq.leases со своего роутера, необязательно")
    args = parser.parse_args()
    if args.leases is not None and not args.leases.is_file():
        parser.error("--leases должен указывать на существующий файл")
    lan = f"{args.host}:{args.port}"
    auth = "/" + secrets.token_urlsafe(24) + "/"
    visitors = Visitors()
    try:
        with Server(args.host, args.port, visitors, lan) as guest:
            with Server("127.0.0.1", args.admin_port, visitors, lan, auth, args.leases) as admin:
                print(f"Гостевая страница: http://{lan}/\nПанель хоста: http://{admin.address}{auth}\nВыход: Ctrl+C", flush=True)
                thread = threading.Thread(target=admin.serve_forever, daemon=True)
                thread.start()
                try:
                    guest.serve_forever()
                finally:
                    admin.shutdown()
                    thread.join()
    except KeyboardInterrupt:
        return
    except OSError as exc:
        parser.exit(1, f"PhoneHost LAN: {exc}\n")


if __name__ == "__main__":
    main()
