"""Render untrusted values as literal Markdown text."""
from __future__ import annotations


_MARKDOWN_SPECIALS = frozenset(r"\`*_{}[]<>()#+-.!|>")


def markdown_literal(value: object) -> str:
    """Escape Markdown and raw-HTML syntax while preserving line breaks."""
    text = str(value or "").replace("\r\n", "\n").replace("\r", "\n")
    return "".join(
        f"\\{character}" if character in _MARKDOWN_SPECIALS else character
        for character in text
    )


def markdown_table_cell(value: object) -> str:
    """Render a value inside a Markdown table without active markup."""
    return markdown_literal(value).strip().replace("\n", " / ")
