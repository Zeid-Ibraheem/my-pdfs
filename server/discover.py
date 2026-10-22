"""Recherche de livres libres en ligne.

Sources, toutes avec une API publique gratuite et sans compte :
- Internet Archive : livres scannés téléchargeables (domaine public ou
  licence libre). Les livres « empruntables » sont exclus : ils sont
  protégés contre la copie et ne sont jamais téléchargés.
- Open Library : catalogue d'Internet Archive. Indique si un livre est en
  accès libre (importable) ou seulement empruntable (lien vers le site).
- Gallica (BnF) : affichée comme lien vers le site, sans import automatique.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from typing import Callable, Iterator
from urllib.parse import quote

import requests

USER_AGENT = "my-pdfs/0.3 (bibliotheque personnelle)"
TIMEOUT = 15
RESTRICTED_COLLECTIONS = ("inlibrary", "printdisabled", "lendinglibrary")
IA_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,119}")

SRW = "{http://www.loc.gov/zing/srw/}"
DC = "{http://purl.org/dc/elements/1.1/}"

STATUS_ORDER = {"download": 0, "borrow": 1, "link": 2}


class SourceError(Exception):
    """Erreur lisible, renvoyée à l'appli."""


def new_session() -> requests.Session:
    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT
    return session


def _words(query: str) -> str:
    return " ".join(re.findall(r"\w+", query))


def _text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, list):
        return ", ".join(str(v) for v in value[:3])
    return str(value)


def search_internet_archive(session: requests.Session, query: str) -> list[dict]:
    words = _words(query)
    if not words:
        return []
    restricted = " OR ".join(RESTRICTED_COLLECTIONS)
    response = session.get(
        "https://archive.org/advancedsearch.php",
        params={
            "q": f"({words}) AND mediatype:texts AND NOT collection:({restricted})",
            "fl[]": ["identifier", "title", "creator", "year"],
            "rows": 15,
            "output": "json",
        },
        timeout=TIMEOUT,
    )
    response.raise_for_status()
    docs = response.json().get("response", {}).get("docs", [])
    results = []
    for doc in docs:
        identifier = doc.get("identifier")
        if not identifier:
            continue
        results.append(
            {
                "source": "ia",
                "id": identifier,
                "title": _text(doc.get("title")) or identifier,
                "authors": _text(doc.get("creator")),
                "year": _text(doc.get("year")),
                "status": "download",
                "url": f"https://archive.org/details/{identifier}",
                "origin": "Internet Archive",
            }
        )
    return results


def search_open_library(session: requests.Session, query: str) -> list[dict]:
    words = _words(query)
    if not words:
        return []
    response = session.get(
        "https://openlibrary.org/search.json",
        params={
            "q": words,
            "fields": "key,title,author_name,first_publish_year,ebook_access,ia",
            "limit": 15,
        },
        timeout=TIMEOUT,
    )
    response.raise_for_status()
    results = []
    for doc in response.json().get("docs", []):
        access = doc.get("ebook_access")
        scans = doc.get("ia") or []
        key = doc.get("key", "")
        common = {
            "title": _text(doc.get("title")) or "Sans titre",
            "authors": _text(doc.get("author_name")),
            "year": _text(doc.get("first_publish_year")),
            "origin": "Open Library",
        }
        if access == "public" and scans:
            results.append(
                {
                    **common,
                    "source": "ia",
                    "id": scans[0],
                    "status": "download",
                    "url": f"https://openlibrary.org{key}",
                }
            )
        elif access == "borrowable":
            results.append(
                {
                    **common,
                    "source": "openlibrary",
                    "id": key,
                    "status": "borrow",
                    "url": f"https://openlibrary.org{key}",
                }
            )
    return results


