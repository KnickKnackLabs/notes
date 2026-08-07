"""Convention-aware Markdown note component parser.

This first parser surface only separates existing YAML frontmatter from the
visible Markdown body. Future conventions can build here after their syntax and
semantics are settled.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from frontmatter import parse_frontmatter_text


@dataclass(frozen=True)
class Diagnostic:
    code: str
    message: str
    line: int | None = None

    def to_json(self) -> dict[str, Any]:
        row: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.line is not None:
            row["line"] = self.line
        return row


@dataclass(frozen=True)
class ParsedNote:
    path: Path | None
    source: str
    frontmatter: dict[str, Any] | None
    body: str
    diagnostics: list[Diagnostic]

    def to_json(self) -> dict[str, Any]:
        return {
            "path": str(self.path) if self.path is not None else "",
            "frontmatter": self.frontmatter or {},
            "frontmatter_present": self.frontmatter is not None,
            "body": self.body,
            "diagnostics": [diagnostic.to_json() for diagnostic in self.diagnostics],
        }


def parse_note_text(text: str, *, path: Path | None = None) -> ParsedNote:
    frontmatter, body = parse_frontmatter_text(text)
    return ParsedNote(
        path=path,
        source=text,
        frontmatter=frontmatter,
        body=body,
        diagnostics=[],
    )


def read_note_components(path: Path) -> ParsedNote:
    text = path.read_text(encoding="utf-8")
    return parse_note_text(text, path=path)
