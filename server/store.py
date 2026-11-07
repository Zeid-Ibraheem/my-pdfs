"""Stockage des PDF, catalogue SQLite, texte extrait et sauvegardes.

Organisation du dossier de données :
    books/<empreinte SHA-256>.pdf   les livres
    catalog.db                      catalogue + index de recherche plein texte
    covers/<empreinte>.png          couverture (page 1), créée avec pdftoppm
    backups/my_pdfs-AAAA-MM-JJ.db   sauvegardes de la base de l'appli (1 par jour)
    tmp/                            fichiers en cours de réception
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid
from datetime import date
from pathlib import Path

from pypdf import PdfReader

log = logging.getLogger("my_pdfs.store")

SCHEMA = """
CREATE TABLE IF NOT EXISTS books (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    size_bytes  INTEGER NOT NULL,
    page_count  INTEGER,
    added_at    INTEGER NOT NULL,
    source      TEXT,
    text_status TEXT NOT NULL DEFAULT 'pending'
);
CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(
    book_id UNINDEXED,
    page UNINDEXED,
    text,
    tokenize = 'unicode61 remove_diacritics 2'
);
-- État synchronisé entre les appareils / profils : page en cours,
-- marque-pages, notes, catégories… Un élément = (type, clé). La version la
-- plus récente (updated_at) gagne. seq numérote les changements reçus.
CREATE TABLE IF NOT EXISTS state (
    kind       TEXT NOT NULL,
    key        TEXT NOT NULL,
    data       TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted    INTEGER NOT NULL DEFAULT 0,
    seq        INTEGER NOT NULL,
    PRIMARY KEY (kind, key)
);
CREATE INDEX IF NOT EXISTS state_by_seq ON state (seq);
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

STATE_KINDS = {"progress", "title", "bookmark", "category", "bookcat", "annotation", "readlog"}
STATE_PAGE = 2000
MAX_ITEM_BYTES = 200_000

SQLITE_HEADER = b"SQLite format 3\x00"


class StoreError(Exception):
    """Erreur prévue, renvoyée telle quelle à l'appli avec un code HTTP."""

    status = 400


class QuotaExceeded(StoreError):
    status = 413


class NotPdf(StoreError):
    status = 415


class HashMismatch(StoreError):
    status = 400


class NotFound(StoreError):
    status = 404


class IncomingFile:
    """Fichier en cours de réception : écrit sur disque et haché au fil de l'eau."""

    def __init__(self, tmp_dir: Path, limit_bytes: int):
        self.path = tmp_dir / f"in-{uuid.uuid4().hex}.part"
        self._file = open(self.path, "wb")
        self._hash = hashlib.sha256()
        self.size = 0
        self.limit = limit_bytes
        self.head = b""

    def write(self, chunk: bytes) -> None:
        self.size += len(chunk)
        if self.size > self.limit:
            raise QuotaExceeded("Quota de stockage dépassé")
        if len(self.head) < 1024:
            self.head += chunk[: 1024 - len(self.head)]
        self._hash.update(chunk)
        self._file.write(chunk)

    def finish(self) -> str:
        """Ferme le fichier et renvoie son empreinte SHA-256 (hexadécimal)."""
        if not self._file.closed:
            self._file.close()
        return self._hash.hexdigest()

    def discard(self) -> None:
        if not self._file.closed:
            self._file.close()
        self.path.unlink(missing_ok=True)


