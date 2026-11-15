# mini-md-view

Minimal Markdown viewer for macOS without webviews. It renders Mermaid diagrams too.

mini-md-view is written in Zig and follows [TigerStyle](docs/TIGER_STYLE.md). It has no
dependencies apart from the Zig toolchain and the frameworks that ship with macOS. There is no web view: text
is laid out by TextKit, and diagrams are drawn with CoreGraphics.

## Build and run

The Nix shell provides Zig and the macOS SDK.

```sh
nix develop -c zig build                    # zig-out/MiniMdView.app
nix develop -c zig build run -- README.md   # build, then open a file
nix develop -c zig build test               # parser and diagram layout
nix develop -c zig build icon               # redraw the icon from tools/icon.zig
open zig-out/MiniMdView.app --args "$PWD/README.md"
```

The app needs Apple Silicon. Zig targets the macOS version of the build machine, so the binary
needs that version or later. It must be linked against the macOS 26 SDK or later, because AppKit
gives the Liquid Glass design only to such binaries. The flake provides that SDK.

## What it does

- Opens `.md` files from the Open panel, the command line, the Dock, Finder's "Open With", or a
  drop on a window. File > Open Recent lists the documents that you opened last.
- Shows up to 8 documents, each in its own window. Started without a file, it opens the documents
  that were open when it quit.
- Reloads a document when its file changes on disk, and keeps the scroll position. When the new
  file cannot be shown, the old content stays and the window subtitle says why.
- Lists the headings in a sidebar. Select one to go to it. As you scroll, the sidebar selects the
  heading of the section at the top of the window.
- Follows the system appearance and accent color.
- Find, copy, print and zoom work on the whole document, diagrams included. The zoom applies to
  every window, and the viewer remembers it.
- Links to headings scroll, links to other Markdown files show them in the same window, and web
  and mail links go to the default application. A link to any other local file shows the file in
  Finder and does not open it, so a document cannot run a script with one click.
- Back and Forward (Go menu, Command-[ and Command-], or the toolbar) return to the files and
  scroll positions that a window showed. Each window keeps its last 32 steps.

Markdown: CommonMark blocks and inlines, plus GFM tables, task lists, strikethrough and
autolinks. Raw HTML is shown as text. Images load from local files only: mini-md-view never uses the
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