def search_gallica(session: requests.Session, query: str) -> list[dict]:
    words = _words(query)
    if not words:
        return []
    response = session.get(
        "https://gallica.bnf.fr/SRU",
        params={
            "operation": "searchRetrieve",
            "version": "1.2",
            "query": f'gallica all "{words}" and dc.type all "monographie"',
            "maximumRecords": 10,
        },
        timeout=TIMEOUT,
    )
    response.raise_for_status()
    root = ET.fromstring(response.content)
    results = []
    for record in root.iter(f"{SRW}record"):
        links = [
            e.text.strip()
            for e in record.iter(f"{DC}identifier")
            if e.text and "gallica.bnf.fr/ark:" in e.text
        ]
        if not links:
            continue
        titles = [e.text for e in record.iter(f"{DC}title") if e.text]
        creators = [e.text for e in record.iter(f"{DC}creator") if e.text]
        dates = [e.text for e in record.iter(f"{DC}date") if e.text]
        results.append(
            {
                "source": "gallica",
                "id": links[0],
                "title": titles[0] if titles else "Sans titre",
                "authors": _text(creators),
                "year": dates[0] if dates else "",
                "status": "link",
                "url": links[0],
                "origin": "Gallica",
            }
        )
    return results


SOURCES: dict[str, Callable[[requests.Session, str], list[dict]]] = {
    "Internet Archive": search_internet_archive,
    "Open Library": search_open_library,
    "Gallica": search_gallica,
}


def search_all(
    query: str,
    session_factory: Callable[[], requests.Session] = new_session,
    sources: dict | None = None,
) -> dict:
    """Interroge toutes les sources en parallèle. Une source en panne
    n'empêche pas les autres de répondre."""
    sources = sources or SOURCES
    with ThreadPoolExecutor(max_workers=len(sources)) as pool:
        futures = {
            name: pool.submit(search, session_factory(), query)
            for name, search in sources.items()
        }
    results: list[dict] = []
    errors: list[str] = []
    seen: set[tuple[str, str]] = set()
    for name, future in futures.items():
        try:
            found = future.result()
        except Exception as exc:  # réseau, format inattendu…
            errors.append(f"{name} : {type(exc).__name__}")
            continue
        for item in found:
            key = (item["source"], item["id"])
            if key in seen:
                continue
            seen.add(key)
            results.append(item)
    results.sort(key=lambda r: STATUS_ORDER.get(r["status"], 9))
    return {"results": results, "errors": errors}


def internet_archive_pdf(session: requests.Session, identifier: str) -> dict:
    """Trouve le PDF libre d'un livre d'Internet Archive.

    Refuse les livres empruntables (accès restreint) : seuls les fichiers
    publics sont téléchargés.
    """
    if not IA_IDENTIFIER.fullmatch(identifier or ""):
        raise SourceError("Identifiant Internet Archive invalide")
    response = session.get(
        f"https://archive.org/metadata/{identifier}", timeout=TIMEOUT
    )
    response.raise_for_status()
    data = response.json()
    meta = data.get("metadata") if isinstance(data, dict) else None
    if not meta:
        raise SourceError("Livre introuvable sur Internet Archive")

    collections = meta.get("collection") or []
    if isinstance(collections, str):
        collections = [collections]
    restricted = str(meta.get("access-restricted-item", "false")).lower() == "true"
    if restricted or any(c in RESTRICTED_COLLECTIONS for c in collections):
        raise SourceError(
            "Ce livre est seulement empruntable : il n'est pas en accès libre"
        )

    pdfs = [
        f
        for f in data.get("files", [])
        if str(f.get("name", "")).lower().endswith(".pdf")
        and str(f.get("private", "false")).lower() != "true"
    ]
    if not pdfs:
        raise SourceError("Aucun PDF en accès libre pour ce livre")

    def rank(f: dict) -> tuple:
        # « Text PDF » = PDF avec couche texte (copiable, cherchable) : en priorité.
        size = int(f.get("size") or 0)
        return (str(f.get("format")) != "Text PDF", -size)

    best = min(pdfs, key=rank)
    title = meta.get("title")
    if isinstance(title, list):
        title = title[0] if title else None
    return {
        "url": f"https://archive.org/download/{identifier}/{quote(best['name'])}",
        "title": str(title or identifier),
        "size": int(best.get("size") or 0),
    }


def stream_file(session: requests.Session, url: str) -> Iterator[bytes]:
    with session.get(url, stream=True, timeout=(15, 120)) as response:
        response.raise_for_status()
        for chunk in response.iter_content(chunk_size=64 * 1024):
            if chunk:
                yield chunk
