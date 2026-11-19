from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_investigate import ph


class Profiles(unittest.TestCase):
    def test_csv_supported_and_only_corroborated_links_reported(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bb, sherlock, maigret = [root / name for name in ("bb.csv", "s.csv", "m.csv")]
            bb.write_text("name,url\nTelegram,https://t.me/demo_shop\nX,https://x.com/unrelated\n", encoding="utf-8")
            sherlock.write_text("username,name,url_main,url_user,exists,http_status\n"
                                "demo_shop,Telegram,https://t.me,https://t.me/demo_shop,Claimed,200\n"
                                "demo_shop,Instagram,https://instagram.com,https://instagram.com/demo_shop,Available,404\n",
                                encoding="utf-8")
            maigret.write_text("username,name,url_main,url_user,exists,http_status\n"
                               "demo_shop,Twitter,https://x.com,https://twitter.com/demo_shop,Claimed,200\n",
                               encoding="utf-8")
            results = {}
            for path in (bb, sherlock, maigret):
                for key in ph.case_import_profiles(path):
                    results.setdefault(key, set()).add(path.name)
            report = {"pages": [{"url":"https://shop-demo.org/", "facts": [
                ["profile", "https://t.me/demo_shop"], ["profile", "https://x.com/demo_shop"]
            ]}]}
        matches = ph.case_account_links(report, [], results)
        self.assertEqual(len(matches), 2)
        self.assertEqual(matches[0]["reports"], ["bb.csv", "s.csv"])
        self.assertEqual(matches[1]["reports"], ["m.csv"])
        self.assertNotIn("instagram.com/demo_shop", results)

    def test_github_user_and_private_gitlab_group_not_included(self):
        def fetch(url):
            if "github" in url:
                return {"type":"User", "login":"demo"}
            return {"visibility":"private", "full_path":"demo"}
        with patch.object(ph, "case_json", side_effect=fetch):
            self.assertEqual(ph.case_org_accounts("demo"), ([], []))

    def test_public_organization_link_state(self):
        def fetch(url):
            if "github" in url:
                return {"type":"Organization", "login":"demo", "name":"Demo", "blog":"https://shop-demo.org"}
            return {"visibility":"public", "full_path":"demo", "name":"Demo"}
        with patch.object(ph, "case_json", side_effect=fetch):
            accounts, failures = ph.case_org_accounts("demo")
        self.assertEqual(failures, [])
        ph.case_account_links({"pages":[{"url":"https://shop-demo.org/", "facts":[]}]}, accounts, {})
        self.assertEqual(len(accounts), 2)
        self.assertIn("ведёт на проверенный сайт", accounts[0]["link_state"])
        self.assertIn("связь не подтверждена", accounts[1]["link_state"])

    def test_wikidata_filters_person_and_similar_name(self):
        def claim(val):
            return {"rank":"normal", "mainsnak":{"datavalue":{"value":val}}}
        search = {"search": [{"id":"Q1","label":"Demo"}, {"id":"Q2","label":"Demo"},
                             {"id":"Q3","label":"Demo Incorporated"}]}
        record = {"entities":{"Q1":{"claims":{"P31":[claim({"id":"Q783794"})],
                                              "P856":[claim("https://shop-demo.org/")]}},
                              "Q2":{"claims":{"P31":[claim({"id":"Q5"})],
                                              "P856":[claim("https://person-demo.org/")]}}}}
        with patch.object(ph, "case_json", side_effect=[search, record]):
            results = ph.case_wikidata_sites("Demo")
        self.assertEqual([row["url"] for row in results], ["https://shop-demo.org/"])


if __name__ == "__main__":
    unittest.main()
