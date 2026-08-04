#!/usr/bin/env python3
"""Read-only Dropbox cloud inventory for duplicates and large media.

Safety boundary: the only Dropbox endpoints named or callable in this file are
/files/list_folder and /files/list_folder/continue. The script cannot download,
upload, move, rename, or delete Dropbox content.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import getpass
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.request


API_ENDPOINTS = {
    "list_folder": "https://api.dropboxapi.com/2/files/list_folder",
    "list_folder_continue": "https://api.dropboxapi.com/2/files/list_folder/continue",
}

VIBE_ROOT = Path(os.environ.get("VIBE_ROOT") or (Path.home() / "Vibe"))
DEFAULT_OUTPUT = VIBE_ROOT / "WindowsTuneUp" / "recovery-manifests"
DEFAULT_VIDEO_EXTENSIONS = {
    ".3gp", ".asf", ".avi", ".divx", ".dv", ".f4v", ".flv", ".hevc",
    ".m2ts", ".m4v", ".mkv", ".mod", ".mov", ".mp4", ".mpeg", ".mpg",
    ".mts", ".mxf", ".ogv", ".qt", ".rm", ".rmvb", ".ts", ".vob",
    ".webm", ".wmv",
}

KNOWN_RENAMED_PAIRS = [
    (
        "Food renamed to Food - uploaded 2026-07-31",
        "/photos/2025-07-13 january to may hong kong/food",
        "/photos/2025-07-13 january to may hong kong/food - uploaded 2026-07-31",
    ),
    ("Snapseed Austria", "/photos/2026-04-12/snapseed/austria", "/photos/2026-04-12/snapseed/austria snapseed"),
    ("Snapseed Azerbaijan", "/photos/2026-04-12/snapseed/azerbaijan", "/photos/2026-04-12/snapseed/azerbaijan snapseed"),
    ("Snapseed China", "/photos/2026-04-12/snapseed/china", "/photos/2026-04-12/snapseed/china snapseed"),
    ("Snapseed Taiwan", "/photos/2026-04-12/snapseed/taiwan", "/photos/2026-04-12/snapseed/taiwan snapseed"),
    ("Snapseed Thailand", "/photos/2026-04-12/snapseed/thailand", "/photos/2026-04-12/snapseed/thailand snapseed"),
    (
        "Snapseed United Arab Emirates",
        "/photos/2026-04-12/snapseed/united arab emirates",
        "/photos/2026-04-12/snapseed/united arab emirates snapseed",
    ),
]


def utc_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d_%H%M%S")


def human_size(value: int) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:,.2f} {unit}"
        amount /= 1024
    return f"{value:,} B"


def extension_for(path: str) -> str:
    return PurePosixPath(path).suffix.lower()


def parent_folder_for(path: str) -> str:
    parent = str(PurePosixPath(path).parent)
    return "/" if parent == "." else parent


def top_level_for(path_lower: str) -> str:
    stripped = path_lower.strip("/")
    return stripped.split("/", 1)[0] if stripped else ""


def open_database(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=NORMAL")
    connection.execute("PRAGMA temp_store=MEMORY")
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS scan_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS files (
            path_lower TEXT PRIMARY KEY,
            path_display TEXT NOT NULL,
            name TEXT NOT NULL,
            file_id TEXT,
            rev TEXT,
            size INTEGER NOT NULL,
            content_hash TEXT,
            client_modified TEXT,
            server_modified TEXT,
            extension TEXT NOT NULL,
            top_level TEXT NOT NULL,
            is_downloadable INTEGER NOT NULL,
            in_shared_folder INTEGER NOT NULL,
            shared_read_only INTEGER NOT NULL,
            parent_shared_folder_id TEXT
        );
        """
    )
    return connection


def state_get(connection: sqlite3.Connection, key: str, default: str = "") -> str:
    row = connection.execute("SELECT value FROM scan_state WHERE key = ?", (key,)).fetchone()
    return row[0] if row else default


def state_set(connection: sqlite3.Connection, key: str, value: object) -> None:
    connection.execute(
        "INSERT INTO scan_state(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, str(value)),
    )