class Store:
    def __init__(self, data_dir: Path, quota_bytes: int, keep_backups: int = 7):
        self.data_dir = data_dir
        self.books_dir = data_dir / "books"
        self.tmp_dir = data_dir / "tmp"
        self.backups_dir = data_dir / "backups"
        self.covers_dir = data_dir / "covers"
        for folder in (self.books_dir, self.tmp_dir, self.backups_dir, self.covers_dir):
            folder.mkdir(parents=True, exist_ok=True)
        for leftover in self.tmp_dir.glob("*.part"):
            leftover.unlink(missing_ok=True)

        self.quota_bytes = quota_bytes
        self.keep_backups = keep_backups
        self._lock = threading.RLock()
        self._db = sqlite3.connect(data_dir / "catalog.db", check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.executescript(SCHEMA)
        # Identifiant de cette base d'état : s'il change (base recréée),
        # l'appli renvoie tout ce qu'elle a au lieu de croire être à jour.
        if self._db.execute("SELECT 1 FROM meta WHERE key = 'epoch'").fetchone() is None:
            self._db.execute(
                "INSERT INTO meta (key, value) VALUES ('epoch', ?)", (uuid.uuid4().hex,)
            )
        self._db.commit()
        self.epoch = self._db.execute(
            "SELECT value FROM meta WHERE key = 'epoch'"
        ).fetchone()[0]

    # ------------------------------------------------------------ catalogue

    def _row(self, row: sqlite3.Row | None) -> dict | None:
        return dict(row) if row is not None else None

    def list_books(self) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM books ORDER BY added_at DESC"
            ).fetchall()
        return [dict(r) for r in rows]

    def get_book(self, book_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM books WHERE id = ?", (book_id,)
            ).fetchone()
        return self._row(row)

    def path_of(self, book_id: str) -> Path:
        return self.books_dir / f"{book_id}.pdf"

    def used_bytes(self) -> int:
        with self._lock:
            (used,) = self._db.execute(
                "SELECT COALESCE(SUM(size_bytes), 0) FROM books"
            ).fetchone()
        return int(used)

    def remaining_bytes(self) -> int:
        return max(0, self.quota_bytes - self.used_bytes())

    def usage(self) -> dict:
        with self._lock:
            (count,) = self._db.execute("SELECT COUNT(*) FROM books").fetchone()
            (pending,) = self._db.execute(
                "SELECT COUNT(*) FROM books WHERE text_status = 'pending'"
            ).fetchone()
        return {
            "used_bytes": self.used_bytes(),
            "quota_bytes": self.quota_bytes,
            "books": count,
            "text_pending": pending,
            "disk_free_bytes": shutil.disk_usage(self.data_dir).free,
        }

    def incoming(self, limit_bytes: int | None = None) -> IncomingFile:
        limit = self.remaining_bytes() if limit_bytes is None else limit_bytes
        return IncomingFile(self.tmp_dir, limit)

    def commit(
        self,
        incoming: IncomingFile,
        *,
        title: str,
        source: str,
        expected_id: str | None = None,
    ) -> tuple[dict, bool]:
        """Range le fichier reçu. Renvoie (livre, créé ?)."""
        digest = incoming.finish()
        if expected_id is not None and digest != expected_id:
            incoming.discard()
            raise HashMismatch(
                "Le fichier reçu ne correspond pas à son empreinte "
                "(transfert interrompu ?). Réessaie."
            )
        if b"%PDF" not in incoming.head:
            incoming.discard()
            raise NotPdf("Ce fichier n'est pas un PDF")

        existing = self.get_book(digest)
        if existing is not None:
            incoming.discard()
            return existing, False

        os.replace(incoming.path, self.path_of(digest))
        book = {
            "id": digest,
            "title": (title or "Sans titre").strip()[:300] or "Sans titre",
            "size_bytes": incoming.size,
            "page_count": None,
            "added_at": int(time.time() * 1000),
            "source": source,
            "text_status": "pending",
        }
        with self._lock:
            self._db.execute(
                "INSERT INTO books (id, title, size_bytes, page_count, added_at,"
                " source, text_status) VALUES (:id, :title, :size_bytes,"
                " :page_count, :added_at, :source, :text_status)",
                book,
            )
            self._db.commit()
        return book, True

    def rename(self, book_id: str, title: str) -> dict:
        title = title.strip()[:300]
        if not title:
            raise StoreError("Titre vide")
        with self._lock:
            cursor = self._db.execute(
                "UPDATE books SET title = ? WHERE id = ?", (title, book_id)
            )
            self._db.commit()
        if cursor.rowcount == 0:
            raise NotFound("Livre introuvable sur le serveur")
        return self.get_book(book_id)  # type: ignore[return-value]

    def delete(self, book_id: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM pages WHERE book_id = ?", (book_id,))
            cursor = self._db.execute("DELETE FROM books WHERE id = ?", (book_id,))
            self._db.commit()
        self.path_of(book_id).unlink(missing_ok=True)
        self.cover_of(book_id).unlink(missing_ok=True)
        if cursor.rowcount == 0:
            raise NotFound("Livre introuvable sur le serveur")

    # ------------------------------------------------- texte et recherche

    def extract_text(self, book_id: str) -> None:
        """Extrait le texte de chaque page et l'ajoute à l'index de recherche.

        Pas d'OCR : une page scannée (image seule) ne donne pas de texte.
        """
        path = self.path_of(book_id)
        if not path.exists():
            return
        started = time.monotonic()
        try:
            reader = PdfReader(path)
            if reader.is_encrypted:
                reader.decrypt("")
            rows = []
            for number, page in enumerate(reader.pages, start=1):
                try:
                    text = (page.extract_text() or "").strip()
                except Exception:  # page abîmée : on passe à la suivante
                    text = ""
                if text:
                    rows.append((book_id, number, text))
            page_count = len(reader.pages)
            status = "done" if rows else "none"
        except Exception:
            log.exception("Extraction du texte impossible pour %s", book_id)
            rows, page_count, status = [], None, "error"

        with self._lock:
            self._db.execute("DELETE FROM pages WHERE book_id = ?", (book_id,))
            self._db.executemany(
                "INSERT INTO pages (book_id, page, text) VALUES (?, ?, ?)", rows
            )
            self._db.execute(
                "UPDATE books SET page_count = COALESCE(?, page_count),"
                " text_status = ? WHERE id = ?",
                (page_count, status, book_id),
            )
            self._db.commit()
        log.info(
            "Texte de %s : %s pages avec texte, statut %s (%.1f s)",
            book_id[:12], len(rows), status, time.monotonic() - started,
        )

    def process(self, book_id: str) -> None:
        """Traitements après réception d'un livre : couverture puis texte."""
        self.make_cover(book_id)
        self.extract_text(book_id)

    def extract_pending(self) -> None:
        """Au démarrage : termine les traitements interrompus."""
        with self._lock:
            pending = {
                r[0]
                for r in self._db.execute(
                    "SELECT id FROM books WHERE text_status = 'pending'"
                ).fetchall()
            }
            all_ids = [r[0] for r in self._db.execute("SELECT id FROM books").fetchall()]
        for book_id in all_ids:
            if not self.cover_of(book_id).exists():
                self.make_cover(book_id)
            if book_id in pending:
                self.extract_text(book_id)

    # ---------------------------------------------------------- couvertures

    def cover_of(self, book_id: str) -> Path:
        return self.covers_dir / f"{book_id}.png"

    def make_cover(self, book_id: str) -> bool:
        """Image de la page 1 (300 px de large) avec pdftoppm (paquet
        poppler-utils). Sans pdftoppm, l'appli affiche une icône à la place."""
        source = self.path_of(book_id)
        if not source.exists() or shutil.which("pdftoppm") is None:
            return False
        prefix = self.tmp_dir / f"cover-{uuid.uuid4().hex}"
        produced = prefix.with_suffix(".png")
        try:
            subprocess.run(
                ["pdftoppm", "-png", "-f", "1", "-l", "1", "-scale-to-x", "300",
                 "-scale-to-y", "-1", "-singlefile", str(source), str(prefix)],
                check=True, timeout=120, capture_output=True,
            )
            os.replace(produced, self.cover_of(book_id))
            return True
        except (subprocess.SubprocessError, OSError):
            log.warning("Couverture impossible pour %s", book_id[:12])
            produced.unlink(missing_ok=True)
            return False

    def search(self, query: str, limit: int = 50) -> list[dict]:
        """Recherche plein texte, sans tenir compte des accents ni des majuscules.

        Chaque mot est cherché comme début de mot (« reseau » trouve « réseaux »).
        """
        words = re.findall(r"\w+", query)
        if not words:
            return []
        match = " ".join(f'"{w}"*' for w in words[:12])
        with self._lock:
            rows = self._db.execute(
                "SELECT pages.book_id AS book_id, pages.page AS page,"
                " snippet(pages, 2, char(1), char(2), '…', 14) AS snippet,"
                " books.title AS title"
                " FROM pages JOIN books ON books.id = pages.book_id"
                " WHERE pages MATCH ? ORDER BY rank LIMIT ?",
                (match, limit),
            ).fetchall()
        return [dict(r) for r in rows]

    # ------------------------------------------------- état synchronisé

    def sync_state(self, since: int, changes: list) -> dict:
        """Reçoit les changements d'un appareil, garde pour chaque élément la
        version la plus récente, et renvoie ce qui a changé depuis [since]."""
        if not isinstance(changes, list):
            raise StoreError("changes doit être une liste")
        with self._lock:
            (seq,) = self._db.execute("SELECT COALESCE(MAX(seq), 0) FROM state").fetchone()
            for change in changes[:5000]:
                item = self._valid_item(change)
                current = self._db.execute(
                    "SELECT updated_at FROM state WHERE kind = ? AND key = ?",
                    (item["kind"], item["key"]),
                ).fetchone()
                if current is not None and current[0] >= item["updated_at"]:
                    continue  # le serveur a déjà une version aussi récente
                seq += 1
                self._db.execute(
                    "INSERT OR REPLACE INTO state (kind, key, data, updated_at, deleted, seq)"
                    " VALUES (?, ?, ?, ?, ?, ?)",
                    (item["kind"], item["key"], item["data"], item["updated_at"],
                     1 if item["deleted"] else 0, seq),
                )
            self._db.commit()
            rows = self._db.execute(
                "SELECT kind, key, data, updated_at, deleted, seq FROM state"
                " WHERE seq > ? ORDER BY seq LIMIT ?",
                (max(0, int(since)), STATE_PAGE + 1),
            ).fetchall()
        more = len(rows) > STATE_PAGE
        rows = rows[:STATE_PAGE]
        return {
            "epoch": self.epoch,
            "seq": rows[-1]["seq"] if rows else max(0, int(since)),
            "more": more,
            "changes": [
                {
                    "kind": r["kind"],
                    "key": r["key"],
                    "data": json.loads(r["data"]),
                    "updated_at": r["updated_at"],
                    "deleted": bool(r["deleted"]),
                }
                for r in rows
            ],
        }

    @staticmethod
    def _valid_item(change) -> dict:
        if not isinstance(change, dict):
            raise StoreError("Élément de synchronisation invalide")
        kind, key = change.get("kind"), change.get("key")
        updated_at, data = change.get("updated_at"), change.get("data", {})
        if kind not in STATE_KINDS:
            raise StoreError(f"Type inconnu : {kind!r}")
        if not isinstance(key, str) or not 0 < len(key) <= 300:
            raise StoreError("Clé invalide")
        if not isinstance(updated_at, int) or isinstance(updated_at, bool) or updated_at < 0:
            raise StoreError("Date invalide")
        if not isinstance(data, dict):
            raise StoreError("Données invalides")
        encoded = json.dumps(data, ensure_ascii=False)
        if len(encoded.encode()) > MAX_ITEM_BYTES:
            raise StoreError("Élément trop gros")
        return {
            "kind": kind,
            "key": key,
            "data": encoded,
            "updated_at": updated_at,
            "deleted": bool(change.get("deleted", False)),
        }

    # ------------------------------------------------- effacement total

    def wiped_epochs(self) -> set[str]:
        with self._lock:
            row = self._db.execute("SELECT value FROM meta WHERE key = 'wiped'").fetchone()
        return set(json.loads(row[0])) if row else set()

    def wipe(self, delete_books: bool) -> dict:
        """Efface définitivement l'état synchronisé (pages, notes, surlignages,
        marque-pages, catégories) et toutes les sauvegardes ; avec
        [delete_books], aussi tous les livres, leur texte et leurs couvertures.

        L'ancien identifiant de base est noté « effacé » : un autre profil qui
        se synchronise ensuite efface ses propres données au lieu de les
        renvoyer (sinon elles reviendraient)."""
        deleted_books = 0
        with self._lock:
            wiped = self.wiped_epochs() | {self.epoch}
            self.epoch = uuid.uuid4().hex
            self._db.execute("DELETE FROM state")
            self._db.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('epoch', ?)", (self.epoch,)
            )
            self._db.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('wiped', ?)",
                (json.dumps(sorted(wiped)),),
            )
            if delete_books:
                ids = [r[0] for r in self._db.execute("SELECT id FROM books").fetchall()]
                self._db.execute("DELETE FROM pages")
                self._db.execute("DELETE FROM books")
                deleted_books = len(ids)
            self._db.commit()
        for backup in self.backups_dir.glob("*.db"):
            backup.unlink(missing_ok=True)
        if delete_books:
            for folder in (self.books_dir, self.covers_dir):
                for file in folder.iterdir():
                    if file.is_file():
                        file.unlink(missing_ok=True)
        log.warning("Effacement total (livres : %s)", "oui" if delete_books else "non")
        return {"epoch": self.epoch, "deleted_books": deleted_books}

    # ----------------------------------------------------------- sauvegardes

    def save_backup(self, incoming: IncomingFile) -> dict:
        incoming.finish()
        if not incoming.head.startswith(SQLITE_HEADER):
            incoming.discard()
            raise StoreError("Ce fichier n'est pas une base SQLite")
        dest = self.backups_dir / f"my_pdfs-{date.today().isoformat()}.db"
        os.replace(incoming.path, dest)
        backups = sorted(self.backups_dir.glob("my_pdfs-*.db"), reverse=True)
        for old in backups[self.keep_backups :]:
            old.unlink(missing_ok=True)
        return self._backup_info(dest)

    def _backup_info(self, path: Path) -> dict:
        stat = path.stat()
        return {
            "name": path.name,
            "size_bytes": stat.st_size,
            "created_at": int(stat.st_mtime * 1000),
        }

    def list_backups(self) -> list[dict]:
        files = sorted(self.backups_dir.glob("my_pdfs-*.db"), reverse=True)
        return [self._backup_info(f) for f in files]

    def latest_backup(self) -> Path:
        files = sorted(self.backups_dir.glob("my_pdfs-*.db"), reverse=True)
        if not files:
            raise NotFound("Aucune sauvegarde sur le serveur")
        return files[0]
