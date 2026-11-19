"""Run with python -m unittest discover -s tests -v (no network or API keys)."""
import argparse
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch


INSTALLER = Path(__file__).resolve().parents[1] / "PhoneHost-install.sh"
PAYLOAD = INSTALLER.read_text(encoding="utf-8").split("<<'PHONEHOST_PY'\n", 1)[1].split("\nPHONEHOST_PY\n", 1)[0]
ph = types.ModuleType("phonehost")
ph.__file__ = str(INSTALLER)
exec(compile(PAYLOAD, str(INSTALLER), "exec"), vars(ph))

DOMAIN = "https://www.shop-demo.org/"
PAGE = '''<!DOCTYPE html>
<meta name="description" content="Сервис и ремонт ноутбуков">
<script type="application/ld+json">
{"@context":"https://schema.org","@graph":[
  {"@type":"Person","name":"Не публиковать","telephone":"+12025550110"},
  {"@type":"Organization","legalName":"Demo Shop SIA","taxID":"LV40003032949",
   "industry":"Ремонт техники","sameAs":["https://t.me/demo_shop"],
   "contactPoint":[{"@type":"ContactPoint","telephone":"+371 2000 1000"}]}
]}
</script>
<a href="tel:+37120001000">Звонок</a>
<a href="https://www.shop-demo.org/kontakti">Контакты</a>
<a href="https://t.me/share/url?url=https://shop-demo.org">Поделиться</a>
<script>var a = "ИНН 7707083893";</script>
'''


def opts(**overrides):
    return argparse.Namespace(**dict({"company": "", "phone": "+37120001000", "handle": "@demo_shop",
                                      "registration": "", "site": [DOMAIN], "discover": False,
                                      "bill": None, "case": None, "json": False}, **overrides))


