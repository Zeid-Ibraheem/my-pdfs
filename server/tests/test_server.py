"""Tests du serveur : python3 -m unittest discover -s tests (depuis server/)."""

from __future__ import annotations

import hashlib
import json
import socket
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

import requests
import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import discover  # noqa: E402
from app import create_app  # noqa: E402
from config import Settings  # noqa: E402
from store import QuotaExceeded, Store  # noqa: E402

TOKEN = "jeton-de-test-0123456789"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def make_pdf(pages: list[str]) -> bytes:
    """PDF minimal avec du vrai texte (police Helvetica, encodage WinAnsi)."""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        (
            "<< /Type /Pages /Kids ["
            + " ".join(f"{4 + 2 * i} 0 R" for i in range(len(pages)))
            + f"] /Count {len(pages)} >>"
        ).encode(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica"
        b" /Encoding /WinAnsiEncoding >>",
    ]
    for i, text in enumerate(pages):
        content = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode("cp1252")
        objects.append(
            (
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                " /Resources << /Font << /F1 3 0 R >> >>"
                f" /Contents {5 + 2 * i} 0 R >>"
            ).encode()
        )
        objects.append(
            b"<< /Length %d >>\nstream\n" % len(content)
            + content
            + b"\nendstream"
        )
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n"
    ).encode()
    return bytes(out)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        settings = Settings(
            data_dir=Path(cls.tmp.name), quota_bytes=50 * 1024**2, token=TOKEN
        )
        port = free_port()
        cls.base = f"http://127.0.0.1:{port}"
        config = uvicorn.Config(
            create_app(settings), host="127.0.0.1", port=port, log_level="warning"
        )
        cls.server = uvicorn.Server(config)
        cls.thread = threading.Thread(target=cls.server.run, daemon=True)
        cls.thread.start()
        deadline = time.time() + 10
        while not cls.server.started and time.time() < deadline:
            time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.server.should_exit = True
        cls.thread.join(timeout=5)
        cls.tmp.cleanup()

    def url(self, path: str) -> str:
        return self.base + path

    def upload(self, data: bytes, title="Livre", book_id=None):
        return requests.put(
            self.url(f"/api/books/{book_id or sha(data)}"),
            params={"title": title},
            data=data,
            headers=AUTH,
            timeout=10,
        )

    def wait_text(self, book_id: str) -> dict:
        for _ in range(100):
            books = requests.get(self.url("/api/books"), headers=AUTH, timeout=5).json()
            book = next(b for b in books if b["id"] == book_id)
            if book["text_status"] != "pending":
                return book
            time.sleep(0.05)
        self.fail("extraction du texte trop longue")

    # ------------------------------------------------------------- tests

    def test_health_without_token(self):
        r = requests.get(self.url("/api/health"), timeout=5)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["ok"])

    def test_token_required(self):
        self.assertEqual(requests.get(self.url("/api/books"), timeout=5).status_code, 401)
        bad = {"Authorization": "Bearer mauvais"}
        self.assertEqual(
            requests.get(self.url("/api/books"), headers=bad, timeout=5).status_code, 401
        )

    def test_full_book_cycle(self):
        pdf = make_pdf(["Bonjour réseau", "Deuxième page sur les télécoms"])
        book_id = sha(pdf)

        r = self.upload(pdf, title="Cours R&T")
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual(r.json()["id"], book_id)
        self.assertEqual(self.upload(pdf).status_code, 200)  # doublon

        book = self.wait_text(book_id)
        self.assertEqual(book["text_status"], "done")
        self.assertEqual(book["page_count"], 2)

        hits = requests.get(
            self.url("/api/search"), params={"q": "reseau"}, headers=AUTH, timeout=5
        ).json()
        self.assertEqual([(h["book_id"], h["page"]) for h in hits], [(book_id, 1)])
        self.assertIn("\x01", hits[0]["snippet"])
        self.assertEqual(hits[0]["title"], "Cours R&T")

        hits = requests.get(
            self.url("/api/search"), params={"q": "TELECOM"}, headers=AUTH, timeout=5
        ).json()
        self.assertEqual([h["page"] for h in hits], [2])  # début de mot + accents

        r = requests.get(self.url(f"/api/books/{book_id}/file"), headers=AUTH, timeout=5)
        self.assertEqual(r.content, pdf)

        r = requests.patch(
            self.url(f"/api/books/{book_id}"), json={"title": "Réseaux"},
            headers=AUTH, timeout=5,
        )
        self.assertEqual(r.json()["title"], "Réseaux")

        usage = requests.get(self.url("/api/usage"), headers=AUTH, timeout=5).json()
        self.assertGreaterEqual(usage["used_bytes"], len(pdf))

        r = requests.delete(self.url(f"/api/books/{book_id}"), headers=AUTH, timeout=5)
        self.assertEqual(r.status_code, 204)
        r = requests.get(self.url(f"/api/books/{book_id}/file"), headers=AUTH, timeout=5)
        self.assertEqual(r.status_code, 404)
        hits = requests.get(
            self.url("/api/search"), params={"q": "reseau"}, headers=AUTH, timeout=5
        ).json()
        self.assertEqual(hits, [])

    def test_upload_rejects_bad_files(self):
        pdf = make_pdf(["Test"])
        r = self.upload(pdf, book_id="0" * 64)
        self.assertEqual(r.status_code, 400)
        self.assertIn("empreinte", r.json()["detail"])

        html = b"<html>pas un pdf</html>"
        self.assertEqual(self.upload(html).status_code, 415)
        self.assertEqual(self.upload(pdf, book_id="pas-un-id").status_code, 400)

    def test_scanned_pdf_has_no_text(self):
        pdf = make_pdf([""])
        r = self.upload(pdf, title="Scan")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(self.wait_text(sha(pdf))["text_status"], "none")

    def test_backups(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "app.db"
            con = sqlite3.connect(db_path)
            con.execute("CREATE TABLE t (x)")
            con.commit()
            con.close()
            data = db_path.read_bytes()
        r = requests.put(self.url("/api/backup"), data=data, headers=AUTH, timeout=5)
        self.assertEqual(r.status_code, 201, r.text)
        listing = requests.get(self.url("/api/backups"), headers=AUTH, timeout=5).json()
        self.assertEqual(len(listing), 1)
        r = requests.get(self.url("/api/backup/latest"), headers=AUTH, timeout=5)
        self.assertEqual(r.content, data)
        r = requests.put(self.url("/api/backup"), data=b"nimporte", headers=AUTH, timeout=5)
        self.assertEqual(r.status_code, 400)

    def post_state(self, since=0, changes=(), epoch=None):
        r = requests.post(self.url("/api/state"), headers=AUTH, timeout=5,
                          json={"since": since, "epoch": epoch, "changes": list(changes)})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()

    def test_state_sync_between_two_profiles(self):
        a = self.post_state(changes=[
            {"kind": "progress", "key": "b1", "data": {"page": 50}, "updated_at": 2000},
            {"kind": "bookmark", "key": "b1|12", "data": {}, "updated_at": 2000},
        ])
        since_a = a["seq"]
        # Profil B : une page plus ancienne (perd) et un marque-page supprimé (gagne).
        b = self.post_state(changes=[
            {"kind": "progress", "key": "b1", "data": {"page": 10}, "updated_at": 1000},
            {"kind": "bookmark", "key": "b1|12", "data": {}, "updated_at": 3000,
             "deleted": True},
        ])
        state = {(c["kind"], c["key"]): c for c in b["changes"]}
        self.assertEqual(state[("progress", "b1")]["data"], {"page": 50})
        self.assertTrue(state[("bookmark", "b1|12")]["deleted"])
        # Le profil A ne reçoit que ce qui a changé depuis sa dernière synchro.
        again = self.post_state(since=since_a, epoch=a["epoch"])
        self.assertEqual([(c["kind"], c["key"]) for c in again["changes"]],
                         [("bookmark", "b1|12")])
        # Égalité de date : le serveur garde sa version.
        tie = self.post_state(since=b["seq"], changes=[
            {"kind": "progress", "key": "b1", "data": {"page": 99}, "updated_at": 2000}])
        self.assertEqual(tie["changes"], [])

    def test_reading_log_synced(self):
        log = self.post_state(changes=[{"kind": "readlog", "key": "book:rl1",
                                        "data": {"title": "Livre", "rating": 4},
                                        "updated_at": 4000}])
        mine = [c for c in log["changes"] if c["key"] == "book:rl1"]
        self.assertEqual(mine[0]["data"]["rating"], 4)

    def test_state_epoch_reset_and_validation(self):
        self.post_state(changes=[
            {"kind": "title", "key": "zz", "data": {"title": "T"}, "updated_at": 5}])
        everything = self.post_state(since=10**9, epoch="ancienne-base")
        self.assertTrue(any(c["key"] == "zz" for c in everything["changes"]))
        for bad in ({"kind": "pirate", "key": "x", "updated_at": 1},
                    {"kind": "title", "key": "", "updated_at": 1},
                    {"kind": "title", "key": "x", "updated_at": "hier"}):
            r = requests.post(self.url("/api/state"), headers=AUTH, timeout=5,
                              json={"since": 0, "changes": [bad]})
            self.assertEqual(r.status_code, 400)

    def test_cover(self):
        import shutil as _sh
        pdf = make_pdf(["Couverture"])
        self.upload(pdf, title="Avec couverture")
        book_id = sha(pdf)
        self.wait_text(book_id)
        r = requests.get(self.url(f"/api/books/{book_id}/cover"), headers=AUTH, timeout=5)
        if _sh.which("pdftoppm"):
            self.assertEqual(r.status_code, 200)
            self.assertTrue(r.content.startswith(b"\x89PNG"))
        else:
            self.assertEqual(r.status_code, 404)

    def test_wipe(self):
        pdf = make_pdf(["A effacer"])
        self.upload(pdf, title="A effacer")
        self.wait_text(sha(pdf))
        old = self.post_state(changes=[
            {"kind": "annotation", "key": "w1", "data": {"note": "x"}, "updated_at": 7}])
        r = requests.post(self.url("/api/wipe"), headers=AUTH, timeout=5, json={})
        self.assertEqual(r.status_code, 400)  # sans confirmation : refusé
        r = requests.post(self.url("/api/wipe"), headers=AUTH, timeout=5,
                          json={"confirm": "SUPPRIMER", "books": True})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertNotEqual(r.json()["epoch"], old["epoch"])
        # Un autre profil resté sur l'ancienne base reçoit l'ordre d'effacer,
        # et ses anciennes données ne reviennent pas sur le serveur.
        stale = self.post_state(epoch=old["epoch"], changes=[
            {"kind": "annotation", "key": "w1", "data": {"note": "x"}, "updated_at": 9}])
        self.assertTrue(stale["wipe"])
        fresh = self.post_state(epoch=r.json()["epoch"])
        self.assertEqual(fresh["changes"], [])
        books = requests.get(self.url("/api/books"), headers=AUTH, timeout=5).json()
        self.assertEqual(books, [])
        self.assertEqual(
            requests.get(self.url("/api/backups"), headers=AUTH, timeout=5).json(), [])

    def test_discover_rejects_other_sources(self):
        r = requests.post(
            self.url("/api/discover/import"),
            json={"source": "openlibrary", "id": "/works/OL1W"},
            headers=AUTH, timeout=5,
        )
        self.assertEqual(r.status_code, 400)


class EraseAllTest(unittest.TestCase):
    def test_erase_everything(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "donnees"
            data.mkdir()
            (data / "server.env").write_text("MYPDFS_TOKEN=secret\n")
            stopped = threading.Event()
            settings = Settings(data_dir=data, quota_bytes=10**9, token=TOKEN)
            port = free_port()
            server = uvicorn.Server(uvicorn.Config(
                create_app(settings, shutdown=stopped.set),
                host="127.0.0.1", port=port, log_level="warning"))
            thread = threading.Thread(target=server.run, daemon=True)
            thread.start()
            while not server.started:
                time.sleep(0.05)
            base = f"http://127.0.0.1:{port}"
            try:
                pdf = make_pdf(["Titre secret"])
                requests.put(f"{base}/api/books/{sha(pdf)}", params={"title": "Secret"},
                             data=pdf, headers=AUTH, timeout=5)
                r = requests.post(f"{base}/api/erase-all", headers=AUTH, timeout=5,
                                  json={"confirm": "SUPPRIMER"})
                self.assertEqual(r.status_code, 400)  # mauvaise confirmation
                r = requests.post(f"{base}/api/erase-all", headers=AUTH, timeout=10,
                                  json={"confirm": "TOUT SUPPRIMER"})
                self.assertEqual(r.status_code, 200, r.text)
                self.assertTrue(stopped.wait(5))
                self.assertEqual(list(data.rglob("*")), [])  # plus rien, même la config
                r = requests.get(f"{base}/api/books", headers=AUTH, timeout=5)
                self.assertEqual(r.status_code, 410)
            finally:
                server.should_exit = True
                thread.join(timeout=5)


class StoreTest(unittest.TestCase):
    def test_quota(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp), quota_bytes=100)
            incoming = store.incoming()
            with self.assertRaises(QuotaExceeded):
                incoming.write(b"x" * 200)
            incoming.discard()
            self.assertEqual(list((Path(tmp) / "tmp").iterdir()), [])

    def test_migrations(self):
        import store as store_module
        with tempfile.TemporaryDirectory() as tmp:
            first = Store(Path(tmp), quota_bytes=10)
            self.assertEqual(first.schema_version, len(store_module.MIGRATIONS))
            epoch = first.epoch
            again = Store(Path(tmp), quota_bytes=10)  # réouverture sans effet
            self.assertEqual(again.epoch, epoch)
            mode = again._db.execute("PRAGMA journal_mode").fetchone()[0]
            self.assertEqual(mode.lower(), "wal")
            again._db.execute(
                "UPDATE meta SET value = '999' WHERE key = 'schema_version'")
            again._db.commit()
            with self.assertRaises(RuntimeError):
                Store(Path(tmp), quota_bytes=10)

    def test_backups_keep_seven(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp), quota_bytes=10**9, keep_backups=7)
            for day in range(1, 10):
                (store.backups_dir / f"my_pdfs-2026-01-0{day}.db").write_bytes(b"x")
            incoming = store.incoming(limit_bytes=10**6)
            incoming.write(b"SQLite format 3\x00" + b"\x00" * 100)
            store.save_backup(incoming)
            names = [b["name"] for b in store.list_backups()]
            self.assertEqual(len(names), 7)
            self.assertNotIn("my_pdfs-2026-01-01.db", names)


