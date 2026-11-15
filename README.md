# Minied

A native macOS viewer for Markdown files, with Mermaid diagrams.

Minied is written in Zig and follows [TigerStyle](docs/TIGER_STYLE.md). It has no dependencies
apart from the Zig toolchain and the frameworks that ship with macOS. There is no web view: text
is laid out by TextKit, and diagrams are drawn with CoreGraphics.

## Build and run

The Nix shell provides Zig and the macOS SDK.

```sh
nix develop -c zig build                      # writes zig-out/Minied.app and zig-out/bin/minied
nix develop -c zig build run -- README.md     # builds, then opens a file
nix develop -c zig build test                 # tests the parser and the diagram layout
open zig-out/Minied.app --args "$PWD/README.md"
```

The app needs macOS 26 or later on Apple Silicon. It must be linked against the macOS 26 SDK or
later, because AppKit gives the Liquid Glass design only to such binaries. The flake pins the SDK.

## What it does

- Opens `.md` files from the Open panel, the command line, the Dock, or Finder's "Open With".
- Shows up to 8 documents, each in its own window.
- Reloads a document when its file changes on disk, and keeps the scroll position.
- Lists the headings in a sidebar. Select one to go to it.
- Follows the system appearance and accent color.
- Find, copy, print and zoom work on the whole document, diagrams included.
- Links to headings scroll, links to other Markdown files open in Minied, and other links go to
  the default application.

Markdown: CommonMark blocks and inlines, plus GFM tables, task lists, strikethrough and
autolinks. Raw HTML is shown as text. Images load from local files only: Minied never uses the
network.

Mermaid: `flowchart`/`graph`, `sequenceDiagram`, `stateDiagram`, `classDiagram`, `erDiagram`,
`pie` and `gantt`. A diagram that cannot be laid out is shown as its source, with the reason.

## Design

| File | Role |
|:-----|:-----|
| `src/markdown.zig`, `src/markdown_inline.zig` | Markdown to a flat event stream |
| `src/mermaid.zig`, `src/mermaid/` | Mermaid source to a display list |
| `src/scene.zig` | The display list: shapes, lines and text with semantic colors |
| `src/render.zig` | Events to an attributed string for TextKit |
| `src/canvas.zig` | Display list to CoreGraphics, as a text attachment |
| `src/document.zig` | The document pool, windows, loading and reloading |
| `src/main.zig` | Application delegate, menus, toolbar |
| `src/objc.zig`, `src/cocoa.zig` | Objective-C runtime bindings |

The parser and the diagram layout are plain Zig. They do not allocate and do not recurse: all
working memory is static, which bounds what the viewer accepts.

| Limit | Value |
|:------|------:|
| File size | 4 MB |
| Open documents | 8 |
| Block nesting depth | 16 |
| Diagrams per document | 64 |
| Headings in the sidebar | 2048 |

A file over 4 MB does not open. Past the other limits the viewer degrades: deeper nesting is
shown as plain text, and a diagram or the tail of a document that does not fit is replaced by a
notice.