class Investigate(unittest.TestCase):
    def test_inputs(self):
        self.assertEqual(ph.case_phone("+371 (2000) 1000", ""), "+37120001000")
        self.assertEqual(ph.case_phone("8 (800) 555-35-35", "RU"), "+78005553535")
        self.assertEqual(ph.case_identifier("LV40003032949"), ("LV", "40003032949"))
        self.assertEqual(ph.case_identifier("7707083893"), ("RU", "7707083893"))
        self.assertEqual(ph.case_identifier("1027700132195"), ("RU", "1027700132195"))
        self.assertEqual(ph.case_identifier("7707083894"), ("", ""))
        self.assertEqual(ph.case_identifier("5493001KJTIIGC8Y1R12"), ("LEI", "5493001KJTIIGC8Y1R12"))
        self.assertEqual(ph.case_identifier("231234567891"), ("", ""))
        with self.assertRaises(ph.UserError):
            ph.case_collect(opts(phone="1234"))

    def test_https_only_and_safe_hosts(self):
        for url in ("http://example.org/", "https://localhost/", "https://127.0.0.1/",
                    "https://example.org:8080/", "https://a@evil.org/", "https://[::1]/",
                    "shop.local", "example.org\\@evil.org", "https://a." + "b" * 64 + "/"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                ph.case_url(url)
        self.assertEqual(ph.case_url(DOMAIN + "?token=secret#part"), DOMAIN)

    def test_dns_never_returns_private_or_ipv6_transition_candidates(self):
        answers = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", (value, 443))
            for value in ("192.168.0.1", "127.0.0.1", "100.64.0.1", "169.254.169.254", "93.184.216.34")
        ] + [
            (socket.AF_INET6, socket.SOCK_STREAM, 6, "", (value, 443, 0, 0))
            for value in ("::ffff:127.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::1", "ff02::1")
        ]
        with patch.object(ph.socket, "getaddrinfo", return_value=answers):
            self.assertEqual(ph.case_public_ips("demo.org"), ["93.184.216.34"])

    def test_published_organization_not_person_or_scripts(self):
        facts, more = ph.case_evidence(DOMAIN, PAGE, "LV", supplied=True)
        self.assertIn(("phone", "+37120001000"), facts)
        self.assertIn(("organization", "Demo Shop SIA"), facts)
        self.assertIn(("description", "Сервис и ремонт ноутбуков"), facts)
        self.assertIn(("activity", "Ремонт техники"), facts)
        self.assertIn(("identifier", "40003032949"), facts)
        self.assertIn(("profile", "https://t.me/demo_shop"), facts)
        self.assertNotIn(("phone", "+12025550110"), facts)
        self.assertNotIn(("organization", "Не публиковать"), facts)
        self.assertNotIn(("identifier", "7707083893"), facts)
        self.assertEqual(more, [DOMAIN + "kontakti"])
        self.assertEqual(ph.case_evidence(DOMAIN, '<a href="tel:+37120001000">person</a>', "", supplied=False)[0], [])

    def test_discovery_requires_corroboration(self):
        other = "https://www.other-shop.org/"
        third = "https://www.third-shop.org/"
        with patch.object(ph, "case_discovery", return_value=([other, third], None)), \
             patch.object(ph, "case_html", side_effect=[
                 (other, PAGE),
                 (third, PAGE.replace("demo_shop", "unrelated").replace("+371 2000 1000", "+371 2000 1001")),
             ]), patch.object(ph, "case_registry", return_value={"status": "found"}):
            report = ph.case_collect(opts(site=[], discover=True))
        self.assertEqual([p["url"] for p in report["pages"]], [other])

    def test_registry_states_and_non_business_filter(self):
        def lv(rows):
            return {"success": True, "result": {"records": rows}}
        record = {"regcode": 40003032949, "type": "AS", "name": "Demo AS", "registered": "1991-10-08",
                  "closed": " ", "terminated": None, "address": "excluded"}
        with patch.object(ph, "case_json", return_value=lv([record])):
            info = ph.case_registry("LV", "40003032949")
            self.assertEqual(info["status"], "found")
            self.assertEqual(info["state"], "в записи нет даты исключения")
            self.assertNotIn("address", info)
        with patch.object(ph, "case_json", return_value=lv([dict(record, type="IK", name="Private name")])):
            info = ph.case_registry("LV", "40003032949")
        self.assertEqual(info["status"], "outside_scope")
        self.assertNotIn("name", info)
        with patch.object(ph, "case_json", return_value=lv([])):
            self.assertEqual(ph.case_registry("LV", "40003032949")["status"], "not_found")
        with patch.object(ph, "case_json", side_effect=ph.UserError("timeout")):
            out = ph.case_collect(opts(phone="", handle="", site=[], registration="40003032949"))
        self.assertEqual(out["registry"][0]["status"], "unavailable")

    def test_russian_legal_entity_only(self):
        rows = [{"data": {"type": "INDIVIDUAL", "inn": "7707083893"}},
                {"data": {"type": "LEGAL", "inn": "7707083893", "name": {"full_with_opf": 'ПАО "Демо"'},
                          "okved": "62.01", "state": {"status": "ACTIVE"}, "management": {"name": "exclude"}}}]
        with patch.dict(ph.os.environ, {"PHONEHOST_DADATA_KEY": "test"}), \
             patch.object(ph, "case_json", return_value={"suggestions": rows}) as fetch:
            data = ph.case_registry("RU", "7707083893")
        self.assertEqual(data["activity"], "62.01")
        self.assertNotIn("management", data)
        self.assertEqual(json.loads(fetch.call_args.kwargs["data"])["type"], "LEGAL")
        with patch.dict(ph.os.environ, {"PHONEHOST_DADATA_KEY": ""}):
            self.assertEqual(ph.case_registry("RU", "7707083893")["status"], "manual")

    def test_name_results_are_candidates_and_exact(self):
        def row(name, category="GENERAL"):
            return {"id":"5493001KJTIIGC8Y1R12",
                    "attributes":{"entity":{"legalName":{"name":name},"category":category}}}
        response = {"data": [row("Demo L.P."), row("Demo Finance L.P."), row("Demo L.P.", "SOLE_PROPRIETOR")]}
        with patch.object(ph, "case_json", return_value=response):
            result = ph.case_registry_name("Demo L.P.")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["status"], "name_match")

    def test_html_checks_redirect_before_connecting(self):
        class FakeResponse:
            status = 307

            def getheader(self, _):
                return "https://127.0.0.1/admin"

            def close(self):
                pass

        class FakeConnection:
            def __init__(self, *_):
                pass

            def request(self, *_, **__):
                pass

            def getresponse(self):
                return FakeResponse()

            def close(self):
                pass

        with patch.object(ph, "case_public_ips", return_value=["93.184.216.34"]) as resolve, \
             patch.object(ph, "CaseConnection", FakeConnection), self.assertRaises(ValueError):
            ph.case_html(DOMAIN)
        resolve.assert_called_once_with("www.shop-demo.org")

    def test_local_bill_and_unavailable_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            bill = Path(tmp) / "invoice.txt"
            bill.write_text("ИНН: 7707083893\nТелефон: +7 495 555-43-21\nЛичный текст\n", encoding="utf-8")
            self.assertEqual(ph.case_bill(bill, "RU"), [
                ("identifier", "7707083893"), ("phone", "+74955554321")
            ])
            with patch.object(ph, "STATE", Path(tmp)), patch.object(ph, "case_html", return_value=(DOMAIN, PAGE)), \
                 patch.object(ph, "case_registry", return_value={"status": "found"}), redirect_stdout(io.StringIO()):
                ph.case_investigate(opts(case="shop", bill=bill, json=True))
            snap = Path(tmp) / "investigations" / "shop.json"
            raw = snap.read_text()
            self.assertNotIn("Личный текст", raw)
            self.assertEqual(snap.stat().st_mode & 0o777, 0o600)
            prior = json.loads(raw)
            no_page = dict(prior, pages=[{"url": DOMAIN, "error": "timeout"}])
            self.assertIn("Удаление", ph.case_changes(prior, no_page)[0])
            new = dict(prior, pages=[{"url": DOMAIN, "facts": [["phone", "+37120001002"]]}])
            self.assertTrue(any("+37120001002" in change for change in ph.case_changes(prior, new)))

    def test_help_and_panel(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "phonehost.py"
            script.write_text(PAYLOAD, encoding="utf-8")
            env = dict(ph.os.environ, HOME=tmp, PHONEHOST_BRAVE_KEY="", PHONEHOST_DADATA_KEY="")
            result = subprocess.run(["python3", str(script), "console"], env=env,
                                    input="7\n\n\n\n\n7707083893\n\n\n\n0\n", text=True,
                                    capture_output=True, timeout=5, check=True)
        self.assertIn("Расследование", result.stdout)
        self.assertIn("Ручная проверка в ФНС", result.stdout)


if __name__ == "__main__":
    unittest.main()
