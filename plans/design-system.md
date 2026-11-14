# Design system

The UI is governed by three skills (mandated by `CLAUDE.md`) and one source of
truth in code (`Theme`).

## The skills

- **macos-design** — layout, composition, native idioms. Use before deciding a
  design and when reviewing one.
- **typography-designer** — the type scale and hierarchy.
- **swiftui-pro** — modern-API/correctness review of the code.

Run them before *and* after writing UI. They're why the choices below look the
way they do.

## `Theme` — one place for type and metrics

Every font and layout constant lives in `Sources/BooxBridge/Theme.swift`. Two
rules keep it honest (`SWIFTUI-RULES.md` §2.4, §5.1):

1. **Scale is semantic.** Fonts come from SwiftUI text styles
   (`.caption` → `.body` → `.title2` → `.largeTitle`), never hardcoded point
   sizes, so Dynamic Type and OS metric updates keep working.
2. **Emphasis is weight; de-emphasis is color.** Headings get `.semibold`/
   `.bold`; quieter text gets `.secondary`, never a lighter weight.

### The type scale

| Role            | Style                          | Used by                     |
|-----------------|--------------------------------|-----------------------------|
| Page title      | `.largeTitle` bold             | reading column hero         |
| Lead            | `.title3` + `.secondary`       | standfirst under the title  |
| Section heading | `.title2` semibold             | reading sections            |
| Body            | `.body` + line spacing         | reading paragraphs          |
| Table cell      | `.body`                        | table text columns          |
| Table number    | `.body` monospaced-digit       | the Value column (aligns)   |
| Badge           | `.caption` medium              | `StatusBadge`               |
| Meta            | `.caption` + `.secondary`      | the table footer count      |

## macOS idioms applied

- **NavigationSplitView** with a column-width-constrained sidebar — the Mail/
  Notes/Reminders shape.
- **Reading measure cap** (`Theme.readingMaxWidth`) so body lines stay near the
  60–75-character ideal regardless of window width; the column centers in
  extra space rather than stretching.
- **Native `Table`** with sortable columns (`KeyPathComparator`), tabular
  figures for the numeric column, a relative-date column, and a `.bar`-backed
  footer showing a live count.
- **`StatusBadge`** is one reusable component with the tint living next to the
  status case, so every surface shows the same color (`SWIFTUI-RULES.md` §5.4),
  and it carries a VoiceOver label because the color encodes meaning.
- **`ContentUnavailableView`** for the no-selection state — the native empty-
  state idiom (`SWIFTUI-RULES.md` §7.1).
- **Light/dark** come for free: everything uses system colors/materials
  (`.secondary`, `.bar`, accent), so both modes are correct without a second
  palette.

When you restyle, change `Theme` first; if you're typing the same literal a
third time in a view, it belongs in `Theme`.

---

## Boox Bridge additions (2026-11-13)

- Native semantic SF type via SwiftUI text styles; hierarchy through
  weight (`semibold` rows, `headline` sections, `bold` titles) rather than
  extra families. Rows follow SWIFTUI-RULES: `.lineLimit(1)` +
  `.truncationMode(.tail)`, monospaced digits for counters.
- Centralized metrics in `Theme.swift` (`Metrics`, `TypeStyles`): prose
  measure capped at 680pt (readable transcription column), consistent
  pane insets, bounded preview dimension.
- Semantic colors only (`.secondary`, `.tertiary`, `Color.accentColor`,
  system green/orange for device status) so light/dark stay native.
  No custom font loading.
- States are first-class: `ContentUnavailableView` for empty library /
  no-folder / listing failures, an always-visible device-status footer
  with actionable guidance (authorization, disconnection, ambiguity),
  and explicit OCR consent sheet. No fabricated progress percentages.
- Note: the `swiftui-pro` and `macos-design` skills were not registered
  during implementation; guidance came from `SWIFTUI-RULES.md`,
  `typography-designer`, and Apple HIG idioms (recorded in PROGRESS.md).
