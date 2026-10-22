"""Serveur My PDFs : API HTTP utilisée par l'appli Android.

Il n'écoute que sur l'adresse Tailscale de la machine (voir install.sh) :
il n'est donc jamais visible depuis Internet. Chaque requête doit en plus
porter le jeton secret (en-tête « Authorization: Bearer <jeton> »).

Lancement : uvicorn --factory app:create_app --host <ip> --port 8765
"""

from __future__ import annotations

import contextlib
import hmac
import logging
import re
import threading

from starlette.applications import Starlette
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response
from starlette.routing import Route

import discover
from config import Settings, load_settings
from store import NotFound, QuotaExceeded, Store, StoreError

VERSION = "0.3.0"
BOOK_ID = re.compile(r"[0-9a-f]{64}")
MAX_BACKUP_BYTES = 500 * 1024 * 1024

log = logging.getLogger("my_pdfs")


def error(status: int, message: str) -> JSONResponse:
    return JSONResponse({"detail": message}, status_code=status)


def create_app(settings: Settings | None = None) -> Starlette:
    settings = settings or load_settings()
    store = Store(settings.data_dir, settings.quota_bytes, settings.keep_backups)
    expected_auth = f"Bearer {settings.token}".encode()

    def protected(handler):
        """Vérifie le jeton et transforme les erreurs prévues en réponses JSON."""

        async def wrapper(request: Request) -> Response:
            given = request.headers.get("authorization", "").encode()
            if not hmac.compare_digest(given, expected_auth):
                return error(401, "Jeton invalide")
            try:
                return await handler(request)
            except StoreError as exc:
                return error(exc.status, str(exc))
            except discover.SourceError as exc:
                return error(422, str(exc))

        return wrapper

    def book_id_of(request: Request) -> str:
        book_id = request.path_params["book_id"]
        if not BOOK_ID.fullmatch(book_id):
            raise StoreError("Identifiant de livre invalide")
        return book_id

    # ------------------------------------------------------------- routes

    async def health(request: Request) -> Response:
        return JSONResponse({"ok": True, "version": VERSION})

    @protected
    async def usage(request: Request) -> Response:
        return JSONResponse(await run_in_threadpool(store.usage))

    @protected
    async def list_books(request: Request) -> Response:
        return JSONResponse(await run_in_threadpool(store.list_books))

    @protected
    async def upload_book(request: Request) -> Response:
        book_id = book_id_of(request)
        title = request.query_params.get("title", "Sans titre")
        existing = store.get_book(book_id)
        if existing is not None:
            async for _ in request.stream():  # on lit et on jette : déjà là
                pass
            return JSONResponse(existing)

        length = request.headers.get("content-length", "")
        if length.isdigit() and int(length) > store.remaining_bytes():
            raise QuotaExceeded("Quota de stockage dépassé")

        incoming = store.incoming()
        try:
            async for chunk in request.stream():
                incoming.write(chunk)
            book, created = store.commit(
                incoming, title=title, source="upload", expected_id=book_id
            )
        except Exception:
            incoming.discard()
            raise
        task = BackgroundTask(store.extract_text, book_id) if created else None
        return JSONResponse(book, status_code=201 if created else 200, background=task)

    @protected
    async def download_book(request: Request) -> Response:
        book_id = book_id_of(request)
        book = store.get_book(book_id)
        path = store.path_of(book_id)
        if book is None or not path.exists():
            raise NotFound("Livre introuvable sur le serveur")
        return FileResponse(path, media_type="application/pdf")

    @protected
    async def update_book(request: Request) -> Response:
        book_id = book_id_of(request)
        body = await request.json()
        title = str(body.get("title", "")) if isinstance(body, dict) else ""
        return JSONResponse(store.rename(book_id, title))

    @protected
    async def delete_book(request: Request) -> Response:
        book_id = book_id_of(request)
        await run_in_threadpool(store.delete, book_id)
        return Response(status_code=204)

    @protected
    async def search(request: Request) -> Response:
        query = request.query_params.get("q", "")[:200]
        hits = await run_in_threadpool(store.search, query)
        return JSONResponse(hits)

    @protected
    async def list_backups(request: Request) -> Response:
        return JSONResponse(store.list_backups())

    @protected
    async def upload_backup(request: Request) -> Response:
        incoming = store.incoming(limit_bytes=MAX_BACKUP_BYTES)
        try:
            async for chunk in request.stream():
                incoming.write(chunk)
            info = store.save_backup(incoming)
        except Exception:
            incoming.discard()
            raise
        return JSONResponse(info, status_code=201)

    @protected
    async def latest_backup(request: Request) -> Response:
        path = store.latest_backup()
        return FileResponse(path, media_type="application/octet-stream")

    @protected
    async def discover_search(request: Request) -> Response:
        query = request.query_params.get("q", "").strip()[:200]
        if not query:
            return JSONResponse({"results": [], "errors": []})
        return JSONResponse(await run_in_threadpool(discover.search_all, query))

    def _import_from_internet_archive(identifier: str, title: str | None) -> tuple:
        session = discover.new_session()
        info = discover.internet_archive_pdf(session, identifier)
        if info["size"] > store.remaining_bytes():
            raise QuotaExceeded("Quota de stockage dépassé")
        incoming = store.incoming()
        try:
            for chunk in discover.stream_file(session, info["url"]):
                incoming.write(chunk)
            return store.commit(
                incoming,
                title=title or info["title"],
                source=f"ia:{identifier}",
            )
        except Exception:
            incoming.discard()
            raise

    @protected
    async def discover_import(request: Request) -> Response:
        body = await request.json()
        if not isinstance(body, dict) or body.get("source") != "ia":
            raise StoreError(
                "Seuls les livres d'Internet Archive en accès libre "
                "peuvent être ajoutés automatiquement"
            )
        identifier = str(body.get("id", ""))
        title = body.get("title")
        try:
            book, created = await run_in_threadpool(
                _import_from_internet_archive, identifier, title
            )
        except (StoreError, discover.SourceError):
            raise
        except Exception as exc:
            log.exception("Import Internet Archive impossible : %s", identifier)
            raise discover.SourceError(
                f"Téléchargement impossible depuis Internet Archive ({type(exc).__name__})"
            ) from exc
        task = BackgroundTask(store.extract_text, book["id"]) if created else None
        return JSONResponse(book, status_code=201 if created else 200, background=task)

    @contextlib.asynccontextmanager
    async def lifespan(app: Starlette):
        # Termine l'extraction de texte interrompue (redémarrage, coupure…).
        threading.Thread(target=store.extract_pending, daemon=True).start()
        yield

    routes = [
        Route("/api/health", health, methods=["GET"]),
        Route("/api/usage", usage, methods=["GET"]),
        Route("/api/books", list_books, methods=["GET"]),
        Route("/api/books/{book_id}", upload_book, methods=["PUT"]),
        Route("/api/books/{book_id}", update_book, methods=["PATCH"]),
        Route("/api/books/{book_id}", delete_book, methods=["DELETE"]),
        Route("/api/books/{book_id}/file", download_book, methods=["GET"]),
        Route("/api/search", search, methods=["GET"]),
        Route("/api/backups", list_backups, methods=["GET"]),
        Route("/api/backup", upload_backup, methods=["PUT"]),
        Route("/api/backup/latest", latest_backup, methods=["GET"]),
        Route("/api/discover", discover_search, methods=["GET"]),
        Route("/api/discover/import", discover_import, methods=["POST"]),
    ]
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    app = Starlette(routes=routes, lifespan=lifespan)
    app.state.store = store
    return app
