#!/usr/bin/env python3
"""Maintain the private, deduplicated corpus of human Unramble recordings.

The command never modifies or removes a source recording. Canonical files are
named by their SHA-256 and copied with APFS clone-on-write when available.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Iterable


REPOSITORY = Path(__file__).resolve().parents[1]
LOCAL_ONLY = REPOSITORY / ".scratch/archive/local-only"
CORPUS = REPOSITORY / ".scratch/recordings/originals"
CANONICAL = CORPUS / "by-sha256"
CATALOG = CORPUS / "catalog.jsonl"


def source_roots() -> list[tuple[str, Path]]:
    return [
        (
            "live-app",
            Path.home() / "Library/Application Support/Unramble/recordings",
        ),
        ("live-capture", LOCAL_ONLY / "data/live-captures-2026-07-20"),
        ("live-capture", LOCAL_ONLY / "data/live-captures-2026-07-21"),
        ("historical-dictation", LOCAL_ONLY / "data/wavs"),
        (
            "human-matched",
            REPOSITORY
            / ".scratch/archive/legacy-parent-workspace/private"
            / "segmentation-boundary/s01",
        ),
    ]


def wavs(root: Path) -> Iterable[Path]:
    if root.exists():
        yield from sorted(path for path in root.rglob("*.wav") if path.is_file())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(REPOSITORY))
    except ValueError:
        return str(path)


def clone_or_copy(source: Path, destination: Path) -> None:
    try:
        subprocess.run(
            ["/bin/cp", "-c", str(source), str(destination)],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError:
        shutil.copy2(source, destination)


def ingest() -> int:
    CANONICAL.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    unique: set[str] = set()

    for source_class, root in source_roots():
        for source in wavs(root):
            digest = sha256(source)
            destination = CANONICAL / f"{digest}.wav"
            if not destination.exists():
                clone_or_copy(source, destination)
            elif sha256(destination) != digest:
                raise RuntimeError(f"canonical hash mismatch: {destination}")
            unique.add(digest)
            rows.append(
                {
                    "schema_version": 1,
                    "sha256": digest,
                    "source_class": source_class,
                    "source_path": display_path(source),
                    "canonical_path": display_path(destination),
                    "bytes": source.stat().st_size,
                }
            )

    temporary = CATALOG.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        for row in rows:
            output.write(
                json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
            )
    os.replace(temporary, CATALOG)
    print(json.dumps({"aliases": len(rows), "unique_originals": len(unique)}))
    return 0


def load_catalog() -> list[dict[str, object]]:
    if not CATALOG.exists():
        raise RuntimeError("catalog missing; run ingest first")
    return [json.loads(line) for line in CATALOG.read_text().splitlines()]


def resolve_catalog_path(value: object) -> Path:
    path = Path(str(value))
    return path if path.is_absolute() else REPOSITORY / path


def verify() -> int:
    rows = load_catalog()
    failures: list[str] = []
    checked: set[str] = set()
    for row in rows:
        digest = str(row["sha256"])
        source = resolve_catalog_path(row["source_path"])
        canonical = resolve_catalog_path(row["canonical_path"])
        if not source.exists():
            failures.append(f"missing source: {source}")
        if digest not in checked:
            if not canonical.exists():
                failures.append(f"missing canonical: {canonical}")
            elif sha256(canonical) != digest:
                failures.append(f"hash mismatch: {canonical}")
            checked.add(digest)

    print(
        json.dumps(
            {
                "aliases": len(rows),
                "unique_originals": len(checked),
                "failures": failures,
            },
            indent=2,
        )
    )
    return 1 if failures else 0


def summary() -> int:
    rows = load_catalog()
    classes: dict[str, dict[str, object]] = {}
    for row in rows:
        name = str(row["source_class"])
        record = classes.setdefault(name, {"aliases": 0, "hashes": set()})
        record["aliases"] = int(record["aliases"]) + 1
        hashes = record["hashes"]
        assert isinstance(hashes, set)
        hashes.add(str(row["sha256"]))
    result = {
        name: {"aliases": value["aliases"], "unique": len(value["hashes"])}
        for name, value in sorted(classes.items())
    }
    print(json.dumps(result, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("ingest", "verify", "summary"))
    command = parser.parse_args().command
    return {"ingest": ingest, "verify": verify, "summary": summary}[command]()


if __name__ == "__main__":
    sys.exit(main())
