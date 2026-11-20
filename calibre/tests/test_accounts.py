import copy
import sys
import unittest
from pathlib import Path

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from nimbus_calibre import config


class TestAccountsConfig(unittest.TestCase):
    def setUp(self):
        self._orig = copy.deepcopy(dict(config.prefs))
        config.prefs.clear()
        config.prefs.update(copy.deepcopy(config.DEFAULTS))

    def tearDown(self):
        config.prefs.clear()
        config.prefs.update(self._orig)

    def test_legacy_single_account_migration(self):
        config.prefs["provider"] = "gdrive"
        config.prefs["remote_root"] = "MyNimbus"
        config.prefs["oauth_tokens"] = {"gdrive": {"access_token": "tok_abc", "refresh_token": "ref_abc"}}

        accounts = config.get_accounts()
        self.assertEqual(len(accounts), 1)
        acc = accounts[0]
        self.assertEqual(acc["provider"], "gdrive")
        self.assertEqual(acc["remote_root"], "MyNimbus")
        self.assertEqual(acc["identifier_key"], "nimbus")
        self.assertEqual(acc["oauth_tokens"]["access_token"], "tok_abc")
        self.assertEqual(config.get_default_account()["id"], acc["id"])

    def test_identifier_key_generation_and_collisions(self):
        self.assertEqual(config.make_identifier_key("Jimmy", []), "nimbus")
        self.assertEqual(config.make_identifier_key("Emma", ["nimbus"]), "nimbus_emma")
        self.assertEqual(config.make_identifier_key("Emma!", ["nimbus", "nimbus_emma"]), "nimbus_emma_2")
        self.assertEqual(config.make_identifier_key("Emma", ["nimbus", "nimbus_emma", "nimbus_emma_2"]), "nimbus_emma_3")

    def test_save_accounts_default_fallback_and_isolated_tokens(self):
        a1 = {"id": "acc_1", "name": "Jimmy", "provider": "gdrive", "oauth_tokens": {"access_token": "t1"}}
        a2 = {"id": "acc_2", "name": "Emma", "provider": "gdrive", "oauth_tokens": {"access_token": "t2"}}
        saved = config.save_accounts([a1, a2], default_account_id="acc_1")
        self.assertEqual(saved[0]["identifier_key"], "nimbus")
        self.assertEqual(saved[1]["identifier_key"], "nimbus_emma")

        config.update_account_tokens("acc_2", {"access_token": "t2_new"})
        self.assertEqual(config.get_account_by_id("acc_1")["oauth_tokens"]["access_token"], "t1")
        self.assertEqual(config.get_account_by_id("acc_2")["oauth_tokens"]["access_token"], "t2_new")

        # Removing default falls back to remaining account
        config.save_accounts([saved[1]], default_account_id="acc_1")
        self.assertEqual(config.get_default_account()["id"], "acc_2")


if __name__ == "__main__":
    unittest.main()
