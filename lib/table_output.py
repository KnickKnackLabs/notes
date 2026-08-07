"""Shared table presentation for human-facing Notes commands."""

from __future__ import annotations

import os
import subprocess
from collections.abc import Iterable, Sequence


def sanitize_cell(value: object) -> str:
    return str(value).replace("\t", " ").replace("\n", "⏎")


def format_tsv(headers: Sequence[object], rows: Iterable[Sequence[object]]) -> str:
    lines = ["\t".join(sanitize_cell(value) for value in headers)]
    lines.extend("\t".join(sanitize_cell(value) for value in row) for row in rows)
    return "\n".join(lines)


def print_table(headers: Sequence[object], rows: Iterable[Sequence[object]]) -> None:
    table = format_tsv(headers, rows)
    gum = os.environ.get("GUM", "gum")

    try:
        result = subprocess.run(
            [gum, "table", "--print", "--separator", "\t"],
            input=f"{table}\n",
            text=True,
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError):
        print(table)
        return

    print(result.stdout, end="")
