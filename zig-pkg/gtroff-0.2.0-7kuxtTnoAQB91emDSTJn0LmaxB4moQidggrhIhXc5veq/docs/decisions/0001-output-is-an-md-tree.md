# 0001: gtroff-zig produces md-zig trees

Status: accepted by the maintainer in conversation (see md-zig decision 0002).

## Problem

dkman must show man pages and Markdown alike and with one renderer.

## Decision

The library does not render. `parseMan` returns an `md.Document` whose tree uses
headings, paragraphs, definition lists, bullet lists, block quotes, code blocks
and inline emphasis. Rendering is md-zig's `writeText` (or `writeHtml`, or a GTK
walker).

## Alternatives considered

- A tree and renderer of its own: duplicates md-zig's wrapping and styles, and
  the two formats would look different.
- Rendering to text directly (like groff -Tutf8): exact for roff, but no
  structure for the GTK viewer and no shared look.

## Consequences

- Layout fidelity is limited to what the tree can express (see
  `docs/architecture.md`, "Known losses").
- gtroff-zig depends on md-zig; changes to md-zig's `ast.zig` are API changes
  for this library.
- mdoc(7) will map to the same node kinds.