def api_call(operation: str, body: dict, token: str) -> dict:
    if operation not in API_ENDPOINTS:
        raise RuntimeError(f"Blocked Dropbox operation: {operation}")
    request_body = json.dumps(body, separators=(",", ":")).encode("utf-8")
    for attempt in range(1, 8):
        request = urllib.request.Request(
            API_ENDPOINTS[operation],
            data=request_body,
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "User-Agent": "DropboxCloudDuplicateAudit/1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=150) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            details = error.read().decode("utf-8", errors="replace")
            if error.code == 429 or 500 <= error.code <= 599:
                if attempt < 7:
                    retry_after = error.headers.get("Retry-After")
                    delay = int(retry_after) if retry_after and retry_after.isdigit() else min(30, 2**attempt)
                    print(f"Dropbox returned HTTP {error.code}; retrying in {delay}s ({attempt}/7).")
                    time.sleep(delay)
                    continue
            raise RuntimeError(f"Dropbox API HTTP {error.code}: {details[:1000]}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt < 7:
                delay = min(30, 2**attempt)
                print(f"Network error; retrying in {delay}s ({attempt}/7): {error}")
                time.sleep(delay)
                continue
            raise
    raise RuntimeError("Dropbox metadata request failed after retries.")


def insert_entries(connection: sqlite3.Connection, entries: list[dict]) -> tuple[int, int]:
    rows = []
    entry_count = 0
    file_count = 0
    for entry in entries:
        entry_count += 1
        if entry.get(".tag") != "file":
            continue
        file_count += 1
        path_lower = entry.get("path_lower") or (entry.get("path_display") or "").lower()
        path_display = entry.get("path_display") or path_lower
        sharing = entry.get("sharing_info") or {}
        rows.append(
            (
                path_lower,
                path_display,
                entry.get("name") or PurePosixPath(path_display).name,
                entry.get("id"),
                entry.get("rev"),
                int(entry.get("size") or 0),
                entry.get("content_hash"),
                entry.get("client_modified"),
                entry.get("server_modified"),
                extension_for(path_display),
                top_level_for(path_lower),
                int(entry.get("is_downloadable", True)),
                int(bool(sharing)),
                int(bool(sharing.get("read_only", False))),
                sharing.get("parent_shared_folder_id"),
            )
        )
    connection.executemany(
        """
        INSERT INTO files(
            path_lower, path_display, name, file_id, rev, size, content_hash,
            client_modified, server_modified, extension, top_level,
            is_downloadable, in_shared_folder, shared_read_only,
            parent_shared_folder_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path_lower) DO UPDATE SET
            path_display=excluded.path_display,
            name=excluded.name,
            file_id=excluded.file_id,
            rev=excluded.rev,
            size=excluded.size,
            content_hash=excluded.content_hash,
            client_modified=excluded.client_modified,
            server_modified=excluded.server_modified,
            extension=excluded.extension,
            top_level=excluded.top_level,
            is_downloadable=excluded.is_downloadable,
            in_shared_folder=excluded.in_shared_folder,
            shared_read_only=excluded.shared_read_only,
            parent_shared_folder_id=excluded.parent_shared_folder_id
        """,
        rows,
    )
    return entry_count, file_count


def scan_dropbox(connection: sqlite3.Connection, token: str, database_path: Path) -> None:
    if state_get(connection, "status") == "complete":
        print("The database already contains a completed scan; regenerating reports only.")
        return

    cursor = state_get(connection, "cursor")
    pages = int(state_get(connection, "pages", "0") or 0)
    entries_seen = int(state_get(connection, "entries_seen", "0") or 0)
    files_seen = int(state_get(connection, "files_seen", "0") or 0)

    if cursor:
        print(f"Resuming metadata scan from page {pages:,}.")
        response = api_call("list_folder_continue", {"cursor": cursor}, token)
    else:
        print("Starting recursive Dropbox metadata scan. No file content will be downloaded.")
        response = api_call(
            "list_folder",
            {
                "path": "",
                "recursive": True,
                "include_deleted": False,
                "include_has_explicit_shared_members": False,
                "include_media_info": False,
                "include_mounted_folders": True,
                "include_non_downloadable_files": True,
                "limit": 2000,
            },
            token,
        )

    while True:
        page_entries, page_files = insert_entries(connection, list(response.get("entries") or []))
        pages += 1
        entries_seen += page_entries
        files_seen += page_files
        cursor = response.get("cursor") or ""
        state_set(connection, "cursor", cursor)
        state_set(connection, "pages", pages)
        state_set(connection, "entries_seen", entries_seen)
        state_set(connection, "files_seen", files_seen)
        state_set(connection, "status", "incomplete")
        connection.commit()
        print(
            f"Page {pages:,}: {entries_seen:,} entries, {files_seen:,} files",
            end="\r" if response.get("has_more") else "\n",
            flush=True,
        )
        if not response.get("has_more"):
            state_set(connection, "status", "complete")
            state_set(connection, "completed_utc", dt.datetime.now(dt.timezone.utc).isoformat())
            connection.commit()
            break
        response = api_call("list_folder_continue", {"cursor": cursor}, token)

    print(f"Metadata scan completed. Resumable database: {database_path}")


def write_csv(path: Path, headers: list[str], rows) -> int:
    count = 0
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(headers)
        for row in rows:
            writer.writerow(row)
            count += 1
    return count


def folder_rows(connection: sqlite3.Connection, prefix: str) -> list[sqlite3.Row]:
    return connection.execute(
        "SELECT * FROM files WHERE path_lower = ? OR path_lower LIKE ? ORDER BY path_lower",
        (prefix, prefix.rstrip("/") + "/%"),
    ).fetchall()


def analyze_known_pairs(connection: sqlite3.Connection, output_path: Path, summary_path: Path) -> list[dict]:
    detail_headers = [
        "PairName", "Side", "Status", "Path", "SizeBytes", "SizeGiB",
        "ContentHash", "MatchingPath", "ServerModified",
    ]
    detail_rows = []
    summary_rows = []
    for pair_name, old_prefix, replacement_prefix in KNOWN_RENAMED_PAIRS:
        old_rows = folder_rows(connection, old_prefix)
        replacement_rows = folder_rows(connection, replacement_prefix)
        replacement_by_key: dict[tuple[str, int], list[str]] = {}
        old_keys = set()
        for row in replacement_rows:
            key = (row["content_hash"] or "", int(row["size"]))
            if key[0]:
                replacement_by_key.setdefault(key, []).append(row["path_display"])
        confirmed_count = 0
        confirmed_bytes = 0
        old_unique_count = 0
        old_unique_bytes = 0
        for row in old_rows:
            key = (row["content_hash"] or "", int(row["size"]))
            if key[0]:
                old_keys.add(key)
            matches = replacement_by_key.get(key, []) if key[0] else []
            if matches:
                status = "CONFIRMED_IN_REPLACEMENT"
                confirmed_count += 1
                confirmed_bytes += int(row["size"])
            elif key[0]:
                status = "OLD_UNIQUE_OR_CHANGED_REVIEW"
                old_unique_count += 1
                old_unique_bytes += int(row["size"])
            else:
                status = "NO_CONTENT_HASH_REVIEW"
                old_unique_count += 1
                old_unique_bytes += int(row["size"])
            detail_rows.append(
                [pair_name, "Old", status, row["path_display"], row["size"], row["size"] / 1024**3,
                 row["content_hash"], " | ".join(matches[:5]), row["server_modified"]]
            )
        replacement_additional_count = 0
        replacement_additional_bytes = 0
        for row in replacement_rows:
            key = (row["content_hash"] or "", int(row["size"]))
            if key[0] and key in old_keys:
                continue
            replacement_additional_count += 1
            replacement_additional_bytes += int(row["size"])
            detail_rows.append(
                [pair_name, "Replacement", "REPLACEMENT_ADDITIONAL", row["path_display"], row["size"],
                 row["size"] / 1024**3, row["content_hash"], "", row["server_modified"]]
            )
        summary_rows.append(
            {
                "PairName": pair_name,
                "OldPath": old_prefix,
                "ReplacementPath": replacement_prefix,
                "OldFileCount": len(old_rows),
                "ReplacementFileCount": len(replacement_rows),
                "ConfirmedOldFileCount": confirmed_count,
                "ConfirmedOldBytes": confirmed_bytes,
                "OldUniqueOrChangedCount": old_unique_count,
                "OldUniqueOrChangedBytes": old_unique_bytes,
                "ReplacementAdditionalCount": replacement_additional_count,
                "ReplacementAdditionalBytes": replacement_additional_bytes,
                "WholeOldFolderEligible": "YES" if old_rows and old_unique_count == 0 else "NO",
            }
        )
    write_csv(output_path, detail_headers, detail_rows)
    headers = list(summary_rows[0].keys()) if summary_rows else []
    write_csv(summary_path, headers, ([row[h] for h in headers] for row in summary_rows))
    return summary_rows


def analyze_database(
    connection: sqlite3.Connection,
    output_directory: Path,
    database_path: Path,
    large_threshold: int,
    video_extensions: set[str],
) -> dict:
    connection.row_factory = sqlite3.Row
    connection.executescript(
        """
        CREATE INDEX IF NOT EXISTS idx_files_hash_size ON files(content_hash, size);
        CREATE INDEX IF NOT EXISTS idx_files_size ON files(size);
        CREATE INDEX IF NOT EXISTS idx_files_extension_size ON files(extension, size);
        CREATE INDEX IF NOT EXISTS idx_files_top_level ON files(top_level);
        DROP TABLE IF EXISTS duplicate_groups;
        CREATE TABLE duplicate_groups (
            group_id INTEGER PRIMARY KEY AUTOINCREMENT,
            content_hash TEXT NOT NULL,
            size INTEGER NOT NULL,
            file_count INTEGER NOT NULL,
            redundant_bytes INTEGER NOT NULL,
            first_path TEXT NOT NULL,
            top_level_count INTEGER NOT NULL,
            UNIQUE(content_hash, size)
        );
        INSERT INTO duplicate_groups(content_hash, size, file_count, redundant_bytes, first_path, top_level_count)
        SELECT content_hash, size, COUNT(*), (COUNT(*) - 1) * size, MIN(path_display), COUNT(DISTINCT top_level)
        FROM files
        WHERE content_hash IS NOT NULL AND content_hash <> '' AND size > 0
        GROUP BY content_hash, size
        HAVING COUNT(*) > 1
        ORDER BY (COUNT(*) - 1) * size DESC, size DESC;
        """
    )
    connection.commit()

    stamp = utc_stamp()
    group_csv = output_directory / f"Dropbox-exact-duplicate-groups_{stamp}.csv"
    duplicate_files_csv = output_directory / f"Dropbox-exact-duplicate-files_{stamp}.csv"
    large_files_csv = output_directory / f"Dropbox-large-files_{stamp}.csv"
    video_files_csv = output_directory / f"Dropbox-video-files_{stamp}.csv"
    duplicate_videos_csv = output_directory / f"Dropbox-exact-duplicate-videos_{stamp}.csv"
    review_queue_csv = output_directory / f"Dropbox-cleanup-review-queue_{stamp}.csv"
    known_detail_csv = output_directory / f"Dropbox-known-renamed-comparison_{stamp}.csv"
    known_summary_csv = output_directory / f"Dropbox-known-renamed-summary_{stamp}.csv"
    summary_md = output_directory / f"Dropbox-cloud-file-audit-summary_{stamp}.md"

    group_headers = [
        "GroupId", "ContentHash", "FileSizeBytes", "FileSizeGiB", "FileCount",
        "PotentialReclaimBytes", "PotentialReclaimGiB", "FirstPath", "TopLevelFolderCount",
    ]
    group_count = write_csv(
        group_csv,
        group_headers,
        (
            [row["group_id"], row["content_hash"], row["size"], row["size"] / 1024**3,
             row["file_count"], row["redundant_bytes"], row["redundant_bytes"] / 1024**3,
             row["first_path"], row["top_level_count"]]
            for row in connection.execute("SELECT * FROM duplicate_groups ORDER BY redundant_bytes DESC, size DESC")
        ),
    )

    file_headers = [
        "GroupId", "DuplicateStatus", "Path", "ParentFolder", "Name", "Extension", "SizeBytes", "SizeGiB",
        "GroupFileCount", "GroupPotentialReclaimBytes", "ContentHash", "FileId", "Revision",
        "ServerModified", "TopLevelFolder", "InSharedFolder", "SharedReadOnly",
        "Decision", "Reason", "Approved",
    ]
    duplicate_query = """
        SELECT g.group_id, f.*, g.file_count, g.redundant_bytes
        FROM files f JOIN duplicate_groups g
          ON f.content_hash = g.content_hash AND f.size = g.size
        ORDER BY g.redundant_bytes DESC, g.group_id, f.path_lower
    """
    duplicate_file_count = write_csv(
        duplicate_files_csv,
        file_headers,
        (
            [row["group_id"], "EXACT_DUPLICATE", row["path_display"], parent_folder_for(row["path_display"]), row["name"],
             row["extension"], row["size"], row["size"] / 1024**3, row["file_count"],
             row["redundant_bytes"], row["content_hash"], row["file_id"], row["rev"],
             row["server_modified"], row["top_level"], row["in_shared_folder"], row["shared_read_only"],
             "", "", "NO"]
            for row in connection.execute(duplicate_query)
        ),
    )

    large_query = """
        SELECT f.*, g.group_id, g.file_count, g.redundant_bytes
        FROM files f LEFT JOIN duplicate_groups g
          ON f.content_hash = g.content_hash AND f.size = g.size
        WHERE f.size >= ?
        ORDER BY f.size DESC, f.path_lower
    """
    large_file_count = write_csv(
        large_files_csv,
        file_headers,
        (
            [row["group_id"], "EXACT_DUPLICATE" if row["group_id"] is not None else "UNIQUE_IN_INVENTORY",
             row["path_display"], parent_folder_for(row["path_display"]), row["name"],
             row["extension"], row["size"], row["size"] / 1024**3, row["file_count"],
             row["redundant_bytes"], row["content_hash"], row["file_id"], row["rev"],
             row["server_modified"], row["top_level"], row["in_shared_folder"], row["shared_read_only"],
             "", "", "NO"]
            for row in connection.execute(large_query, (large_threshold,))
        ),
    )

    placeholders = ",".join("?" for _ in video_extensions)
    video_query = f"""
        SELECT f.*, g.group_id, g.file_count, g.redundant_bytes
        FROM files f LEFT JOIN duplicate_groups g
          ON f.content_hash = g.content_hash AND f.size = g.size
        WHERE f.extension IN ({placeholders})
        ORDER BY f.size DESC, f.path_lower
    """
    video_file_count = write_csv(
        video_files_csv,
        file_headers,
        (
            [row["group_id"], "EXACT_DUPLICATE" if row["group_id"] is not None else "UNIQUE_IN_INVENTORY",
             row["path_display"], parent_folder_for(row["path_display"]), row["name"],
             row["extension"], row["size"], row["size"] / 1024**3, row["file_count"],
             row["redundant_bytes"], row["content_hash"], row["file_id"], row["rev"],
             row["server_modified"], row["top_level"], row["in_shared_folder"], row["shared_read_only"],
             "", "", "NO"]
            for row in connection.execute(video_query, tuple(sorted(video_extensions)))
        ),
    )
    duplicate_video_count = write_csv(
        duplicate_videos_csv,
        file_headers,
        (
            [row["group_id"], "EXACT_DUPLICATE", row["path_display"], parent_folder_for(row["path_display"]), row["name"],
             row["extension"], row["size"], row["size"] / 1024**3, row["file_count"],
             row["redundant_bytes"], row["content_hash"], row["file_id"], row["rev"],
             row["server_modified"], row["top_level"], row["in_shared_folder"], row["shared_read_only"],
             "", "", "NO"]
            for row in connection.execute(video_query, tuple(sorted(video_extensions)))
            if row["group_id"] is not None
        ),
    )

    review_headers = [
        "GroupId", "CandidateCategory", "ReviewSafety", "DuplicateStatus", "Path", "ParentFolder",
        "Name", "Extension", "SizeBytes", "SizeGiB", "GroupFileCount", "GroupPotentialReclaimBytes",
        "ContentHash", "FileId", "Revision", "ServerModified", "TopLevelFolder", "InSharedFolder",
        "SharedReadOnly", "Decision", "Reason", "Approved",
    ]
    review_query = f"""
        SELECT f.*, g.group_id, g.file_count, g.redundant_bytes
        FROM files f LEFT JOIN duplicate_groups g
          ON f.content_hash = g.content_hash AND f.size = g.size
        WHERE g.group_id IS NOT NULL OR f.size >= ? OR f.extension IN ({placeholders})
        ORDER BY
          CASE WHEN g.group_id IS NOT NULL THEN 0 ELSE 1 END,
          COALESCE(g.redundant_bytes, 0) DESC,
          g.group_id,
          f.size DESC,
          f.path_lower
    """

    def review_row(row: sqlite3.Row) -> list:
        is_duplicate = row["group_id"] is not None
        is_video = row["extension"] in video_extensions
        is_large = int(row["size"]) >= large_threshold
        if is_duplicate and is_video:
            category = "EXACT_DUPLICATE_VIDEO"
        elif is_duplicate:
            category = "EXACT_DUPLICATE_OTHER"
        elif is_video and is_large:
            category = "UNIQUE_LARGE_VIDEO"
        elif is_video:
            category = "UNIQUE_VIDEO"
        else:
            category = "UNIQUE_LARGE_OTHER"
        safety = "KEEP_AT_LEAST_ONE_VERIFIED_COPY" if is_duplicate else "UNIQUE_HIGH_RISK_REVIEW"
        duplicate_status = "EXACT_DUPLICATE" if is_duplicate else "UNIQUE_IN_INVENTORY"
        return [
            row["group_id"], category, safety, duplicate_status, row["path_display"],
            parent_folder_for(row["path_display"]), row["name"], row["extension"], row["size"],
            row["size"] / 1024**3, row["file_count"], row["redundant_bytes"], row["content_hash"],
            row["file_id"], row["rev"], row["server_modified"], row["top_level"],
            row["in_shared_folder"], row["shared_read_only"], "", "", "NO",
        ]

    review_queue_count = write_csv(
        review_queue_csv,
        review_headers,
        (
            review_row(row)
            for row in connection.execute(
                review_query,
                (large_threshold, *tuple(sorted(video_extensions))),
            )
        ),
    )

    known_summary = analyze_known_pairs(connection, known_detail_csv, known_summary_csv)
    totals = connection.execute(
        "SELECT COUNT(*) AS files, COALESCE(SUM(size),0) AS bytes, "
        "SUM(CASE WHEN content_hash IS NOT NULL AND content_hash <> '' THEN 1 ELSE 0 END) AS hashed FROM files"
    ).fetchone()
    duplicate_totals = connection.execute(
        "SELECT COUNT(*) AS groups, COALESCE(SUM(redundant_bytes),0) AS reclaim FROM duplicate_groups"
    ).fetchone()
    video_bytes = connection.execute(
        f"SELECT COALESCE(SUM(size), 0) FROM files WHERE extension IN ({placeholders})",
        tuple(sorted(video_extensions)),
    ).fetchone()[0]

    with summary_md.open("w", encoding="utf-8") as handle:
        handle.write("# Dropbox cloud duplicate and large-file audit\n\n")
        handle.write("This report was produced using read-only Dropbox metadata endpoints. No file content was downloaded and no Dropbox item was changed.\n\n")
        handle.write("## Totals\n\n")
        handle.write(f"- Files inventoried: {totals['files']:,}\n")
        handle.write(f"- Logical size inventoried: {human_size(totals['bytes'])}\n")
        handle.write(f"- Files with Dropbox content hashes: {totals['hashed']:,}\n")
        handle.write(f"- Exact duplicate groups: {duplicate_totals['groups']:,}\n")
        handle.write(f"- Maximum theoretical duplicate reclaim: {human_size(duplicate_totals['reclaim'])}\n")
        handle.write(f"- Files at least {human_size(large_threshold)}: {large_file_count:,}\n")
        handle.write(f"- Video files: {video_file_count:,} ({human_size(video_bytes)})\n")
        handle.write(f"- Video files belonging to exact duplicate groups: {duplicate_video_count:,}\n\n")
        handle.write(f"- Consolidated review-queue files: {review_queue_count:,}\n\n")
        handle.write("Maximum theoretical reclaim assumes one copy is kept from every exact-content group. It is not a deletion recommendation: paths may have independent meaning.\n\n")
        handle.write("## Known renamed folders\n\n")
        handle.write("| Pair | Old files | Replacement files | Old unique/changed | Whole old folder eligible |\n")
        handle.write("|---|---:|---:|---:|---|\n")
        for row in known_summary:
            handle.write(
                f"| {row['PairName']} | {row['OldFileCount']:,} | {row['ReplacementFileCount']:,} | "
                f"{row['OldUniqueOrChangedCount']:,} | {row['WholeOldFolderEligible']} |\n"
            )
        handle.write("\n## Outputs\n\n")
        for path in [group_csv, duplicate_files_csv, large_files_csv, video_files_csv, duplicate_videos_csv,
                     review_queue_csv,
                     known_detail_csv, known_summary_csv, database_path]:
            handle.write(f"- `{path}`\n")

    return {
        "database": str(database_path),
        "summary": str(summary_md),
        "duplicate_groups": str(group_csv),
        "duplicate_files": str(duplicate_files_csv),
        "large_files": str(large_files_csv),
        "video_files": str(video_files_csv),
        "duplicate_videos": str(duplicate_videos_csv),
        "review_queue": str(review_queue_csv),
        "known_renamed_detail": str(known_detail_csv),
        "known_renamed_summary": str(known_summary_csv),
        "file_count": totals["files"],
        "logical_bytes": totals["bytes"],
        "duplicate_group_count": duplicate_totals["groups"],
        "potential_reclaim_bytes": duplicate_totals["reclaim"],
        "large_file_count": large_file_count,
        "video_file_count": video_file_count,
        "duplicate_video_count": duplicate_video_count,
        "review_queue_count": review_queue_count,
    }


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="dropbox-audit-self-test-") as temp:
        root = Path(temp)
        database = root / "test.sqlite"
        connection = open_database(database)
        sample = [
            ("/photos/a.mp4", "/Photos/a.mp4", "a.mp4", "id:a", "r1", 2_000_000_000, "hash-video", "", "2026-01-01T00:00:00Z", ".mp4", "photos", 1, 0, 0, None),
            ("/backup/a.mp4", "/Backup/a.mp4", "a.mp4", "id:b", "r1", 2_000_000_000, "hash-video", "", "2026-01-01T00:00:00Z", ".mp4", "backup", 1, 0, 0, None),
            ("/docs/large.pdf", "/Docs/large.pdf", "large.pdf", "id:c", "r1", 200_000_000, "hash-pdf", "", "2026-01-01T00:00:00Z", ".pdf", "docs", 1, 0, 0, None),
            ("/small/x.txt", "/Small/x.txt", "x.txt", "id:d", "r1", 10, "hash-small", "", "2026-01-01T00:00:00Z", ".txt", "small", 1, 0, 0, None),
            ("/small/y.txt", "/Small/y.txt", "y.txt", "id:e", "r1", 10, "hash-small", "", "2026-01-01T00:00:00Z", ".txt", "small", 1, 0, 0, None),
        ]
        connection.executemany(
            "INSERT INTO files VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            sample,
        )
        state_set(connection, "status", "complete")
        connection.commit()
        result = analyze_database(connection, root, database, 100 * 1024**2, DEFAULT_VIDEO_EXTENSIONS)
        connection.close()
        assert result["file_count"] == 5
        assert result["duplicate_group_count"] == 2
        assert result["large_file_count"] == 3
        assert result["video_file_count"] == 2
        assert result["duplicate_video_count"] == 2
        assert result["review_queue_count"] == 5
        assert result["potential_reclaim_bytes"] == 2_000_000_010
    print("SELF-TEST PASSED: no Dropbox API call was made.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only Dropbox duplicate and large-media audit")
    parser.add_argument("--output-directory", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--database", type=Path, help="Existing database to resume/reanalyze; omit to start a new scan")
    parser.add_argument("--large-threshold-mib", type=int, default=100)
    parser.add_argument(
        "--video-extensions",
        default=",".join(sorted(DEFAULT_VIDEO_EXTENSIONS)),
        help="Comma-separated extensions, including or omitting the leading dot",
    )
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.large_threshold_mib <= 0:
        raise RuntimeError("--large-threshold-mib must be greater than zero.")
    output_directory = args.output_directory.resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(output_directory).free < 1024**3:
        raise RuntimeError("Less than 1 GiB is free on the report drive; refusing to start the inventory.")
    database_path = args.database.resolve() if args.database else output_directory / f"Dropbox-cloud-file-inventory_{utc_stamp()}.sqlite"
    connection = open_database(database_path)
    try:
        needs_scan = state_get(connection, "status") != "complete"
        if needs_scan:
            print("SAFETY: this program can call only Dropbox list_folder metadata endpoints.")
            print("Required token scope: files.metadata.read. Do not grant content-write permission for this scan.")
            token = getpass.getpass("Paste the temporary Dropbox read-only access token (input hidden): ").strip()
            if not token:
                raise RuntimeError("No Dropbox token was entered.")
            try:
                scan_dropbox(connection, token, database_path)
            except Exception:
                print(f"The partial scan is saved. Resume with --database \"{database_path}\"", file=sys.stderr)
                raise
            finally:
                token = ""
        extensions = {
            value if value.startswith(".") else "." + value
            for value in (item.strip().lower() for item in args.video_extensions.split(","))
            if value
        }
        if not extensions:
            raise RuntimeError("At least one video extension must be supplied.")
        result = analyze_database(
            connection,
            output_directory,
            database_path,
            args.large_threshold_mib * 1024**2,
            extensions,
        )
    finally:
        connection.close()
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
