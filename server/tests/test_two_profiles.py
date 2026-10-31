"""Simulation de deux profils du téléphone qui se synchronisent avec le
serveur, avec la même logique que l'appli (lib/data/library.dart, _syncState,
et lib/data/database.dart, applyRemote) : la version la plus récente gagne."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from store import Store  # noqa: E402


class Profile:
    """Miroir local (sync_items) d'un profil, comme dans l'appli."""

    def __init__(self, store: Store):
        self.store = store
        self.items: dict[tuple, dict] = {}  # (kind, key) -> élément + dirty
        self.since = 0
        self.epoch = None

    def write(self, kind, key, data, at, deleted=False):
        self.items[(kind, key)] = {"kind": kind, "key": key, "data": data,
                                   "updated_at": at, "deleted": deleted, "dirty": True}

    def sync(self):
        for _ in range(50):
            outgoing = [dict(v) for v in self.items.values() if v["dirty"]][:500]
            for o in outgoing:
                o.pop("dirty")
            if self.epoch not in (None, self.store.epoch):
                self.since = 0
            response = self.store.sync_state(self.since, outgoing)
            if self.epoch is not None and response["epoch"] != self.epoch:
                for v in self.items.values():
                    v["dirty"] = True
                self.since, self.epoch = 0, response["epoch"]
                continue
            for o in outgoing:  # markSent : seulement si pas modifié entre-temps
                local = self.items[(o["kind"], o["key"])]
                if local["updated_at"] == o["updated_at"]:
                    local["dirty"] = False
            for c in response["changes"]:  # applyRemote
                local = self.items.get((c["kind"], c["key"]))
                if local is not None and local["updated_at"] >= c["updated_at"]:
                    continue
                self.items[(c["kind"], c["key"])] = {**c, "dirty": False}
            self.since, self.epoch = response["seq"], response["epoch"]
            if not response["more"] and len(outgoing) < 500:
                return

    def view(self):
        return {k: (v["data"], v["deleted"]) for k, v in self.items.items()}


class TwoProfilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name), quota_bytes=10**9)
        self.a, self.b = Profile(self.store), Profile(self.store)

    def tearDown(self):
        self.tmp.cleanup()

    def test_converge(self):
        a, b = self.a, self.b
        # État existant de chaque profil avant la mise à jour (migration v5).
        a.write("progress", "L1", {"page": 40, "opened": 100}, 100)
        a.write("category", "reseau", {"name": "Réseau"}, 10)
        a.write("bookcat", "L1|reseau", {}, 10)
        b.write("progress", "L1", {"page": 12, "opened": 50}, 50)
        b.write("category", "reseau", {"name": "Reseau"}, 20)  # même clé : fusion
        b.write("annotation", "n1", {"book_id": "L1", "page": 3, "note": "x"}, 60)
        a.sync(); b.sync(); a.sync()
        self.assertEqual(a.view(), b.view())
        self.assertEqual(a.view()[("progress", "L1")][0]["page"], 40)

        # B lit jusqu'à la page 41 et supprime la note ; A ajoute un marque-page.
        b.write("progress", "L1", {"page": 41, "opened": 200}, 200)
        b.write("annotation", "n1", {}, 210, deleted=True)
        a.write("bookmark", "L1|7", {}, 205)
        a.sync(); b.sync(); a.sync()
        self.assertEqual(a.view(), b.view())
        self.assertEqual(a.view()[("progress", "L1")][0]["page"], 41)
        self.assertTrue(a.view()[("annotation", "n1")][1])
        self.assertFalse(b.view()[("bookmark", "L1|7")][1])

    def test_many_items_paged(self):
        for i in range(4500):
            self.a.write("bookmark", f"L|{i}", {}, i + 1)
        self.a.sync()
        self.b.sync()
        self.assertEqual(len(self.b.view()), 4500)

    def test_server_reset(self):
        self.a.write("title", "L1", {"title": "Mon livre"}, 5)
        self.a.sync()
        # Le serveur perd sa base d'état (disque changé, base recréée…).
        fresh = tempfile.TemporaryDirectory()
        self.addCleanup(fresh.cleanup)
        self.a.store = Store(Path(fresh.name), quota_bytes=10**9)
        self.a.sync()
        b = Profile(self.a.store)
        b.sync()
        self.assertEqual(b.view()[("title", "L1")][0], {"title": "Mon livre"})


if __name__ == "__main__":
    unittest.main()
