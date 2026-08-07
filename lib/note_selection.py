"""Resolve public note selectors to readable Markdown paths."""

from __future__ import annotations

from pathlib import Path


def note_path_candidates(
    selector: str, *, target_dir: Path, notes_dir: Path
) -> list[Path]:
    """Return de-duplicated path candidates in public selector precedence."""
    raw = Path(selector).expanduser()
    if raw.is_absolute():
        candidates = [raw]
    else:
        candidates = [target_dir / raw, notes_dir / raw]
        if raw.suffix != ".md":
            candidates.extend(
                [target_dir / f"{selector}.md", notes_dir / f"{selector}.md"]
            )

    unique: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate.resolve(strict=False))
        if key not in seen:
            unique.append(candidate)
            seen.add(key)
    return unique


def resolve_note_path(
    selector: str, *, target_dir: Path, notes_dir: Path
) -> Path | None:
    for candidate in note_path_candidates(
        selector, target_dir=target_dir, notes_dir=notes_dir
    ):
        if candidate.is_file():
            return candidate
    return None