# ------------------------------------------------------- sources en ligne


class FakeResponse:
    def __init__(self, payload=None, content=b"", status=200):
        self.payload = payload
        self.content = content
        self.status_code = status

    def json(self):
        return self.payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(str(self.status_code))

    def iter_content(self, chunk_size=1):
        yield self.content

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeSession:
    def __init__(self, routes: dict):
        self.routes = routes
        self.calls = []

    def get(self, url, params=None, timeout=None, stream=False):
        self.calls.append((url, params))
        return self.routes[url]


class DiscoverTest(unittest.TestCase):
    def test_internet_archive_excludes_lending(self):
        session = FakeSession(
            {
                "https://archive.org/advancedsearch.php": FakeResponse(
                    {"response": {"docs": [
                        {"identifier": "lesmiserables01", "title": "Les Misérables",
                         "creator": ["Victor Hugo"], "year": "1862"},
                    ]}}
                )
            }
        )
        results = discover.search_internet_archive(session, "Les Misérables !")
        self.assertEqual(results[0]["id"], "lesmiserables01")
        self.assertEqual(results[0]["status"], "download")
        query = session.calls[0][1]["q"]
        self.assertIn("NOT collection:(inlibrary OR printdisabled OR lendinglibrary)", query)

    def test_open_library_statuses(self):
        session = FakeSession(
            {
                "https://openlibrary.org/search.json": FakeResponse(
                    {"docs": [
                        {"key": "/works/OL1W", "title": "Libre", "ebook_access": "public",
                         "ia": ["libre01"], "author_name": ["A"]},
                        {"key": "/works/OL2W", "title": "Empruntable",
                         "ebook_access": "borrowable"},
                        {"key": "/works/OL3W", "title": "Réservé",
                         "ebook_access": "printdisabled"},
                        {"key": "/works/OL4W", "title": "Rien", "ebook_access": "no_ebook"},
                    ]}
                )
            }
        )
        results = discover.search_open_library(session, "test")
        self.assertEqual(
            [(r["source"], r["id"], r["status"]) for r in results],
            [("ia", "libre01", "download"), ("openlibrary", "/works/OL2W", "borrow")],
        )

    def test_gallica_xml(self):
        xml = b"""<?xml version="1.0"?>
<srw:searchRetrieveResponse xmlns:srw="http://www.loc.gov/zing/srw/"
  xmlns:dc="http://purl.org/dc/elements/1.1/">
 <srw:records><srw:record><srw:recordData><oai_dc:dc
   xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/">
  <dc:title>Le Rouge et le Noir</dc:title>
  <dc:creator>Stendhal</dc:creator>
  <dc:date>1831</dc:date>
  <dc:identifier>https://gallica.bnf.fr/ark:/12148/bpt6k1234</dc:identifier>
 </oai_dc:dc></srw:recordData></srw:record></srw:records>
</srw:searchRetrieveResponse>"""
        session = FakeSession({"https://gallica.bnf.fr/SRU": FakeResponse(content=xml)})
        results = discover.search_gallica(session, "rouge noir")
        self.assertEqual(results[0]["title"], "Le Rouge et le Noir")
        self.assertEqual(results[0]["status"], "link")
        self.assertTrue(results[0]["url"].startswith("https://gallica.bnf.fr/ark:"))

    def test_search_all_survives_a_broken_source(self):
        def ok(session, q):
            return [{"source": "gallica", "id": "x", "status": "link"},
                    {"source": "ia", "id": "y", "status": "download"}]

        def broken(session, q):
            raise requests.ConnectionError("boom")

        out = discover.search_all("q", session_factory=lambda: None,
                                  sources={"A": ok, "B": broken})
        self.assertEqual([r["id"] for r in out["results"]], ["y", "x"])
        self.assertEqual(out["errors"], ["B : ConnectionError"])

    def test_ia_pdf_choice_and_restrictions(self):
        meta_url = "https://archive.org/metadata/livre01"
        files = [
            {"name": "livre01.pdf", "format": "Image Container PDF", "size": "9000"},
            {"name": "livre01_text.pdf", "format": "Text PDF", "size": "5000"},
            {"name": "secret.pdf", "format": "Text PDF", "size": "1", "private": "true"},
        ]
        session = FakeSession({meta_url: FakeResponse(
            {"metadata": {"title": "Livre", "collection": ["americana"]}, "files": files}
        )})
        info = discover.internet_archive_pdf(session, "livre01")
        self.assertTrue(info["url"].endswith("/livre01_text.pdf"))
        self.assertEqual(info["title"], "Livre")

        session = FakeSession({meta_url: FakeResponse(
            {"metadata": {"title": "Livre", "collection": ["inlibrary"]}, "files": files}
        )})
        with self.assertRaises(discover.SourceError):
            discover.internet_archive_pdf(session, "livre01")

        with self.assertRaises(discover.SourceError):
            discover.internet_archive_pdf(FakeSession({}), "../etc/passwd")


if __name__ == "__main__":
    unittest.main()
