# Lectern — Design Specification

**Platform:** macOS 26+ (SwiftUI, Liquid Glass). Built and tested on macOS 27 / Xcode 27.
**Audience:** engineers implementing SwiftUI views directly from this document.
**Status:** v1.0 — implementation-ready. Where a choice was possible, one was made.

---

## 0. The one-paragraph brief

Lectern sits open during a lecture and quietly turns speech + slides into a short, live, scannable list of *takeaways*. A distractible student who looks back at the screen after five minutes of drifting should be able to answer "what did I miss, and what is happening right now?" in under three seconds, without reading a transcript. Everything else in the app (transcript, slides, quizzes, Ask) exists to support that one moment. The design therefore optimizes for **one focal point per screen**, **stable layout** (nothing jumps), **quiet motion**, and **zero interruptions** — Lectern must never compete with the professor for attention.

### Design principles (rank-ordered; when they conflict, the higher one wins)

1. **Calm.** No sound by default, no modal alerts during a session, no layout shifts, no busy gradients. Motion is slow, springy, and rare.
2. **One thing at a time.** Each screen has exactly one primary surface. In the live session that is the Takeaways column. Everything else is dimmer, smaller, or collapsible.
3. **Stable ground.** Timestamps, slide numbers and card positions never move once settled. Streaming content only ever appends or refines *in place*.
4. **Native first.** System text styles, semantic colors, system materials, standard toolbar/sidebar/inspector. If a control exists in macOS, use it. Custom chrome is reserved for the four Lectern-specific objects (Takeaway card, Quiz card, Now card, Focus panel).
5. **Glass is for what floats.** Liquid Glass is applied only to the layer that floats above content (toolbar, pills, the docked Now card, quiz ping, Focus panel). Content itself is always opaque and readable.
6. **Keyboard complete.** Every action has a shortcut; every list is arrow-navigable.

---

## 1. Name, icon, accent

**Name:** Lectern. (A lectern is the thing the lecture comes *from*; the app is the student's own lectern — a place to stand and take it in.)

**App icon concept (macOS 26 layered icon, Icon Composer):**
- Background: a rounded-square gradient, top-left `#6C70FF` → bottom-right `#4448D8` (Lectern Indigo, slightly deeper at the bottom), with the standard macOS 26 glass specular layer.
- Foreground glyph (white, SF-Symbol-weight strokes, Medium weight, ~62% of icon width): a **lectern silhouette** — a slanted trapezoid reading surface on a slim vertical stem with a small flared base — drawn as a single continuous outlined shape. To the right of the reading surface, **three short horizontal bars of decreasing length** (like `text.alignleft` at 3 lines), suggesting both "notes" and "speech being written down". The glyph reads at 16 pt in the menu bar as "podium + lines".
- Custom SF Symbol `lectern.custom` (exported from the same glyph, all three scales, monochrome + hierarchical variants) is used for the menu bar extra, the empty state, and onboarding hero. Fallback if the custom symbol isn't ready: `music.mic` is *not* acceptable (too "karaoke"); use `text.book.closed` for placeholders.

**Accent color — Lectern Indigo:**

| Appearance | Hex | Use |
|---|---|---|
| Light | `#5B5FEF` | Tint for buttons, selection, links, current-slide ring |
| Dark | `#7F82FF` | Same, lifted for contrast on dark surfaces |
| Increased Contrast light | `#3E42D6` | |
| Increased Contrast dark | `#9A9CFF` | |

Set via `Color("AccentColor")` in the asset catalog (Global Accent Color Name = `AccentColor`). The app **respects the user's system accent** when it is not "Multicolor" — this is a first-party-app trait; we only ship indigo as the multicolor default.

Reserved semantic colors (never reused for anything else):
- **Recording red** — `Color.red` (system). Only the live dot and the Stop button.
- **Correct green** — `Color.green` (system). Only quiz results.
- **Needs-review orange** — `Color.orange` (system). Only quiz results. (Never red for "wrong" — red means "recording".)
- **Warning yellow** — `Color.yellow` (system). Only for non-fatal banners.

---

## 2. Information architecture & scenes

### 2.1 Navigation model

```
Main window (WindowGroup "main")
└── NavigationSplitView
    ├── Sidebar (Library navigation)
    │     All Lectures · Courses (list) · [footer: ModelStatusBadge]
    └── Detail (one of)
          ├── LibraryView          (grid of lectures, grouped by course, searchable)
          ├── SetupView            (pre-lecture)          ← pushed from LibraryView
          ├── LiveSessionView      (.live mode)           ← replaces SetupView on Start
          └── LiveSessionView      (.review mode)         ← opened from a Library card
                └── .inspector(): Transcript | Ask | (Quiz, review only)
```

There is **one session view** (`LiveSessionView`) with a `mode: .live | .review` enum. Review is not a separate screen; it is the same layout with recording controls swapped for review controls. This halves the UI surface and guarantees the student's spatial memory carries over from lecture to review.

The sidebar is **collapsed automatically** when a live session starts (`columnVisibility = .detailOnly`) and restored to its previous state on finish. During a session the user can still open it with `⌃⌘S` (system) — it overlays as the standard floating glass sidebar on macOS 26.

### 2.2 Scenes

| Scene | Type | Notes |
|---|---|---|
| `main` | `WindowGroup` | Default 1280×800, min 720×520. Single instance (`handlesExternalEvents` restricted; a second window is allowed for review only — `⌘⇧N` "New Window" opens a second review window; a live session may only exist in one window). |
| `settings` | `Settings` | Standard `⌘,`. 620 pt wide, content-sized height. |
| `focus` | `Window("Focus", id: "focus")` | The floating mini panel. `.windowLevel(.floating)`, `.windowStyle(.plain)`, `.windowResizability(.contentSize)`, `.windowBackgroundDragBehavior(.enabled)`, `.restorationBehavior(.disabled)`, `.defaultWindowPlacement` top-trailing of the main screen with 20 pt inset. **Needs AppKit bridging** — see §12: non-activating panel + join-all-Spaces. |
| `onboarding` | `Window("Welcome to Lectern", id: "onboarding")` | 560×640 fixed. Shown on first launch instead of `main`; closes into `main`. |
| `menubar` | `MenuBarExtra` | `.menuBarExtraStyle(.menu)`. Enabled by default only *while a session is live* (`isInserted` bound to session state and a General setting). |

### 2.3 URL scheme (internal navigation only)

`lectern://session/<uuid>/slide/<n>` and `lectern://session/<uuid>/t/<seconds>` — used by inline citation links in Ask answers and Takeaway cards. Handled through `.environment(\.openURL, OpenURLAction { ... })` at the `LiveSessionView` level, so *any* `Text` with a link attribute becomes a working citation with no custom layout code.

---

## 3. Design tokens (`DesignSystem.swift`)

Paste as-is. Everything else in this document references these names.

```swift
import SwiftUI

enum DS {

    // MARK: Spacing (4-pt base scale). Only these values appear in layout code.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let s:   CGFloat = 8
        static let m:   CGFloat = 12
        static let l:   CGFloat = 16
        static let xl:  CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let huge: CGFloat = 40
        /// Inset of floating glass objects from the edge of their container.
        static let floatInset: CGFloat = 12
    }

    // MARK: Corner radii. Nested radii follow (outer − padding).
    enum Radius {
        static let chip: CGFloat = 6      // chips, small badges
        static let control: CGFloat = 8   // thumbnails, text fields, small buttons
        static let card: CGFloat = 12     // takeaway cards, list cards
        static let float: CGFloat = 16    // docked Now card, quiz card, banners
        static let panel: CGFloat = 20    // Focus panel, onboarding sheet
        static let pill: CGFloat = 999    // capsules
    }

    // MARK: Layout widths (points)
    enum Layout {
        static let windowMin = CGSize(width: 720, height: 520)
        static let windowDefault = CGSize(width: 1280, height: 800)
        static let sidebar = (min: 200.0, ideal: 240.0, max: 320.0)
        static let slidesColumn = (min: 200.0, ideal: 240.0, max: 320.0)
        static let takeawaysMin: CGFloat = 420
        static let inspector = (min: 300.0, ideal: 340.0, max: 480.0)
        static let readingMaxWidth: CGFloat = 640  // transcript & summary text measure
        /// Live layout breakpoints, measured on the detail column's width.
        static let threeColumnMin: CGFloat = 1180
        static let twoColumnMin: CGFloat = 860
        static let focusPanel = CGSize(width: 340, height: 160)
        static let focusPanelWithQuiz = CGSize(width: 340, height: 248)
        static let settingsWidth: CGFloat = 620
    }

    // MARK: Motion. Reduce Motion handling lives in `DS.Motion.resolve(_:)`.
    enum Motion {
        /// Cards settling, columns resizing, expand/collapse.
        static let settle = Animation.spring(duration: 0.45, bounce: 0.15)
        /// Small UI: pills appearing, chips, hover states.
        static let quick = Animation.spring(duration: 0.28, bounce: 0.20)
        /// Floating objects entering (quiz card, banners).
        static let float = Animation.spring(duration: 0.40, bounce: 0.25)
        /// Text refinement crossfade (Now card title/summary morph).
        static let morph = Animation.smooth(duration: 0.35)
        /// Numeric counters (elapsed time, counts).
        static let numeric = Animation.snappy(duration: 0.25)
        /// Fallback when Reduce Motion is on: a plain fade.
        static let reduced = Animation.easeInOut(duration: 0.18)

        static func resolve(_ a: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? reduced : a
        }
        /// Live dot pulse period; disabled under Reduce Motion.
        static let livePulsePeriod: Double = 1.2
    }

    // MARK: Colors. Semantic first; named assets only where the system has no equivalent.
    enum Colors {
        static let accent = Color.accentColor
        static let recording = Color.red
        static let correct = Color.green
        static let review = Color.orange
        static let warning = Color.yellow

        /// Canvas behind content in the detail column.
        static let canvas = Color(nsColor: .windowBackgroundColor)
        /// Opaque card surface. Asset: light #FFFFFF, dark #26262A.
        static let surface = Color("Surface")
        /// Slightly raised surface (expanded card, hovered row). Asset: light #FFFFFF, dark #2E2E33.
        static let surfaceRaised = Color("SurfaceRaised")
        /// 1-pt hairline around cards. Asset: light #000000 @ 8%, dark #FFFFFF @ 10%.
        static let hairline = Color("Hairline")
        /// Volatile (in-progress) transcript text.
        static let volatileText = Color.secondary
        /// Search-hit highlight. Asset: light #FFE066 @ 55%, dark #FFD60A @ 30%.
        static let searchHit = Color("SearchHit")

        /// Course colors: index = courseColorIndex % 8.
        static let course: [Color] = [.indigo, .teal, .orange, .pink, .green, .purple, .brown, .cyan]
    }

    // MARK: Typography. System text styles only; sizes shown for reference (macOS default).
    enum Type {
        static let largeTitle = Font.largeTitle          // 26 pt
        static let title      = Font.title               // 22 pt
        static let title2     = Font.title2              // 17 pt
        static let title3     = Font.title3              // 15 pt
        static let headline   = Font.headline            // 13 pt semibold
        static let body       = Font.body                // 13 pt
        static let callout    = Font.callout             // 12 pt
        static let subheadline = Font.subheadline        // 11 pt
        static let footnote   = Font.footnote            // 10 pt
        static let caption    = Font.caption             // 10 pt
        /// Timestamps, slide numbers, elapsed time. Always monospaced digits.
        static let mono       = Font.system(.caption, design: .monospaced).monospacedDigit()
        static let monoBody   = Font.system(.body, design: .monospaced).monospacedDigit()
        /// Transcript reading text: body with relaxed leading.
        static let transcriptLineSpacing: CGFloat = 4
        static let summaryLineSpacing: CGFloat = 2
    }

    // MARK: Sizes of recurring glyphs
    enum Size {
        static let liveDot: CGFloat = 8
        static let liveDotSmall: CGFloat = 6
        static let slideThumb = CGSize(width: 96, height: 54)     // 16:9 in lists
        static let slideThumbLarge = CGSize(width: 128, height: 72)
        static let cardThumb = CGSize(width: 64, height: 36)      // inside expanded takeaway
        static let iconButton: CGFloat = 28
        static let levelMeterHeight: CGFloat = 6
    }
}
```

### 3.1 Materials & glass rules

| Object | Treatment |
|---|---|
| Window toolbar, sidebar, inspector chrome | System default (Liquid Glass automatically). Do not override. |
| Takeaway cards, transcript, slide list, library cards | **Opaque** `DS.Colors.surface` + 1 pt `DS.Colors.hairline` stroke. Never glass, never material. |
| Docked Now card, Quiz card, error/notice banners | `.glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.float))`, grouped in one `GlassEffectContainer(spacing: DS.Space.m)` so they merge/split as they appear. |
| "Jump to live", "Resume following", "N new" pills | `.glassEffect(.regular.interactive(), in: .capsule)` |
| Primary buttons (Start, Finish & Summarize, Continue) | `.buttonStyle(.glassProminent)` |
| Secondary toolbar buttons | `.buttonStyle(.glass)` where they float over content; plain `.borderless` inside the system toolbar (the toolbar is already glass). |
| Focus panel | Whole window `.glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.panel))` |
| Setup hero (deck drop zone) | `.backgroundExtensionEffect()` on the first slide image behind the header so the deck "bleeds" softly under the toolbar. |

**Reduce Transparency:** the system swaps glass for an opaque tint automatically. Our only obligation: never place text directly over a slide image or transcript without a glass/opaque backing, so the fallback is readable.

---

## 4. Screens

Point values are for the default 1280×800 window unless stated. Every wireframe uses the same legend:

```
[Button]  (toggle)  <chip>  ●live-dot  ▒ image/thumbnail  ┈ divider  ⋯ overflow  ⌘ shortcut hint
```

### 4.1 Library (home)

**Purpose:** find a lecture or start a new one. Nothing else.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ ○○○ [⊟]        Lectern                       [🔍 Search lectures, transcripts…] [＋ New Lecture]│  ← toolbar (glass)
├──────────────┬─────────────────────────────────────────────────────────────────────────┤
│ 📚 All Lectures│                                                                        │
│              │  Recent                                                                  │
│ COURSES      │  ┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐ │
│ ● CS 421     │  │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ │
│ ● CS 374     │  │▒  slide 1 thumb   ▒│ │▒                   ▒│ │▒                   ▒│ │
│ ● MATH 415   │  │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ │
│              │  │ Type Inference      │ │ Parsing II          │ │ Eigenvalues         │ │
│              │  │ CS 421 · Tue Sep 23 │ │ CS 421 · Thu Sep 18 │ │ MATH 415 · Sep 17   │ │
│              │  │ 48 min · 14 takeaways · 6/8 ✓│ ...           │ │ ...                 │ │
│              │  └─────────────────────┘ └─────────────────────┘ └─────────────────────┘ │
│              │                                                                          │
│              │  CS 421 — Programming Languages & Compilers                        12 ▸  │
│              │  ┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐ │
│              │  │ ...                 │ │ ...                 │ │ ...                 │ │
│              │                                                                          │
│┈┈┈┈┈┈┈┈┈┈┈┈┈┈│                                                                          │
│ ● On-device  │                                                                          │
│   Ready      │                                                                          │
└──────────────┴─────────────────────────────────────────────────────────────────────────┘
```

**Sidebar** (`List(selection:)`, `.listStyle(.sidebar)`):
- Row "All Lectures" — `books.vertical`, always first.
- Section "Courses" (header uses the system sidebar section style). Each course: 8 pt colored dot (`DS.Colors.course[i]`) + course code (`headline`) + optional name on second line only in the tooltip. Badge: count of lectures (`.badge(count)`).
- Context menu on course: Rename, Change Color (submenu of 8 swatches), Delete Course… (this is the *only* destructive confirmation dialog in the app; it lists the number of lectures it contains).
- Footer (pinned, `safeAreaInset(edge: .bottom)`): `ModelStatusBadge` — see §5. Clicking opens Settings › Models.

**Detail** (`ScrollView` + `LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: DS.Space.l)])`):
- Optional "Recent" section (last 6 lectures across all courses) shown only when "All Lectures" is selected and ≥ 2 courses exist.
- One section per course, header: course code + full name (`title3`, primary) with count and a chevron; sections are collapsible (`DisclosureGroup` styled as a plain header; state persisted).
- **LectureCard** (240–300 × ~206 pt): thumbnail of slide 1 (16:9, `DS.Radius.control`, hairline stroke; placeholder = `doc.text` on `.quaternary` fill when no deck), title (`headline`, 1 line, truncated middle), meta line 1 (`subheadline`, secondary): course code · relative date ("Today", "Yesterday", "Tue Sep 23"), meta line 2 (`footnote`, secondary): "48 min · 14 takeaways · 6/8 correct" (quiz part omitted if no quizzes). Hover: card lifts to `surfaceRaised`, 1 pt hairline → accent at 40%, 150 ms. Selected/focused: 2 pt accent ring at 4 pt offset. Double-click or ↩ opens review; single click selects. Context menu: Open, Export ▸, Move to Course ▸, Delete….
- A lecture that is **still live** (crashed/backgrounded window reopened) shows a `LiveDot` before its title and "Recording · 42:18" in meta; clicking resumes the live view.

**Search** (`.searchable(text:placement: .toolbar)` with `.searchScopes`: All / Titles / Transcripts / Takeaways):
- Results replace the grid with a `List` of hits: lecture title (headline) → snippet (`body`, 2 lines, match highlighted with `DS.Colors.searchHit` background attribute) → row of chips: `<TimestampChip 14:32>` `<SlideChip 12>` `<course>`. ↩ opens the lecture at that timestamp (review mode, transcript scrolled and highlighted).
- Search is local, full-text (SQLite FTS5 over transcript paragraphs and takeaway text). Results stream in as typed; no spinner — an empty list says "No matches for “monad”" only after 250 ms of no results.

**Toolbar:** system sidebar toggle (leading) · title "Lectern" (principal, hidden when a course is selected → course code becomes `navigationTitle`, name becomes `navigationSubtitle`) · search field · `ToolbarSpacer(.flexible)` · **New Lecture** `.glassProminent`, `plus`, `⌘N`.

**Drag & drop:** dropping a PDF anywhere on the Library detail area opens Setup with the deck pre-loaded (`.dropDestination(for: URL.self)`; accept only `.pdf` UTType; the whole detail area shows a 2 pt dashed accent ring inset 12 pt while a valid drag hovers).

**Empty states** (`EmptyStateView`, see §5):
- No lectures at all: glyph `lectern.custom` (48 pt, `.secondary`), title "No lectures yet" (`title2`), body "Start a lecture, or drop a slide deck here to set one up." (`body`, secondary, max 320 pt), button "New Lecture" `.glassProminent`.
- Course with no lectures: "Nothing in CS 374 yet" + "New Lecture in CS 374".
- Search with no results: `magnifyingglass`, "No matches", no button.

### 4.2 Pre-lecture Setup

**Purpose:** get the deck in, confirm the mic, press Start. Target: ≤ 10 seconds when the PDF is at hand. Layout is a single centered column, `maxWidth: 720`, vertically centered when it fits, otherwise a scroll view.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ○○○ [⊟]  ‹ Library        New Lecture                                                 │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                       │
│              ┌───────────────────────────────────────────────────────────┐            │
│              │ Course     [ CS 421 — Programming Languages ▾ ]           │            │
│              │ Title      [ Type Inference                          ]  ✦ │  ← ✦ = suggested from PDF
│              └───────────────────────────────────────────────────────────┘            │
│                                                                                       │
│              ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐              │
│                          ▒▒▒▒▒▒▒▒▒▒▒▒                                                 │
│              │        ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                              │              │
│                     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                    (deck fans in here)   │
│              │      ▒▒  Type Inference  ▒▒                           │              │
│                     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                            │
│              │       lecture07-typeinf.pdf · 42 slides · 3.1 MB      │              │
│                          [ Replace… ]   Indexed 42 of 42 ✓                            │
│              └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘              │
│                                                                                       │
│              ┌───────────────────────────────────────────────────────────┐            │
│              │ 🎤 MacBook Pro Microphone ▾      ▮▮▮▮▮▮▮▮▯▯▯▯▯▯▯▯▯▯▯▯      │  ← live level meter
│              │ ● On-device · Parakeet ready · Summaries: Qwen 3 4B warm  │  ← ModelStatusBadge (expanded)
│              └───────────────────────────────────────────────────────────┘            │
│                                                                                       │
│                                 [ ● Start Lecture   ⌘↩ ]                              │
│                                                                                       │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Section 1 — Course & Title** (`Form`-like group, `surface` card, `DS.Radius.card`, padding `DS.Space.l`):
- Course: `Picker` (menu style) listing courses + "New Course…" (inline sheet: code, name, color swatches; ↩ creates). Defaults to the course of the most recent lecture, or the one selected in the sidebar.
- Title: `TextField`, `title3`. When a PDF is dropped, the app extracts the first page's largest text run; if the field is empty or still the auto-generated default ("Lecture 7"), it fills in with `.contentTransition(.opacity)` and a `sparkles` glyph (accent, `caption`) appears at the trailing edge for 4 s, tooltip "Suggested from the slide deck". Never overwrites user-typed text.

**Section 2 — Slide deck (the delightful step)**:
- **Empty:** a 2 pt dashed `.quaternary` rounded rect (`DS.Radius.float`), 200 pt tall, centered: `doc.richtext` 36 pt `.secondary` → "Drop the slide deck here" (`title3`) → "PDF · or [Choose…]" (`subheadline`, secondary; "Choose…" is a link-style button → `fileImporter`). Hover with a valid PDF drag: dash becomes solid accent, background accent at 6%, glyph `symbolEffect(.bounce)` once.
- **Drop → fan-in:** the first 5 pages render as thumbnails (`PDFPage.thumbnail(of:for:)`, 128×72) and animate from the drop point into a fanned stack (rotation −8°, −4°, 0°, 4°, 8°; offsets 12 pt), each staggered 40 ms, `DS.Motion.float`. Under Reduce Motion: thumbnails fade in already fanned.
- **Indexing:** below the fan, `footnote` secondary: filename · "42 slides" · size; then a thin `ProgressView(value:)` (accent, 2 pt tall, full width of the card) with label "Indexing slides… 17 of 42" using `.contentTransition(.numericText())`. Indexing = text extraction + thumbnail cache per page (Vision OCR only for image-only pages, flagged "Reading 6 image slides…"). On completion the bar fades out and the label becomes "Indexed 42 slides ✓" with `checkmark.circle.fill` `.symbolEffect(.bounce)` once, `DS.Colors.correct`.
- **Loaded:** [Replace…] and a small ⓧ to remove. Clicking the fan opens a `QuickLook`-style popover grid of all pages (`LazyVGrid`, 96×54 thumbs) — just a preview.
- Deck is optional; Start is never blocked by a missing deck, but the hint "No deck — slide following and slide citations will be off" appears in `footnote` under the drop zone.

**Section 3 — Input & models** (`surface` card):
- Mic row: `mic.fill` + `Picker` of `AVCaptureDevice` inputs (menu style). Trailing: `LevelMeter` (§5), 160 pt wide, live from the moment the view appears (audio engine warm-up happens here, not on Start — Start is instant).
- Model row: `ModelStatusBadge` expanded variant: dot + engine + summarizer status. States: **Ready** (green dot), **Warming up…** (accent dot pulsing, `waveform` `.variableColor.iterative`), **Downloading 62%** (progress ring 14 pt), **Cloud** (`cloud.fill`, provider name), **Unavailable** (yellow `exclamationmark.triangle` + "Open Settings").
- Mic permission not granted: this row becomes a yellow notice: "Lectern needs microphone access" [Allow…] (calls `AVCaptureDevice.requestAccess`), or "Open System Settings" if previously denied. Start stays enabled but becomes "Start without audio" (transcript will be empty; useful only for slide-only review) — actually **disable Start** in this case; a session without audio has no value. Show the notice prominently.

**Start button:** `.glassProminent`, `controlSize(.extraLarge)`, label "Start Lecture" with a `LiveDot` (static, 8 pt, red) leading. `⌘↩` (`.keyboardShortcut(.defaultAction)`). Pressing it: the button's dot begins pulsing; the whole setup card cross-fades into `LiveSessionView` (`DS.Motion.settle`); the fanned thumbnails fly to the Slides column via `matchedGeometryEffect(id: "deck", in: sessionNamespace)` (Tier-2 delight; skip under Reduce Motion or if it takes more than a day).

**Back:** `‹ Library` in the toolbar (system back). Drafted setup (course/title/deck) is retained in memory until the app quits so an accidental back doesn't lose the deck.

**Error states:**
- Unreadable/encrypted PDF: drop zone shakes 3 px (`symbolEffect(.wiggle)` on the glyph under macOS 26, else 2 offset keyframes), label "Couldn't read that PDF" + "Try another file". Never a modal.
- Deck > 300 pages: accept, warn "Large deck — indexing may take a minute" and keep going.

### 4.3 Live Session — layout decision

**Decision: a "one primary column + two supporting columns" layout — Slides (left, 240 pt) | Takeaways (center, flexible, primary) | Transcript/Ask inspector (right, 340 pt) — with the two supporting columns independently collapsible.**

Why this and not the alternatives:

- *Three equal columns (Slides | Transcript | Takeaways)* puts the transcript — a noisy, fast-moving stream — in the center of the student's field of view. The transcript is *evidence*, not the answer; reading it live is exactly the behavior we want to discourage. It belongs in the periphery.
- *Two columns + inspector with Takeaways as a sidebar* under-weights the app's core artifact. Cards need width (~480–640 pt) to show a title + two-line summary without wrapping into a wall.
- *Tabs* hide state and force switching; a distracted student returning to the screen should not have to remember which tab is which.

So: the eye lands in the center on Takeaways. Peripheral vision catches the current slide on the left (matches the projector at the front of the room) and the transcript scrolling on the right (reassurance that it is listening). Both peripheral columns can be hidden in one keystroke, leaving a single clean column — the recommended state for most of the lecture.

**Responsive behavior** is driven by the *detail column width* (`onGeometryChange`), not the window, because the sidebar or a split-screen neighbor can eat width:

| Detail width | Layout |
|---|---|
| ≥ 1180 | Three regions as above. Inspector uses `.inspector(isPresented:)` and remembers its state. |
| 860–1179 | **Two regions:** Takeaways + inspector. Slides column collapses to a **current-slide chip** in the Takeaways header ("<▒ Slide 12>", tap → popover with the large slide + thumbnail strip) and a `⌘3` popover. |
| < 860 | **Single region** with a segmented control in the toolbar principal slot: `Takeaways · Transcript · Slides` (`⌘1/2/3`). Inspector is force-closed. A one-time tip suggests the Focus panel (`⌘⇧F`). |

Transitions between tiers animate with `DS.Motion.settle`; the current-slide chip and the slides column share a `matchedGeometryEffect(id: "currentSlide")`.

Below 720 pt window width the window simply won't go there (`windowMin`).

### 4.4 Live Session — wide layout (≥ 1180)

```
┌────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ○○○ [⊟]  Type Inference                            ⟦ ● 42:18 ⟧  [⏸] [■]   ┃   [⌘K Ask] [⧉ Focus] [◫]     │
│          CS 421 · Tue Sep 23                                                                              │
├──────────────┬──────────────────────────────────────────────────────┬──────────────────────────────────┤
│ SLIDES  (⚙ Auto)│ TAKEAWAYS                       ⌇ Summarizing…      │ Transcript  Ask        [🔍]     │
│ ┌──────────┐ │                                                      │                                  │
│ │▒▒▒▒▒▒▒▒▒▒│ │  ┌──────────────────────────────────────────────┐    │ 38:02  …so the constraint set   │
│ │▒ slide 12▒│ │  │ Hindley–Milner overview         14:02–18:40  │    │ is what we solve. Unification  │
│ │▒▒▒▒▒▒▒▒▒▒│ │  │ Types are inferred by generating constraints │    │ takes two types and finds the  │
│ └──────────┘ │  │ and unifying them; no annotations needed.    │    │ most general substitution…     │
│ 12 of 42     │  │ <Slides 9–11>                                │    │                                  │
│ ┈┈┈┈┈┈┈┈┈┈┈┈ │  └──────────────────────────────────────────────┘    │ 39:41  Let's look at the occurs │
│ ▒▒ 10        │  ┌──────────────────────────────────────────────┐    │ check. Suppose you try to unify │
│ ▒▒ 11        │  │ Unification algorithm           18:40–31:15  │    │ alpha with a list of alpha —    │
│ ▒▒ 12 ◀      │  │ Walks both types, binds variables, fails on  │    │ that would give you an infinite │
│ ▒▒ 13        │  │ mismatched constructors. Substitutions compose.│   │ type, so we…                    │
│ ▒▒ 14        │  │ <Slides 12–14> ✓ quizzed                      │    │                                  │
│ ▒▒ 15        │  └──────────────────────────────────────────────┘    │ 41:07  Now generalization. Once │
│ ▒▒ 16        │  ┌──────────────────────────────────────────────┐    │ we've solved for a let-bound    │
│ ▒▒ 17        │  │ Occurs check                     31:15–38:50 │    │ variable we can quantify over   │
│   ⋮          │  │ Prevents infinite types by refusing to bind  │    │ any type variables that don't   │
│              │  │ α to a type containing α. …                  │    │ appear in the env̲i̲r̲o̲n̲m̲e̲n̲t̲ ̲f̲r̲e̲e̲…  │  ← volatile (shimmer)
│              │  └──────────────────────────────────────────────┘    │                                  │
│              │                                       ⟦ ↓ Jump to live ⟧ │            ⟦ ↓ Jump to live ⟧ │
│              │ ╔══════════════════════════════════════════════╗    │                                  │
│              │ ║ ● NOW · 3 min                                 ║    │                                  │
│              │ ║ Let-polymorphism & generalization             ║    │                                  │
│              │ ║ Let-bound variables get generalized types;    ║    │                                  │
│              │ ║ lambda-bound ones stay monomorphic…           ║    │                                  │
│              │ ╚══════════════════════════════════════════════╝    │                                  │
└──────────────┴──────────────────────────────────────────────────────┴──────────────────────────────────┘
   ╔═╗ = glass (floating)      ┌─┐ = opaque card
```

#### Toolbar (unified, `.toolbar`)

Leading → trailing:
1. System sidebar toggle.
2. **Principal:** `navigationTitle(lecture.title)` + `navigationSubtitle("\(course.code) · \(date)")`. Title is editable in review mode (`.navigationTitle($title)`), read-only live.
3. `ToolbarSpacer(.flexible)`.
4. **Session group** (`ToolbarItemGroup`): 
   - `SessionClock` — a capsule (glass, interactive) containing `LiveDot` (pulsing red) + elapsed `mm:ss` (`DS.Type.monoBody`, `.contentTransition(.numericText(countsDown: false))`, updated once per second). Paused: dot becomes `pause.fill` in `.secondary`, capsule label "Paused · 42:18", time stops. Clicking the capsule toggles pause.
   - **Pause/Resume** — `pause.fill` / `play.fill`, `⌘⇧P` (also Space when no text field is focused). 
   - **Stop** — `stop.fill` tinted `DS.Colors.recording`, `⌘.`. Opens a **popover** (not an alert) anchored to the button: "Finish this lecture?" (`headline`) / "Recording stops and Lectern writes the final summary." (`subheadline`, secondary) / [Keep Going] [Finish & Summarize `.glassProminent`]. ↩ = Finish, Esc = Keep going. The popover dismisses on outside click; nothing is blocked.
5. `ToolbarSpacer(.fixed)`.
6. **Tools group**: 
   - **Ask** — `sparkle.magnifyingglass` (fallback `text.bubble`), `⌘K` / `⌘L`. Opens the inspector on the Ask tab and focuses the field.
   - **Focus panel** — `rectangle.inset.topright.filled` (`⌘⇧F`). Toggles the floating panel; button shows selected state while open.
   - **Inspector toggle** — system `sidebar.trailing` (`⌘⌥I`).
   - Overflow `ellipsis.circle` (`Menu`): Show/Hide Slides `⌘⌥S`, Follow Slides (checkmark), Quiz frequency ▸ (Off / 5 / 10 / 15 / 20 min), Export… (review only), Lecture Info….

**Model activity** lives in the Takeaways column header, not the toolbar, so it never competes with the recording state: `footnote` secondary text with a leading `waveform` symbol running `.symbolEffect(.variableColor.iterative.reversing, isActive: isBusy)`. Copy: "Listening", "Summarizing…", "Writing quiz…", "Answering…", "Paused". Text changes with `.contentTransition(.opacity)`. If two things run at once, show the one that started last.

#### Slides column (240 pt, left)

- Header row (28 pt): "SLIDES" (`caption`, `.secondary`, uppercase tracking 0.5) · trailing `Toggle("Auto", isOn: $follow)` rendered as a small capsule button with `scope` symbol (`.buttonStyle(.accessoryBar)`). On = accent filled.
- **Current slide** (width − 2·`Space.l`, aspect from the page, max height 160 pt): `Image`, `DS.Radius.control`, hairline stroke, plus a 2 pt accent ring when following. Caption below (`DS.Type.mono`, secondary): "12 of 42". Click → opens the slide full-size in a **popover** (max 900×600) with ←/→ paging; Esc closes. Never a sheet.
- Divider (`Space.m` above/below).
- **Thumbnail list** (`ScrollView` + `LazyVStack(spacing: Space.s)`, `scrollTargetLayout`, `.scrollPosition(id:)`): each row = 96×54 thumb + page number (`mono`, secondary) right-aligned. Current row: accent 2 pt ring, page number in accent. Rows the professor has already visited have a 1 pt `.quaternary` tick on the left edge (so "what's been covered" is visible at a glance). Auto-scroll keeps the current row in the middle third when following.
- **Manual override:** clicking any thumbnail (or ←/→ with the column focused) sets `follow = false` with `DS.Motion.quick`; a glass pill **"⟦ ↻ Resume following ⟧"** (`arrow.clockwise`) appears at the bottom of the column (`safeAreaInset`), `⌘⇧A`. Detection continues in the background, so the ring returns to the detected slide the moment the pill is clicked.
- **Slide detection UI:** when the detector changes slide, the ring moves with `matchedGeometryEffect(id: "slideRing")`, `DS.Motion.settle`. Confidence < threshold → ring becomes dashed and the caption reads "12 of 42 · unsure"; no other treatment.
- No deck: column shows `EmptyStateView` (compact): `doc.badge.plus`, "No slides", [Add Deck…] — adding mid-session is allowed and indexes in the background.

#### Takeaways column (center, primary)

- Header row (36 pt, `safeAreaInset(edge: .top)`, opaque canvas): "TAKEAWAYS" (`caption`, secondary, uppercase) + count badge ("6") + `ToolbarSpacer` + model activity label (above). In two-column tier the current-slide chip sits here too.
- **List:** `ScrollView` + `LazyVStack(spacing: Space.m)`, horizontal padding `Space.l`, content width clamps to `readingMaxWidth + 2·padding` and centers when the column is wider. `defaultScrollAnchor(.bottom)`. Cards are chronological, oldest at top.
- **Docked Now card** (`safeAreaInset(edge: .bottom)`, glass, `DS.Radius.float`, `floatInset` margins): always visible regardless of scroll. Contains the in-progress topic (§5 `TakeawayCard` `.live` state). When the topic settles: the Now card's content flies into a new opaque card at the bottom of the list (`matchedGeometryEffect(id: takeaway.id)`), and the dock refills with the next placeholder ("Listening for the next topic…", `subheadline` secondary, with three dots doing `.symbolEffect(.variableColor.iterative)` on `ellipsis`). The list auto-scrolls to reveal the new card if it was already at the bottom.
- **Auto-scroll rule (shared with transcript):** track `isPinnedToBottom` via `onScrollGeometryChange` (`contentOffset.y + containerSize.height >= contentSize.height − 40`). New content only scrolls when pinned. When unpinned and new content arrives, show the glass pill **"⟦ ↓ Jump to live ⟧"** (`arrow.down`, `⌘↓`) bottom-center of the scroll area, just above the Now card, with a count badge "2 new" after the second item. Clicking scrolls with `DS.Motion.settle` and re-pins.
- **Selection & keyboard:** ↑/↓ move a subtle focus ring between cards; ↩ / Space expands; Esc collapses; `⌘C` copies the card as Markdown. Only one card expanded at a time (expanding another collapses the first with the same animation).
- **Quiz card** appears here — see §4.6.
- **Empty (first minute):** the list is empty and the Now card reads "Listening…" with the level meter (compact, 80 pt) inline so the student sees audio is flowing. After 45 s of speech without a topic: "Still listening — first takeaway usually appears after a couple of minutes." Nothing else. No spinner.

#### Inspector (340 pt, right): Transcript | Ask

`.inspector(isPresented: $showInspector) { InspectorView() }.inspectorColumnWidth(min: 300, ideal: 340, max: 480)`. Header: a `Picker` (segmented, `.pickerStyle(.segmented)`, `controlSize(.small)`): **Transcript · Ask** (+ **Quiz** in review). `⌘2` Transcript, `⌘4` Ask. Trailing `magnifyingglass` button toggles the search field (`⌘F` while the inspector or main content is focused).

**Transcript tab**
- `ScrollView` + `LazyVStack(alignment: .leading, spacing: Space.l)`, `defaultScrollAnchor(.bottom)`, padding `Space.l`, text measure ≤ `readingMaxWidth`.
- **Paragraph** = a `HStack(alignment: .firstTextBaseline)`: `TimestampChip` gutter (48 pt wide, `mono`, `.tertiary`, right-aligned) + `Text` (`body`, `lineSpacing(transcriptLineSpacing)`, `.textSelection(.enabled)`). Paragraph breaks come from the segmenter (pause > 1.5 s or topic boundary) — never more than ~6 lines per paragraph.
- **Volatile text** (the in-progress hypothesis) is appended to the last paragraph as a separate `Text` run in `DS.Colors.volatileText` with a **shimmer**: a `TextRenderer` (macOS 15+) that animates per-glyph opacity 0.45→0.9 as a wave moving at ~80 pt/s, cheap because it only affects the last few words. When the segment is finalized the run turns `.primary` with `contentTransition(.opacity)` over 200 ms; words that changed (ASR revision) are not highlighted — revisions must be invisible, not flashy. Under Reduce Motion: volatile text is simply `.secondary` with no shimmer.
- Auto-scroll and "Jump to live" pill exactly as in Takeaways (`⌘↓` acts on whichever scroll view is focused; otherwise on both).
- **Timestamp click** → popover: slide thumbnail (128×72) + "Slide 12 · Unification" (`headline`) + the takeaway title covering that time (`subheadline`) + [Show slide] [Show takeaway]. Hover on a timestamp shows a tooltip with the absolute wall-clock time ("2:14 PM").
- **Search:** field appears with `DS.Motion.quick` under the segmented header (`TextField` `.textFieldStyle(.roundedBorder)` with `magnifyingglass`); hits get `DS.Colors.searchHit` background attribute; the current hit also gets a 1 pt accent underline. ↩ / ⇧↩ next / previous, count "3 of 17" trailing in `mono`. Esc clears and closes. Searching does not unpin auto-scroll until the user actually navigates to a hit.
- **Paused:** a centered `footnote` line "— Paused at 42:18 —" (secondary) is inserted; recording resumes below it.
- **Mic lost / silence:** if input RMS stays below the noise floor for 20 s while not paused, a compact glass banner (`GlassEffectContainer` at the top of the transcript) shows `mic.slash` "No audio detected" [Choose mic ▾]. Disappears itself when audio returns.

**Ask tab**
```
│ Transcript  [Ask]                [🔍] │
│ ┌──────────────────────────────────┐ │
│ │  What's the occurs check for?    │ │  ← user bubble (accent 12%, right-aligned, radius 12)
│ └──────────────────────────────────┘ │
│  The occurs check stops unification  │  ← answer: plain text, no bubble, streaming
│  from binding a variable to a type   │
│  that contains itself, which would   │
│  create an infinite type <Slide 13>  │
│  <34:12>.                            │
│  ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈ │
│  <▒ Slide 13>  <▒ Slide 14>  <34:12> │  ← citation row (real chips)
│                            [⧉] [👍👎] │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │ Ask about this lecture…       ↑ │ │  ← composer, glass, pinned bottom
│ └──────────────────────────────────┘ │
│   On-device · answers cite slides    │  ← footnote, secondary
```
- Composer: `TextField(axis: .vertical)` 1–4 lines, glass capsule when 1 line → rounded rect when multi-line, trailing send button `arrow.up.circle.fill` (accent, disabled when empty). ↩ sends, ⇧↩ newline, Esc clears. Placeholder rotates between three prompts once per session open: "Ask about this lecture…", "What did I miss in the last 5 minutes?", "Explain slide 12 simply".
- **Suggested prompts** (when the thread is empty): three glass chips: "Catch me up (last 5 min)", "Explain the current slide", "What's important so far?". These are the highest-value entry points for a distracted student; "Catch me up" is also `⌘⇧K`.
- **Streaming answer:** rendered from Markdown → `AttributedString`; tokens append to the last paragraph. A 6 pt accent caret (`▍`, blinking 1 Hz; static under Reduce Motion) sits at the end while streaming. Citations arrive as `[slide:13]` / `[t:2052]` tokens and are rendered as **link runs** (`.link = lectern://…`, accent color, `mono` for timestamps, no underline) so they are clickable inline; the same citations are collected into a **chip row** under the answer for large targets. Clicking a slide citation highlights that slide in the Slides column for 2 s (ring pulses once) and pauses follow *only if the user then pages*; clicking a timestamp switches the inspector to Transcript, scrolls to it, and flashes the paragraph background (accent 10% → 0 over 800 ms).
- Answer actions on hover: copy (`doc.on.doc`), thumbs up/down (stored locally for future prompt tuning). No regenerate button live (avoids compute contention); available in review.
- **Errors:** inline under the question in `footnote` with `exclamationmark.triangle` yellow: "Anthropic API: 401 — check your key in Settings › Models" [Open Settings] [Retry]. Local model OOM: "Not enough memory to answer while summarizing — try again in a moment" [Retry]. Never a modal.
- Thread is per-lecture and persists into review.

### 4.5 Live Session — narrower tiers

**Two-column (860–1179):**
```
┌───────────────────────────────────────────────────────────────────────────────┐
│ ○○○ [⊟]  Type Inference        ⟦ ● 42:18 ⟧ [⏸] [■]  ┃ [⌘K] [⧉] [◫]              │
├────────────────────────────────────────────────┬──────────────────────────────┤
│ TAKEAWAYS  <▒ Slide 12 ▾>       ⌇ Summarizing… │ Transcript  Ask       [🔍]   │
│ ┌────────────────────────────────────────────┐ │ 38:02 …so the constraint set │
│ │ …                                          │ │ is what we solve…            │
```
The `<▒ Slide 12 ▾>` chip (thumb 32×18 + label) opens a popover: current slide large (max 640 wide) + horizontal thumbnail strip + Auto toggle. ←/→ page while the popover is open.

**Single (< 860):**
```
┌──────────────────────────────────────────────────────┐
│ ○○○ [⊟]  ⟦ Takeaways │ Transcript │ Slides ⟧  ⟦●42:18⟧ [⏸][■] ⋯│
├──────────────────────────────────────────────────────┤
│ (one pane fills the width; Now card docked at bottom │
│  on the Takeaways pane; Ask lives under ⋯ / ⌘K as a  │
│  sheet-like overlay panel anchored to the bottom)    │
```
In single tier, Ask opens as an **overlay panel** (glass, 480 pt wide max, anchored bottom-center, 60% of height) over whichever pane is active; Esc closes. This is the only overlay-style Ask and only exists here.

### 4.6 Quiz pings

**Principle:** a quiz is an *invitation*, never an interruption. It cannot take keyboard focus away from a text field, cannot cover the transcript or the Now card, makes no sound, and stays until the user answers, skips or dismisses it.

**Placement:** a glass card inside the same `GlassEffectContainer` as the Now card, rising from behind it to sit directly above it (bottom of the Takeaways column, `floatInset` margins, same width as the Now card). Entry: `.transition(.move(edge: .bottom).combined(with: .opacity))`, `DS.Motion.float`. The container makes the two glass shapes bloom apart as it appears. Under Reduce Motion: fade only.

**Fallback placement** ("Quiet" quiz style in Settings › Quizzes, and always in single-column tier when the Transcript or Slides pane is active): a badge on a toolbar `questionmark.circle` item (`.badge(1)`) with a one-time `symbolEffect(.bounce)`; clicking opens the card as a popover from the button.

```
╔══════════════════════════════════════════════════════════╗
║ Quick check · Unification  +1 more          snooze  skip ║   ← header; "+1 more" only when questions are queued behind this one
║                                                          ║
║ What does the occurs check prevent?                      ║   ← title3
║                                                          ║
║  ⟦1⟧ Binding a variable to a type that contains it       ║   ← options: 4 rows, 36 pt, radius 8, key-cap glyph
║  ⟦2⟧ Applying a substitution twice                       ║
║  ⟦3⟧ Unifying two constructors with different arity      ║
║  ⟦4⟧ Generalizing a lambda-bound variable                ║
║                                                          ║
║                                    🔥 3 in a row         ║   ← streak, footnote, only if ≥ 2
╚══════════════════════════════════════════════════════════╝
╔══════════════════════════════════════════════════════════╗
║ ● NOW · 3 min   Let-polymorphism & generalization …      ║   ← Now card (compact while quiz is up)
╚══════════════════════════════════════════════════════════╝
```

**Behavior:**
- Trigger: every N minutes (default 10) *and* only when a topic has settled in the last N minutes (no quiz on silence), *and* not within 60 s of the previous quiz, *and* not while the user is typing in Ask. If blocked, retry in 60 s.
- Keys: `1–4` select (only when no text field has focus; the option row highlights immediately and submits after 150 ms — no separate confirm for MCQ), `↩` submit (short answer), `S` snooze 5 min, `Esc` skip. Mouse: click an option. Snooze/skip are `footnote` link-style buttons — deliberately small.
- **No timer.** A question stays until the user answers, snoozes, skips or dismisses it (✕ on a result); nothing counts down and nothing expires. A skip is recorded as skipped, never as wrong.
- **Queue:** a question that arrives while one is showing waits behind it (the header shows a quiet "+N more") and takes its place when the card closes. With the toolbar-badge style the queued questions wait for a click on the badge. Questions still queued when the lecture ends are dropped.
- The Now card compresses to a single line while a quiz is up so the pair never exceeds ~40% of column height. On a 14" screen with a 640-pt-tall content area the pair is ≤ 260 pt.
- **Short answer** variant: replaces options with a single-line `TextField` (glass), placeholder "Type a short answer…"; ↩ submits; grading is lenient (semantic) and explained.

**Result states** (same card morphs in place, `DS.Motion.settle`):

*Correct:*
```
╔══════════════════════════════════════════════════════════╗
║ ✓ Correct                                    🔥 4 in a row║   ← checkmark.circle.fill green, symbolEffect(.bounce) once
║ Binding a variable to a type that contains it            ║   ← chosen option, primary
║ Nice — that's exactly the infinite-type case.  <Slide 13>║   ← one line, secondary
╚══════════════════════════════════════════════════════════╝   ← stays until dismissed (✕ or Esc)
```
*Wrong:*
```
╔══════════════════════════════════════════════════════════╗
║ ↺ Not quite                                              ║   ← arrow.uturn.backward.circle.fill, orange (never red)
║ The occurs check refuses to bind α to a type that        ║   ← explanation ≤ 3 lines, grounded, cites
║ contains α, otherwise unification would build an         ║
║ infinite type.  <Slide 13>  <34:12>                       ║
║ ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈ ║
║ Try this one: which of these would FAIL the occurs check?║   ← follow-up question on same concept
║  ⟦1⟧ α ~ List α    ⟦2⟧ α ~ Int    ⟦3⟧ α ~ β    ⟦4⟧ Int ~ Int ║   ← compact 2×2 when options are short (< 18 chars)
╚══════════════════════════════════════════════════════════╝
```
The follow-up is generated *before* the explanation is shown (so there is no wait); if it isn't ready, the explanation shows alone with "Another question is on the way…" and the options fade in when ready. Only one follow-up per ping. A streak resets on wrong, not on skip.

**While a quiz is visible:** the takeaway that spawned it shows a small `questionmark.circle` in its footer; afterwards `checkmark.seal` (green) or `arrow.uturn.backward.circle` (orange) — this is how "missed concepts" surface in review.

### 4.7 Focus panel (floating mini window)

For when Notes/Obsidian/a terminal is in front. Shows exactly three things: that it's still recording, what the current takeaway is, and the quiz ping if one is up.

```
╔════════════════════════════════════════════════╗  340 × 160, radius 20, glass
║ ● 42:18  CS 421                     [⏸] [↗] [×]║  ← row 1 (28 pt): LiveDot + mono time + course code; controls appear on hover
║                                                ║
║ Let-polymorphism & generalization              ║  ← headline, 1 line
║ Let-bound variables get generalized types;     ║  ← subheadline secondary, 2 lines, morphs live
║ lambda-bound ones stay monomorphic.            ║
║                                                ║
║ ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈ ║
║ ◔ What does the occurs check prevent?          ║  ← quiz strip, only when a ping is active (panel grows to 248 pt)
║ ⟦1⟧ Binding α to a type containing α           ║
║ ⟦2⟧ …  ⟦3⟧ …  ⟦4⟧ …               snooze  skip ║
╚════════════════════════════════════════════════╝
```

- `Window` scene, `.windowStyle(.plain)`, `.windowLevel(.floating)`, no traffic lights; `×` closes (`⌘W`), `↗` (`arrow.up.left.and.arrow.down.right`) brings the main window forward. Drag anywhere (`windowBackgroundDragBehavior(.enabled)`); position persisted in `@AppStorage`.
- Opacity: 100% while hovered or when a quiz is up; idles to 85% after 5 s (so it recedes). Never below 85% — legibility.
- Height animates 160 ⇄ 248 with `DS.Motion.float` when a quiz appears/leaves.
- Keyboard 1–4/S/Esc work *only while the panel is key*. Because the panel must be **non-activating** (typing into Notes must not be interrupted when it appears), clicking an option is the primary path; the user can `⌘⇧F` from any app via a global hotkey (optional, see §12).
- Reduce Transparency: opaque `surface` with hairline.
- The main window's Takeaways column shows a small `rectangle.inset.topright.filled` in the header while the panel is open ("Focus panel open") so the state is discoverable.

### 4.8 MenuBarExtra (live only)

Icon: `lectern.custom` (template). While recording, a 5 pt red dot is composited at the bottom-right of the icon (render via `Image` overlay in `MenuBarExtra { } label: { }`); paused → dot becomes gray.

Menu:
```
● Recording — Type Inference · 42:18      (disabled, mono time updates every 1 s)
Now: Let-polymorphism & generalization    (disabled, truncated at 40 chars)
──────────────
Pause                                     ⌘⇧P
Finish Lecture…                           ⌘.
──────────────
Show Focus Panel                          ⌘⇧F
Open Lectern
──────────────
Settings…                                 ⌘,
```
"Finish Lecture…" from the menu bar opens the main window and shows the same Stop popover — it never finishes directly.

### 4.9 Post-lecture Review

Same `LiveSessionView` in `.review` mode. Differences only:

```
┌────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ○○○ [⊟]  Type Inference ✎                       ⟦ 48:12 · 14 takeaways · 6/8 ✓ ⟧   [⌘K Ask] [↑ Export ▾] [◫]│
│          CS 421 · Tue Sep 23                                                                              │
├──────────────┬──────────────────────────────────────────────────────┬──────────────────────────────────┤
│ SLIDES       │ TAKEAWAYS                                            │ Transcript  Ask  [Quiz]   [🔍]  │
│ ┌──────────┐ │ ┌──────────────────────────────────────────────┐    │                                  │
│ │▒ slide 1 ▒│ │ │ ✦ Lecture summary                             │    │   ◯ 6 / 8                        │  ← score ring 64 pt
│ └──────────┘ │ │ Hindley–Milner type inference: constraint     │    │   2 concepts to review           │
│ 1 of 42      │ │ generation, unification with the occurs check,│    │   [ Review missed concepts ]     │  ← glassProminent
│ ┈┈┈┈┈┈┈┈┈┈┈ │ │ let-polymorphism, and the value restriction.  │    │ ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈ │
│ ▒▒ 1  ◀      │ │ Key terms: <unification> <occurs check> <…>   │    │ ✓ 14:20  Constraint generation   │
│ ▒▒ 2         │ └──────────────────────────────────────────────┘    │ ✓ 24:05  Substitution order      │
│ ▒▒ 3         │ ┌──────────────────────────────────────────────┐    │ ↺ 34:40  Occurs check            │  ← orange = missed
│  ⋮           │ │ Hindley–Milner overview         14:02–18:40  │    │ ✓ 38:10  …                       │
│              │ │ …                                            │    │ – 44:00  Generalization (skipped)│
│              │ └──────────────────────────────────────────────┘    │                                  │
└──────────────┴──────────────────────────────────────────────────────┴──────────────────────────────────┘
```

- **Toolbar:** clock capsule becomes a static **stats capsule** (duration · takeaways · score, `mono` digits). Pause/Stop are gone. **Export** menu (`square.and.arrow.up`, `⌘E`): Markdown Notes… / PDF… / Copy Summary (`⌘⇧C`). Title is editable (click or `⌘⇧T` → inline `TextField`).
- **Summary card** at the top of Takeaways: generated at finish; `sparkles` glyph; overview paragraph (≤ 80 words) + "Key terms" chip row (`TermChip` — hover/popover shows the mini-definition). Chips are clickable → scroll to the first takeaway that defines the term.
- All takeaway cards are settled; Now card and quiz ping are gone; the dock at the bottom is removed. Cards keep their quiz markers.
- **Slides column:** same, but clicking a slide scrolls the transcript to the first time it was shown (bidirectional linking). Follow toggle hidden.
- **Inspector › Quiz tab:** score ring (`Circle().trim`, accent, 64 pt, `title2` numeric inside), "N concepts to review", the **Review missed concepts** button, then a list of every question with `checkmark.circle.fill` (green) / `arrow.uturn.backward.circle.fill` (orange) / `minus.circle` (secondary, skipped), timestamp (`mono`) and the concept name. Click → expands the row to show question, your answer, the explanation, and citations.
- **Review missed concepts flow:** replaces the Takeaways list (not a sheet) with a **card stack**: one concept at a time, centered, max 560 pt wide: header "1 of 2 · Occurs check", the takeaway's detailed summary, the explanation from the lecture, cited slide thumbnails, then a fresh question. Bottom bar: [Skip] ⟶ [Next] (`glassProminent`, ↩). Progress dots at the top. Finish screen: "All caught up" with `checkmark.seal.fill` (`symbolEffect(.bounce)`), [Back to lecture]. Esc exits at any time. Motion: cards slide horizontally with `DS.Motion.settle` (`.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))` + opacity).
- **Ask** works identically (thread persists). Regenerate is available here.
- **Audio playback:** not in v1: audio is never stored (the "Keep audio recordings" option was removed until retention is built and verified; see the 8 Oct 2026 audit, B05). Design for its absence.

**Export formats:**
- *Markdown:* H1 title, metadata line, "## Summary", "## Takeaways" (H3 per takeaway with time range, bullets, key terms as bold, `Slide 12` references), "## Quiz" (results table), "## Transcript" (`**14:02**` paragraphs). Slide references link to `slides/page-012.png` if "Include slide images" is checked in the save panel accessory.
- *PDF:* `ImageRenderer` over a print-styled `ExportDocumentView` (Letter, 48 pt margins, `body` 11 pt, mono timestamps in the margin). Same sections; slide thumbnails inline at 40% width beside their takeaway.

**Finishing transition (live → review):** on "Finish & Summarize" the recording controls fade, the Now card settles into the list like any other card, and a `ProgressView` line "Writing summary…" appears where the Summary card will be (its slot is reserved at full height with a `.redacted(reason: .placeholder)` version of a 3-line card so nothing jumps). When the summary streams in, the placeholder crossfades. Total expected time on M2 Max: 5–15 s. The Quiz tab and Export enable immediately; only the Summary card waits.

### 4.10 Settings (`⌘,`)

`Settings { TabView { … } }` — macOS renders toolbar-style tabs. Width 620. Each tab is a `Form` with `.formStyle(.grouped)`.

Tabs (order): **General** `gearshape` · **Transcription** `waveform` · **Models** `cpu` · **Quizzes** `questionmark.circle` · **Focus** `rectangle.inset.topright.filled`.

**General**
```
┌ Appearance ────────────────────────────────────────┐
│ Appearance            ( System │ Light │ Dark )    │
│ Show menu bar status while recording        (●  )  │
└────────────────────────────────────────────────────┘
┌ Storage ───────────────────────────────────────────┐
│ Location   ~/Library/Application Support/Lectern   [Change…] [Reveal] │
│ Used       1.4 GB · 23 lectures · 3 models          │
└────────────────────────────────────────────────────┘
┌ Privacy ───────────────────────────────────────────┐
│ 🔒 With on-device models selected, audio, slides    │
│    and transcripts never leave this Mac. Cloud      │
│    providers receive transcript excerpts and slide  │
│    text for the roles you assign them.              │
└────────────────────────────────────────────────────┘
```

**Transcription**
```
┌ Engine ────────────────────────────────────────────┐
│ Engine     (● Parakeet — on-device, Neural Engine ) │  ← radio group, each with a footnote description
│            (○ Apple Speech — on-device fallback   ) │
│ Status     ● Ready · 600 MB                         │
└────────────────────────────────────────────────────┘
┌ Microphone ────────────────────────────────────────┐
│ Input      [ MacBook Pro Microphone ▾ ]  ▮▮▮▮▮▯▯▯▯▯ │  ← LevelMeter live
└────────────────────────────────────────────────────┘
┌ Custom vocabulary ─────────────────────────────────┐
│ ┌────────────────────────────────────────────────┐ │
│ │ Hindley–Milner                                 │ │  ← editable List, ⌫ deletes, drag to reorder unnecessary
│ │ unification                                    │ │
│ │ lambda calculus                                │ │
│ └────────────────────────────────────────────────┘ │
│ [ + ] [ − ]         Import from slide decks…        │  ← pulls capitalized/rare terms from indexed decks
│ Words and names the transcriber should recognize.   │
└────────────────────────────────────────────────────┘
```

**Models** — the most complex tab. Two groups.
```
┌ Roles ─────────────────────────────────────────────┐
│ Summaries   [ On-device (MLX) — Qwen3 4B ▾ ]   ● Ready   │
│ Quizzes     [ On-device (MLX) — Qwen3 4B ▾ ]   ● Ready   │
│ Ask         [ Anthropic — Claude Sonnet ▾   ]   ● Key OK │
│ Each role can use a different provider. On-device keeps everything private. │
└────────────────────────────────────────────────────┘
┌ Providers ─────────────────────────────────────────┐
│ ▸ On-device (MLX)                                   │
│     ┌ Qwen3 4B (Q4)        2.6 GB   ● Installed  [Remove] ┐   ← download manager rows
│     │ Qwen3 8B (Q4)        5.0 GB   ⬇ 62%  ▬▬▬▬▬▬▬▬▬▬▬▬▯▯▯▯▯ [Pause] │
│     │ Gemma 3 4B           2.5 GB   [Download]              │
│     └ Parakeet TDT 0.6B    600 MB   ● Installed             ┘
│     Models live in Storage › Location. 8.2 GB free.         │
│ ▸ Local server (Ollama / LM Studio)                 │
│     URL    [ http://localhost:11434/v1        ]  [Test]  ● Reachable · 3 models │
│     Model  [ qwen3:8b ▾ ]                            │
│ ▸ OpenAI                                            │
│     API key  [ ••••••••••••••••••••  ]  [Test]   ● OK (gpt-4.1-mini)  🔑 Stored in Keychain │
│     Model    [ gpt-4.1-mini ▾ ]                      │
│ ▸ Anthropic                                         │
│     API key  [ •••••••••••••••••••• ]  [Test]   ● OK   🔑 Stored in Keychain │
│     Model    [ claude-sonnet-… ▾ ]                    │
└────────────────────────────────────────────────────┘
```
- Provider groups are `DisclosureGroup`s; open the ones in use by default.
- **Test connection** button: on click → `ProgressView` (small) replaces the status for ≤ 8 s → result: `checkmark.circle.fill` green "OK · 412 ms" or `xmark.circle.fill` orange with the first line of the error ("401 Unauthorized"). Result persists until the key changes.
- API key field is `SecureField`; a small `key.fill` + "Stored in Keychain" `footnote` appears once saved (saved on field commit, not on every keystroke). Paste works. Never echoed elsewhere.
- Download rows: `ProgressView(value:)` with `.contentTransition(.numericText())` on the percentage; Pause/Resume; on failure the row shows `exclamationmark.triangle` + "Retry". Downloads continue while Settings is closed; the Library sidebar footer badge mirrors progress.
- A role assigned to a model that isn't installed shows a yellow `exclamationmark.triangle` next to its picker with "Not downloaded — using Apple Speech / disabled" and a link to the row.

**Quizzes**
```
┌ Timing ────────────────────────────────────────────┐
│ Ask me a question every   [ 10 min ▾ ]   (5/10/15/20/Off)│
│ Style                     (● Card  ○ Toolbar badge only) │
└────────────────────────────────────────────────────┘
┌ Questions ─────────────────────────────────────────┐
│ Multiple choice                              (●  )  │
│ Short answer                                 (●  )  │
│ Difficulty            ( Easier │ Balanced │ Harder ) │
│ Follow up when I get one wrong               (●  )  │
│ Show streaks                                 (●  )  │
└────────────────────────────────────────────────────┘
```

**Focus**
```
┌ Focus panel ───────────────────────────────────────┐
│ Show on every screen (all Spaces)            (●  )  │
│ Dim when idle                                (●  )  │
│ Global shortcut         [ ⌘⇧F ]  (Record…)          │  ← optional, see §12
└────────────────────────────────────────────────────┘
```

### 4.11 Onboarding (first launch, 4 steps)

Window 560×640, `.windowStyle(.hiddenTitleBar)`, opaque `canvas`, content centered, page dots at the bottom (4 dots, 6 pt, accent for current), `Continue` `.glassProminent` (`↩`), "Skip" as a `footnote` link button bottom-left where allowed. Step transition: `.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))`, `DS.Motion.settle`. The hero glyph area (top 200 pt) uses `matchedGeometryEffect(id: "hero")` so the symbol morphs between steps rather than sliding.

```
Step 1 — Welcome                    Step 2 — Microphone               Step 3 — Models                     Step 4 — Cloud (optional)
┌──────────────────────┐            ┌──────────────────────┐          ┌──────────────────────┐            ┌──────────────────────┐
│                      │            │                      │          │                      │            │                      │
│      ⌐lectern⌐       │            │        🎤             │          │        ⬇ ◔           │            │        ☁ ⇄ 🔒          │
│                      │            │   ▮▮▮▮▯▯▯▯▯▯ (live)  │          │                      │            │                      │
│  Lectern listens so  │            │  Lectern needs your   │          │  Download the on-    │            │  Optional: cloud      │
│  you can look up.    │            │  microphone.          │          │  device models       │            │  models for Ask       │
│                      │            │                      │          │                      │            │                      │
│  Live takeaways from │            │  Audio is processed   │          │  ● Parakeet (speech) │            │  Anthropic  [key…][Test]│
│  every lecture, on   │            │  on this Mac and is   │          │    600 MB  ✓ done    │            │  OpenAI     [key…][Test]│
│  your Mac.           │            │  never stored; only   │          │  ● Qwen3 4B (summaries)│          │                      │
│                      │            │  the transcript is.   │          │    2.6 GB  ▬▬▬▬▯▯ 58% │            │  You can add these   │
│                      │            │                      │          │                      │            │  later in Settings.  │
│                      │            │  [ Allow Microphone ] │          │  3.2 GB · ~2 min on  │            │                      │
│                      │            │                      │          │  campus Wi-Fi         │            │                      │
│ ● ○ ○ ○  [Continue ↩]│            │ ○ ● ○ ○  [Continue ↩]│          │ ○ ○ ● ○  [Continue ↩]│            │ Skip   ○ ○ ○ ●  [Done ↩]│
└──────────────────────┘            └──────────────────────┘          └──────────────────────┘            └──────────────────────┘
```
- Step 2: "Allow Microphone" triggers the system prompt; on grant the meter animates live and Continue enables (Continue is *also* enabled if denied, with a `footnote` "You can grant access later in System Settings" — never trap the user).
- Step 3: downloads start automatically when the step appears (Wi-Fi only prompt is skipped — Macs). Continue is enabled immediately: "Continue while downloading" — the Library sidebar footer shows progress afterwards and Setup will show "Downloading 58%" in its model row. Estimated time uses measured throughput after 3 s.
- Step 4: key fields validate on Test only. Done closes onboarding and opens the main window at the empty Library.
- Onboarding is re-runnable from Help › "Welcome to Lectern".

### 4.12 "While you were away" (recap card)

Lectern notices when it stops being looked at during a live session: the app resigns active or the main window is occluded/not key for ≥ 90 s (Settings › General › "After being away for": 30 s / 1½ / 3 / 5 min; the feature can be turned off). When the user comes back, a **glass recap card** appears at the top of the Takeaways column, inside the normal scroll content (never a modal, never focus-stealing).

```
╔══════════════════════════════════════════════════════════════════╗
║ ◷ WHILE YOU WERE AWAY                Away 7 min · 14:02–21:10  × ║   ← caption header, mono range, close
║ FIRST sets → the LL(1) condition                                 ║   ← headline
║ • FIRST(α) is what a string derived from α can start with …      ║   ← 2–4 bullets, subheadline secondary
║ • …                                                              ║
║ ⚑ The LL(1) condition will be on the midterm                     ║   ← flagged items: yellow flag + 12% yellow chip
║ <Slides 7–12>                    Show in transcript   Dismiss    ║
╚══════════════════════════════════════════════════════════════════╝
```

- Data: `LectureIntelligence.recap(from:to:)`. While loading, the card shows a redacted 3-line placeholder with a shimmer (static under Reduce Motion); it is cancelled and removed if the user leaves again before it finishes. Failure shows one line of copy and the close button — never a retry loop.
- Entry `.move(edge: .top) + opacity`, `DS.Motion.float`. "Show in transcript" seeks the transcript to the start of the window; slide chips highlight the slides. Dismiss is explicit; the card never auto-hides while the user is present.
- Debug › "Simulate Being Away (3 min)" exercises it in demo mode.

### 4.13 Import a recording

**Entry points:** Library toolbar `New Lecture ▾ › Import Recording…` (`⌘⇧I`), File menu, or dropping an audio/video file on the Library. A 560-pt sheet:

```
Import Recording
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
│   ♒ Drop an audio or video file                     │
│   Choose… · From MediaSpace…                        │
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
   after a source is found:
│ ▶ Found: CS 421 · Lecture 8 — Parsing II   [Change] │
│ (●) Use MediaSpace captions (faster)                │
│ ( ) Transcribe on-device (more accurate)            │
┌ Course [CS 421 ▾]  Title [Parsing II]  Slides [Choose Slide Deck…] Optional ┐
                                     [Cancel] [Import ●prominent]
```

- "From MediaSpace…" opens an 860×620 sheet with the embedded browser (`MediaSpaceBrowserView`); the user signs in and opens a lecture; the sheet closes itself with "Found: <title>".
- Importing sessions appear in the Library immediately as an **ImportProgressCard**: thumbnail slot with the source glyph, title, "Importing", a thin accent progress bar, a staged row `✓ Downloading → ◌ Transcribing → ○ Summarizing` with the current stage's percentage in `mono`, and a `Cancel` link. Failure: `⚠` + first line of the error + Dismiss. When finished the card becomes a normal lecture card and the lecture opens in Review.
- Contracts: `RecordingImporting` / `ImportStage`; the session carries `source` (`.audioFile` / `.mediaSpace(usedCaptions:)`).

### 4.14 Course-wide Ask

A course knows all of its lectures. **Where:** sidebar course context menu "Ask CS 421…", the Library toolbar `sparkle.magnifyingglass`, `⌘⌥K`, and a **scope toggle** at the top of the session Ask tab: `This lecture · Whole course`.

- In the Library it is a 340-pt inspector: header "Ask CS 421" + lecture count, thread, glass composer, footnote "Answers cite lectures, slides and timestamps across the course". Three suggested prompts when empty ("What did he say about FIRST sets last week?", "What's most likely on the midterm?", "Catch me up on the last two lectures").
- Citations are `CourseCitation`s rendered inline as accent links **"Lecture 8 · Slide 12"** / **"Lecture 9 · 14:32"** and repeated as a chip row; hovering a chip shows the lecture title. Clicking opens that lecture in Review at the slide (highlighted in the Slides column) or at the timestamp (transcript scrolled + flashed).
- History persists per course (`store.loadCourseChat/saveCourseChat`); a trash button clears it. Uses `CourseAssisting`.

### 4.15 Speakers in the transcript

Diarization labels (`TranscriptionEvent.speakers`) arrive a few seconds after the text and are applied in place (`TranscriptSegment.speaker`); the paragraph builder also breaks paragraphs on speaker change, so a question is never merged into the lecturer's sentence.

- **Lecturer** text stays exactly as before (no label).
- **Audience** turns render as an indented bubble: `accent @ 7%` fill, `Radius.card`, 12 pt inset, with a small `person.fill` "Student" caption. The lecturer's paragraph that immediately follows an audience turn gets a `person.wave.2.fill` "Lecturer" caption, so a Q&A exchange reads as a pair. VoiceOver reads "…, student: …".
- Labels are forwarded to `brain.applySpeakers` so summaries can weight student questions differently.

### 4.16 PowerPoint / Keynote decks

The Setup drop zone and chooser accept `.pptx` and `.key` in addition to PDF when a `PresentationConverting` is available (copy: "PDF, PowerPoint or Keynote · or Choose…"). Dropping one shows a **"Converting with Keynote…"** state (glyph `doc.badge.gearshape`, small spinner, the original file name) before the normal indexing bar; the deck keeps its original name and presenter notes land in `SlidePage.notes`. If macOS Automation permission is missing the drop zone shows the converter's message ("Lectern needs permission to control Keynote. Allow it in System Settings › Privacy & Security › Automation, then try again.") with "Try another file · Choose…" — never a modal.

### 4.17 Interrupted sessions

On launch, any session still marked `.live`/`.paused`/`.importing` with no active model is *interrupted*. The Library shows a one-line glass banner ("A lecture was interrupted — resume it or finish it below.") and each such card gets a footer row: `⚠ Interrupted at 42:18   [Resume] [Finish]` (imports: `[Finish]` only). Resume picks recording back up in the same session (the clock continues from the last transcript time); Finish closes it and writes the summary, opening Review. The context menu adds "Discard…". Nothing happens automatically.

### 4.18 Slide following never moves backwards

Automatic slide detection only ever advances. When the brain believes the lecture went *back* (`BrainUpdate.backtrackSuggestion(n)`), the Slides column shows a calm glass pill at its bottom — `[▒] Back on slide 5? · Jump  ×` — with a 32×18 thumbnail. It never takes focus, never auto-accepts, and `nil` withdraws it. `Jump` (or `⌘[`) calls `brain.setCurrentSlide(n)` and moves the ring; any manual choice (thumbnail click, ←/→) also calls `setCurrentSlide`. As a belt-and-braces rule the app ignores any `.currentSlide(n)` with `n` lower than the current slide; only the user's own choices and accepted suggestions move backwards.

### 4.19 Course slides folder

Students keep a course's decks in one folder (`~/Documents/CS 426 Lecture Slides/lec1.pdf … lec9-ir-gen.pdf`). `Course.slidesFolder` points at it.

- **Setting it:** sidebar course context menu "Slides folder…", the course sheet (now "Edit Course": a "Slides folder" row with the folder name, a clear ⓧ and Choose…), or the link "Set a slides folder for CS 426…" under the empty drop zone in Setup. All use an `NSOpenPanel` limited to directories, opening at the current folder or ~/Documents.
- **Suggesting:** the folder is re-scanned whenever Setup opens or its course changes (no folder watching). Under the drop zone's "PDF · or Choose…" line: one **bordered** (not prominent — Start Lecture stays the only prominent button, §11.15) button "Use lec9-ir-gen.pdf" with `doc.richtext`, and a borderless "Other decks" menu listing the rest of the folder in lecture order. Picking either loads the deck exactly as a drop would. An unreadable folder shows one footnote line with ⚠ and "Change…".
- **Ranking (`DeckSuggester`, LecternStore):** candidates are `.pdf` / `.pptx` / `.key` (the latter two only when the converter is available). Lecture numbers come from the file name: `lec9…`, `lecture_10`, `L11`, `Lecture 12 - …`, a leading `09 - …`, and ranges like `lec2-3` (which mark lectures 2 and 3 used). The suggestion is the lowest-numbered deck after the highest lecture number used by an earlier session of the course (matched by the deck's original file name). With no numbered history, or nothing after it, the newest unused file by modification date wins (files modified within a minute of each other tie, and the higher lecture number wins the tie). A deck already used is never the prominent suggestion; it stays in the menu.

### 4.20 Course jargon fixed from the slides

Parakeet hears identifiers as words: "gen expression" for `genExpr`, "L are" for LR, "I lock" for ILOC, "load A0" for `loadAO`. When the session has a deck, each **final** segment is corrected before it reaches the brain, the store or the transcript view (imports: before the finished session is saved). Settings › Transcription › Slides: "Fix course jargon from slides" (on by default).

- **Vocabulary (`DeckVocabulary`, LecternSlides):** identifiers (camelCase, snake_case), acronyms (ALLCAPS, vowel-less lowercase like `llvm`, letters + a small number like `MP2`, `LL(1)`), Greek letters with the word the deck puts after them (φ-function → "phi" + "function"), and proper title phrases (Hindley–Milner). URLs, ALLCAPS words that are English (`PLUS`, `OR`), roman numerals and hex literals are skipped. Spoken forms split camel/snake parts, spell capitals as letters, expand the abbreviations lecturers read aloud (expr → expression, reg → register…), and compare phonetically (ph→f, c/ck/q→k).
- **Corrector (`TranscriptCorrector`):** replaces a run of up to six words whose spoken form matches a deck term, but only if it doesn't read as ordinary English: one word must be non-everyday ("gen", "reg", "a0"), or an acronym must be spelled letter by letter with a bare letter ("L are", "see F G"; never "I are", never a lone "x"). Everyday-word spans change in two narrow cases only: an acronym said as a word after a determiner or preposition ("the I lock instructions"; never "so I lock it"), and a Greek homophone before its deck collocate ("fee function" → "phi function"). Case-only fixes only capitalize ("cfg" → CFG, never "LLVM" → llvm or "IRs" → IRS). Spans don't cross sentence punctuation; at most 3 edits per segment. Known miss by design: "load I" (the lecturer also says "load I into a register" for the variable *i*).
- **Keeping what was heard:** `TranscriptSegment.originalText` holds the recognizer's words. In the transcript each corrected word gets a subtle **dotted underline** (`.secondary`); the paragraph's tooltip (`.help`) reads "Corrected from the slides. Heard: “gen expression” → genExpr". No other chrome.
- **Measured** on the real CS 426 lecture (`TestData/cs426-reference.txt`, 1,128 segments, with `lec9-ir-gen.pdf` OCR-ingested): 22 corrections, all judged correct (genExpr ×6, new_reg_name ×3, loadAO ×3, IR ×4, MP1/MP2 ×3, CFG ×3, ILOC ×1). With the previous lecture's deck instead, 10 corrections, all case fixes of acronyms both decks share.

### 4.21 API cost meter and monthly cap

Every cloud call (OpenAI, Anthropic) is metered; on-device and local-server calls are free and not recorded.

- **Ledger:** `MeteredProvider` (LecternLLM) records each call's `LLMUsage` + model into the `UsageLedger` actor: per calendar month (local time zone), per provider/model, with per-lecture totals (the brain's `BrainContext.sessionID`). Persisted as JSON at Application Support/Lectern/usage.json; an unreadable file is moved aside, never fatal. `LLMUsage.inputTokens` stays the whole prompt; `cachedInputTokens` (Anthropic `cache_read_input_tokens`, OpenAI `prompt_tokens_details.cached_tokens`) and `cacheWriteTokens` (Anthropic `cache_creation_input_tokens`) are parts of it.
- **Pricing:** `ProviderCatalog.pricing(for:model:)` — list prices per 1M input/output tokens from the catalog; cache reads 0.1× input (Anthropic, current OpenAI models; GPT-4.1 models 0.25×), cache writes 1.25× on Anthropic's 5-minute cache and 1× on OpenAI. Dated snapshots price as their base model; an unknown model is priced as the provider's most expensive listed model (so a cap is never under-counted) and flagged as an estimate.
- **Monthly cap:** optional, Settings › Models › Cloud spending: "Monthly cap" switch + a currency field (default $10 when first switched on). `CappedProvider` wraps each cloud role: once this month's spend reaches the cap, new calls go to the on-device model if one is downloaded (default model first), otherwise fail with `MonthlyCapReached` ("… Raise it in Settings › Models, or download the on-device model to keep going."), which the brain surfaces through its usual notice. The first capped call of a month posts one **info notice** in the lecture on screen (`dollarsign.circle`, Takeaways column): "This month's $10.00 API cap is reached. Cloud roles now use the on-device model." It never repeats that month; a raised cap applies to the very next call.
- **Settings › Models › Cloud spending** (between Roles and Providers; hidden in the demo): the month ("September 2026") with its total in `mono`, one row per provider · model (calls · tokens · % cached, cost in `mono` secondary), the cap row, a warning line when the cap is reached, and a footnote on how prices are computed.
- **Review:** the stats capsule appends the lecture's API cost ("· $0.042", `mono`, tooltip "Cloud API cost of this lecture") only when it is above zero, and updates as calls land (e.g. an Ask in review).

---

## 5. Component inventory

All components live in `Lectern/DesignSystem/Components/`. Props are listed as Swift-ish signatures; states as enums. Every component must render correctly in light/dark, Reduce Motion, Reduce Transparency, Increase Contrast, and at the largest Accessibility text size.

### LiveDot
`LiveDot(state: .recording | .paused | .idle, size: CGFloat = DS.Size.liveDot)`
- recording: `Circle().fill(DS.Colors.recording)` with a second circle behind it scaling 1→1.6 and fading 0.35→0 every `livePulsePeriod` s (`repeatForever(autoreverses: false)`). Reduce Motion: solid dot, no halo.
- paused: `.secondary` filled circle. idle: `.quaternary`.
- `accessibilityLabel`: "Recording" / "Paused" / "Not recording". Marked `accessibilityHidden` when adjacent text already says it (e.g. the clock capsule).

### SessionClock
`SessionClock(elapsed: Duration, state: SessionState, onToggle: () -> Void)` — glass capsule, `LiveDot` + `mono` time, `numericText` transition, 24 pt tall, `.glassEffect(.regular.interactive(), in: .capsule)`. VoiceOver: "Recording, 42 minutes 18 seconds. Double-tap to pause." Updates the accessibility value once per minute, not per second (avoids VoiceOver chatter).

### LevelMeter
`LevelMeter(level: Float /*0…1 RMS*/, peak: Float, width: CGFloat = 160)`
- 20 segments, 4 pt wide, 6 pt tall, 2 pt gap, `Radius.chip`; filled = `.accent` up to level, `.quaternary` beyond; peak segment holds for 800 ms (`.secondary`). Updates at 30 Hz via `TimelineView(.animation)`; clipped above 0.95 to a yellow segment (clipping hint). Reduce Motion: updates at 10 Hz, no peak hold.
- Accessibility: `accessibilityValue` "Input level 60 percent", `.updatesFrequently` trait.

### ModelStatusBadge
`ModelStatusBadge(status: ModelStatus, style: .compact | .expanded)`; `ModelStatus = .ready(engine:) | .warming | .downloading(progress:) | .cloud(provider:) | .unavailable(reason:)`
- compact (sidebar footer, 28 pt): dot (8 pt; green/accent/yellow) + one line `footnote` ("On-device · Ready", "Downloading 62%", "Anthropic · Ask"). Downloading shows a 14 pt ring instead of the dot.
- expanded (Setup): two lines + trailing "Details" link → Settings › Models.

### SlideChip
`SlideChip(page: Int, thumbnail: Image?, style: .inline | .thumb, action)`
- inline: `Radius.chip` capsule-ish rect, `.accent.opacity(0.12)` fill, accent `caption` text "Slide 12", 20 pt tall. Hover → `.opacity(0.2)`. Range variant "Slides 9–11".
- thumb: 32×18 thumbnail + label, 24 pt tall — used in citation rows and the two-column header.
- VoiceOver: "Slide 12, button". Click → highlight in Slides column (see §4.4).

### TimestampChip
`TimestampChip(time: Duration, style: .gutter | .inline | .range(Duration), action)`
- gutter: `mono` `.tertiary`, no background, 48 pt fixed width, hover → `.secondary` + underline. inline: like SlideChip but `mono` text and `.secondary.opacity(0.12)` fill. range: "14:02–18:40".
- VoiceOver: "14 minutes 32 seconds, button. Shows related slide."

### TermChip
`TermChip(term: String, definition: String)` — `Radius.chip`, `.quaternary` fill, `callout` text; hover 300 ms or click → popover with the one-sentence definition (`body`, max 280 pt) and "Find in transcript".

### StreamingText
`StreamingText(committed: AttributedString, volatile: String?, isStreaming: Bool, style: .transcript | .answer)`
- Renders `Text(committed) + Text(volatile)`; volatile styled per §4.4; caret only for `.answer`. Owns the `TextRenderer` shimmer. Exposes `onCitationTap` via `openURL`.
- Committed text changes use `.contentTransition(.opacity)`; appends don't animate (append is the common case and must be free).

### TakeawayCard
`TakeawayCard(takeaway: Takeaway, state: TakeawayCardState, isExpanded: Binding<Bool>, namespace: Namespace.ID)`
`TakeawayCardState = .live(elapsed:) | .settled | .placeholder`
- **.live** (in the dock, glass): header `LiveDot(size: 6)` + "NOW" (`caption`, secondary, tracking 0.5) + "· 3 min" (`mono`); title `headline` (`.contentTransition(.opacity)` + `DS.Motion.morph` on change); summary `subheadline` secondary, `lineLimit(2)`, `lineSpacing(summaryLineSpacing)`, same transition. Refinements arrive at most every 3–5 s; a refinement that changes < 15% of characters still crossfades (never "types"). No footer.
- **.settled** (in the list, opaque `surface`, hairline, `Radius.card`, padding `Space.m`+`Space.l` horizontal): title `headline` + trailing `TimestampChip(.range)`; summary as above; footer row (20 pt): `SlideChip` range · quiz marker (`questionmark.circle` / `checkmark.seal` green / `arrow.uturn.backward.circle` orange). Hover: `surfaceRaised` + hairline → `.separator`. Focused: 2 pt accent ring, 3 pt offset.
- **Expanded** (in place, `DS.Motion.settle`, the list re-flows): summary becomes full; then "Details" bullets (3–6, `body`, `•` with 12 pt hanging indent); "Key terms" row of `TermChip`s; "Slides" row of 64×36 thumbnails (click → show in column); "Transcript 14:02–18:40" `TimestampChip`; trailing small buttons [Ask about this] (`sparkle.magnifyingglass`, seeds Ask with "Explain: <title>") and [Copy] (`doc.on.doc`). A chevron `chevron.down` at top-right rotates 180° on expand.
- **.placeholder**: "Listening for the next topic…" + `ellipsis` `.symbolEffect(.variableColor.iterative)`.
- Height is intrinsic (`fixedSize(horizontal: false, vertical: true)`); never hard-coded, so Dynamic Type works.
- VoiceOver: card is one element in collapsed state: "Unification algorithm, 18:40 to 31:15, slides 12 to 14, quizzed correctly. Summary: … Double-tap to expand." Live card: "Current topic: …". The live card is *not* a live region; announcements are made only when a card settles (`AccessibilityNotification.Announcement("New takeaway: Unification algorithm")`) and can be disabled in Settings › Focus ("Announce new takeaways").

### QuizCard
`QuizCard(question: QuizQuestion, phase: QuizPhase, streak: Int, waiting: Int, onAnswer, onSnooze, onSkip, onDismiss)`
`QuizPhase = .asking | .grading | .correct(feedback:) | .wrong(explanation:, followUp:) | .followUpAsking`
- Layout per §4.6. Option rows: 36 pt, `Radius.control`, `.quaternary` fill; key-cap glyph is a 18×18 rounded rect with `mono` digit; hover → `.accent.opacity(0.12)`; selected → accent fill 100% with white text for 150 ms before submit. `.grading` shows a 14 pt `ProgressView` in the header for ≤ 2 s (grading is local and fast; if a cloud grader takes longer, options stay disabled until it finishes).
- Keyboard is captured through `.onKeyPress` on the card *only when* `@FocusState` says no text field is focused; otherwise ignored.
- VoiceOver: on appear, `Announcement("Quick check: <question>")`; options are buttons "Option 1: …". Card is a `accessibilityElement(children: .contain)` group labeled "Quiz".

### CitationRow
`CitationRow(citations: [Citation])` — `HStack(spacing: Space.s)` of `SlideChip(.thumb)` / `TimestampChip(.inline)`, wraps with a simple flow layout (`Layout` protocol, 30 lines) when it exceeds width.

### JumpToLivePill
`JumpToLivePill(newCount: Int, action)` — glass capsule, `arrow.down` + "Jump to live" + optional badge; `.transition(.move(edge: .bottom).combined(with: .opacity))`, `DS.Motion.quick`. Sits `Space.m` above the bottom inset. `⌘↓`.

### NoticeBanner
`NoticeBanner(kind: .info | .warning, icon: String, title: String, action: (String, () -> Void)?)` — glass, `Radius.float`, 36 pt tall, at the top of the column it concerns; `.transition(.move(edge: .top).combined(with: .opacity))`. Auto-dismisses when the condition clears; manual close `xmark` on hover. At most one banner per column; a new one replaces the old.

### EmptyStateView
`EmptyStateView(symbol: String, title: String, message: String?, action: (label: String, handler)?, style: .full | .compact)` — full: 48 pt symbol `.secondary`, `title2`, `body` secondary ≤ 320 pt, `.glassProminent` button; compact: 24 pt symbol, `headline`, `footnote`, borderless button. Centered in its container. Symbol uses `.symbolEffect(.breathe)` only on first appearance (once), disabled under Reduce Motion.

### DeckDropZone / DeckFan
`DeckDropZone(deck: Binding<SlideDeck?>, indexing: IndexingProgress?)` and `DeckFan(thumbnails: [Image], namespace:)` — per §4.2.

### LectureCard
`LectureCard(lecture: LectureSummary, isSelected: Bool)` — per §4.1.

### ScoreRing
`ScoreRing(correct: Int, total: Int, size: CGFloat = 64)` — accent trim over `.quaternary` track, 6 pt stroke, animates from 0 on appear (`DS.Motion.settle`), numeric label `title2` `monospacedDigit`. VoiceOver: "6 of 8 correct".

---

## 6. Motion catalogue

| Moment | Implementation | Parameters | Reduce Motion |
|---|---|---|---|
| Elapsed time, counts, percentages | `.contentTransition(.numericText())` | `DS.Motion.numeric` | Same (it's a fade) |
| Now card title/summary refinement | `.contentTransition(.opacity)` | `DS.Motion.morph` | Same |
| Takeaway settles (dock → list) | `matchedGeometryEffect(id: takeaway.id, in: ns)` + `withAnimation(DS.Motion.settle)` | duration 0.45, bounce 0.15 | Crossfade in place |
| Card expand/collapse | `withAnimation(DS.Motion.settle)` on `isExpanded`; chevron `rotationEffect` | | `DS.Motion.reduced` |
| Quiz card enter/leave | `.transition(.move(edge:.bottom).combined(with:.opacity))` inside `GlassEffectContainer` | `DS.Motion.float` | Fade |
| Quiz correct | `checkmark.circle.fill` `.symbolEffect(.bounce, value: phase)` | once | None |
| Quiz wrong | Card header crossfade only — **no shake**. Being wrong should feel neutral. | | |
| Live dot | Halo scale/fade loop | 1.2 s | Static dot |
| Model activity | `waveform` `.symbolEffect(.variableColor.iterative.reversing, isActive:)` | | Static symbol, text still changes |
| Volatile transcript shimmer | Custom `TextRenderer` per-glyph opacity wave | 80 pt/s | Static `.secondary` |
| Slide ring moves | `matchedGeometryEffect(id: "slideRing")` | `DS.Motion.settle` | Instant |
| Deck fan-in | Staggered offsets/rotation | 40 ms stagger, `DS.Motion.float` | Fade in fanned |
| Setup → Live | Crossfade + deck `matchedGeometryEffect(id: "deck")` | `DS.Motion.settle` | Crossfade |
| Pills (Jump to live, Resume following) | `.transition(.move+.opacity)` | `DS.Motion.quick` | Fade |
| Hover lifts | `surface → surfaceRaised`, hairline tint | `.easeOut(0.15)` | Same |
| Layout tier change | `withAnimation(DS.Motion.settle)` on the tier enum | | `DS.Motion.reduced` |
| Ask caret | Opacity 1→0 loop | 1 Hz | Static |
| Score ring | trim 0→value | `DS.Motion.settle` | Instant |

Global: read `@Environment(\.accessibilityReduceMotion)` once in the root view and inject a `\.dsAnimation` environment value that every `withAnimation` call uses (`DS.Motion.resolve`). Never call `.animation(_:)` without a `value:`.

---

## 7. Micro-interactions, ranked (delight ÷ cost)

| # | Interaction | Delight | Cost | Verdict |
|---|---|---|---|---|
| 1 | Now card → list "settle" with `matchedGeometryEffect` | High | Low | **Ship first.** It's the app's signature moment and teaches the timeline. |
| 2 | Elapsed time `numericText` + pulsing live dot | High | Trivial | Ship. |
| 3 | Live title/summary crossfade (`morph`) | High | Trivial | Ship. Makes "thinking" visible without being noisy. |
| 4 | Quiz card blooming out of the Now card via `GlassEffectContainer` | High | Low | Ship. |
| 5 | Deck drop → fan-in + "Indexed 42 slides ✓" | High | Medium | Ship. Rewards the one chore we ask for. |
| 6 | "Jump to live" pill with count | Medium | Low | Ship (functional necessity anyway). |
| 7 | Correct-answer `bounce` + streak counter | Medium | Trivial | Ship. |
| 8 | Slide ring gliding between thumbnails | Medium | Low | Ship. |
| 9 | Volatile-text shimmer (`TextRenderer`) | Medium | Medium | Ship if time; fallback is plain `.secondary`. |
| 10 | Timestamp click → slide popover | Medium | Low | Ship. |
| 11 | Setup → Live deck flight (`matchedGeometryEffect` across views) | Medium | Medium-High | Tier 2. Easy to get wrong across navigation; do last. |
| 12 | Title auto-suggest with `sparkles` glint | Low-Med | Low | Ship. |
| 13 | Focus panel dim-on-idle | Low-Med | Low | Ship. |
| 14 | Onboarding hero morph between steps | Low | Medium | Cut if behind. |
| 15 | Hover lift on library cards | Low | Trivial | Ship. |
| 16 | Empty-state symbol `.breathe` | Low | Trivial | Ship, once only. |

---

## 8. Keyboard shortcuts

Register via `.keyboardShortcut` on buttons (so they show in menus and tooltips) and mirror them in the app menu (`CommandGroup`), which is what makes them discoverable. Every shortcut below must appear in a menu.

| Shortcut | Action | Scope |
|---|---|---|
| `⌘N` | New Lecture | Global |
| `⌘⇧N` | New Window (review only) | Global |
| `⌘,` | Settings | Global |
| `⌘F` | Find (library search / transcript search) | Contextual |
| `⌘↩` | Start Lecture / Finish (in Stop popover) / Send (Ask) | Contextual |
| `⌘⇧P`, `Space`* | Pause / Resume | Live |
| `⌘.` | Stop… (opens confirm popover) | Live |
| `⌘K`, `⌘L` | Ask (focus composer) | Session |
| `⌘⇧K` | Ask: "Catch me up (last 5 min)" | Live |
| `⌘⇧F` | Toggle Focus panel | Session (global hotkey optional) |
| `⌘⌥I` | Toggle inspector | Session |
| `⌘⌥S` | Toggle Slides column | Session |
| `⌘1` / `⌘2` / `⌘3` / `⌘4` | Takeaways / Transcript / Slides / Ask (select pane or focus region) | Session |
| `⌘↓` | Jump to live | Session |
| `↑` `↓` `↩` `Esc` | Navigate / expand / collapse takeaways | Takeaways focused |
| `←` `→` | Previous / next slide | Slides focused or slide popover |
| `⌘⇧A` | Resume slide following | Session |
| `1`–`4`, `↩`, `S`, `Esc` | Quiz: choose, submit, snooze, skip | Quiz visible, no text field focused |
| `⌘E` | Export… | Review |
| `⌘⇧C` | Copy Summary | Review |
| `⌘⇧T` | Edit title | Review |
| `⌘C` | Copy focused takeaway as Markdown | Takeaways focused |
| `⌃⌘S` | Toggle sidebar (system) | Global |

\* Space toggles pause only when `@FocusState` reports no text input focused *and* no takeaway is focused (where Space expands).

---

## 9. Accessibility

- **VoiceOver:** every custom control has `accessibilityLabel`, and `accessibilityValue` where state changes (clock, meter, progress). Compound cards are single elements with `accessibilityChildren` actions ("Expand", "Show slide", "Ask about this"). The transcript uses `accessibilityElement(children: .contain)` per paragraph with the timestamp read first ("38 minutes 2 seconds: …"). Volatile text has `accessibilityLabel` prefixed "In progress:". Announcements: new takeaway settled (default on), quiz appeared (always), quiz result (always), "Recording paused/resumed", "Finished — summary ready". Never announce refinements or transcript appends.
- **Keyboard/Full Keyboard Access:** all focusable, visible focus rings (default system ring), logical `focusSection()` groups per column; `⌘1–4` moves focus between regions.
- **Dynamic Type (Accessibility text sizes on macOS):** all text via text styles; no fixed heights on text containers; thumbnails and rings stay fixed; at accessibility sizes the Takeaways column drops `readingMaxWidth` clamping; the Focus panel grows to 420×260; option rows wrap to multiple lines.
- **Reduce Motion:** §6 table. Additionally, the deck fan is static and auto-scroll uses non-animated `scrollTo`.
- **Reduce Transparency:** system handles glass; the Focus panel and Now card take `surface` + hairline. Verify text contrast ≥ 4.5:1 on all glass in both modes with the system's opaque fallback.
- **Increase Contrast:** hairlines switch to `.separator` at 1 pt; chips get a 1 pt border; accent switches to the high-contrast asset variants (§1).
- **Color independence:** correct/wrong/skipped always pair color with a distinct symbol (`checkmark.seal`, `arrow.uturn.backward.circle`, `minus.circle`); current slide uses ring + page-number weight, not color alone.
- **Pointer:** `.hoverEffect` isn't macOS; use explicit hover states via `.onHover` with `DS.Motion.quick`. Tooltips (`.help`) on every icon-only button.

---

## 10. Light & dark

- Both modes use the same semantic tokens; only the three named assets (`Surface`, `SurfaceRaised`, `Hairline`) and `SearchHit` differ.
- Slide thumbnails are almost always white; in dark mode they glow. Wrap every slide image in a 1 pt `hairline` stroke and, in dark mode only, reduce image brightness by 8% (`.brightness(-0.08)` when `colorScheme == .dark`, off under Increase Contrast). The current slide is never dimmed.
- Glass objects need no per-mode work. Verify the quiz card's option rows on glass in dark mode: use `.quaternary` fills, not `.white.opacity`.
- The live dot red and the accent must both be verified against glass in both modes (WCAG 3:1 for non-text UI).

---

## 11. Don'ts

1. **No modal alerts, sheets, or dialogs during a live session.** Confirmations are popovers; errors are banners; everything is dismissible with Esc or ignorable.
2. **No sound.** Ever, by default. (A single optional "quiz ping" sound may be added later; it is off and it is not in v1.)
3. **No layout shift on streaming content.** Reserve space (placeholders with `.redacted`) rather than growing containers, except for the Now card whose height is intrinsic and rarely changes.
4. **No red for "wrong".** Red means recording.
5. **No glass on content.** Cards, transcript, and slide lists are opaque.
6. **No busy gradients, no blur behind text, no drop shadows on flat cards.** Elevation is expressed by `surfaceRaised` and hairline changes only. The only shadow is the system one on popovers and the Focus panel.
7. **No typewriter effects.** Text appears or crossfades; it does not type itself out (except the append of streamed tokens, which is the data, not an effect).
8. **No spinners in the main content.** Activity is shown by the `waveform` symbol and text in the Takeaways header, or by a thin progress bar with a number.
9. **No unbounded transcript paragraphs.** Segment at ≤ 6 lines.
10. **No badges/counters that nag.** The only badge is on the quiz toolbar item in Quiet style, and it clears on view.
11. **No focus stealing.** The quiz card, Focus panel, banners and pills never take first responder from a text field.
12. **No hidden shortcuts.** Every shortcut is in a menu.
13. **No custom fonts.** SF Pro / SF Mono via text styles only.
14. **No animation without `value:`.** And none longer than 0.5 s outside of progress indicators.
15. **No more than one accent-filled (prominent) button visible per screen.**

---

## 12. AppKit bridging & implementation notes

| Need | Approach | Effort |
|---|---|---|
| Focus panel **non-activating** + join all Spaces + no shadow tweaks | The `Window` scene creates an `NSWindow`; on appear, reach it via an `NSViewRepresentable` whose `view.window` is set in `viewDidMoveToWindow`, then set `styleMask.insert(.nonactivatingPanel)` (requires the window to be an `NSPanel`: instead of a SwiftUI `Window`, create an `NSPanel` subclass hosting `NSHostingView(rootView: FocusPanelView())` from an `@MainActor` `FocusPanelController`). Set `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `level = .floating`, `isMovableByWindowBackground = true`, `hidesOnDeactivate = false`. **Recommended: skip the SwiftUI `Window` scene for this one and use the `NSPanel` directly.** | ½ day |
| Global hotkey `⌘⇧F` from other apps | `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` requires Accessibility permission — **defer to v1.1**; ship the menu-bar item instead. | — |
| PDF thumbnails & text | PDFKit (`PDFDocument`, `PDFPage.thumbnail(of:for:)`, `page.string`); Vision `VNRecognizeTextRequest` for image-only pages. No AppKit UI needed. Cache thumbnails at 2× on disk. | 1 day |
| Mic level & device list | `AVAudioEngine` input tap (RMS per buffer) + `AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone])`. Pure AVFoundation. | ½ day |
| Keychain | `Security` framework (`SecItemAdd/Update/CopyMatching`), service `com.lectern.apikeys`, account = provider id. | ¼ day |
| Menu bar red dot | `MenuBarExtra` label with `Image` overlay; no AppKit. | ¼ day |
| Popover slide viewer keyboard paging | `.onKeyPress(.leftArrow)` inside the popover — SwiftUI only. | — |
| Transcript shimmer | `TextRenderer` (SwiftUI, macOS 15+). If it fights with `textSelection`, drop the shimmer and use `.secondary`. | ½ day |
| Auto-scroll | `onScrollGeometryChange` + `scrollPosition(id:)` / `ScrollViewReader`. Pure SwiftUI. | ½ day |
| Export PDF | `ImageRenderer(content:).render { size, renderer in … CGContext PDF }` — SwiftUI only; paginate manually per section. | 1 day |
| Full-text search | SQLite FTS5 via GRDB or raw `sqlite3`; not UI. | ½ day |
| Editable `navigationTitle` in review | `.navigationTitle($title)` (macOS 13+). | — |

**Suggested build order (≈ 4–5 days of UI work):** tokens + components (LiveDot, chips, TakeawayCard, QuizCard) → Live layout shell with tiers → transcript + auto-scroll → Now card dock + settle animation → quiz flow → Setup (deck drop) → Library → Review additions (Summary, Quiz tab, Export) → Settings → Onboarding → Focus panel (NSPanel) → menu bar extra → polish pass with Reduce Motion/Transparency/VoiceOver.

---

## Appendix A — Copy guidelines

- Sentence case everywhere ("Jump to live", not "Jump To Live"). Column headers are the only uppercase text (`caption`, tracked).
- Short, present tense, no exclamation marks. "Correct" not "Correct!". "Not quite" not "Wrong".
- Time: `mm:ss` under an hour, `h:mm:ss` over. Dates: "Today", "Yesterday", then "Tue Sep 23", then "Sep 23, 2025" across years.
- Never say "AI". Say "on-device", "summary", "model" only in Settings.
- Errors name the fix: "Check your key in Settings › Models", not "Authentication failed".

## Appendix B — State matrix (per screen)

| Screen | Empty | Loading | Streaming | Error |
|---|---|---|---|---|
| Library | EmptyStateView (no lectures / no course lectures / no results) | None (local, instant) | — | Storage unreadable → full-screen `EmptyStateView` with "Choose a different location" |
| Setup | Drop zone empty | Indexing bar with count | — | Bad PDF wiggle + copy; mic denied notice |
| Live › Takeaways | "Listening…" Now card | "Warming up model…" header text | Now card morph; settle | NoticeBanner (model failed → fallback), never blocks |
| Live › Transcript | "Listening…" + meter | — | Volatile shimmer | NoticeBanner "No audio detected" |
| Live › Slides | Compact empty (add deck) | Indexing footnote | Ring moves | "Unsure" dashed ring |
| Ask | Suggested prompts | Caret | Token append + citation links | Inline footnote error + Retry |
| Quiz | — | Header ring paused + tiny progress while grading | Follow-up options fade in | If generation fails, the ping is silently skipped and retried next interval |
| Review | — | Summary slot `.redacted` "Writing summary…" | Summary crossfades in | Summary failed → slot shows "Couldn't write the summary" [Try again] |
| Settings › Models | — | Test connection `ProgressView` | Download progress | Row-level `exclamationmark.triangle` + Retry |
| Onboarding | — | Downloads | — | Download failed → "Retry" on the row; Continue stays enabled |

## Appendix C — QA fixes (30 Sep 2026)

Decisions taken while fixing the hands-on QA findings (`docs/ui-review.md`); each amends the section it names.

- **§4.4 Slides column:** list rows are the compact 96×54 thumbnail + right-aligned page number again (QA V4); the full-width hero above the list is the only large rendering.
- **§4.6 Quiz card:** the card is capped at 250 pt and scrolls internally (QA V5); option rows are 30 pt with 6 pt spacing; Snooze/Skip are mini capsule buttons.
- **§4.3 Tiers:** breakpoints have 20 pt of hysteresis; the inspector is pure state, toggled without the split-view animation, and the tier only closes it on entering the single tier (restoring the previous state on leaving). Two `.inspector`s must never coexist in one window: Course Ask is the Library view's inspector, not the split view's.
- **§4.4 Transcript:** volatile text is plain `.secondary` (no per-glyph shimmer); a hypothesis never continues a student turn. Transcript search focuses via the Find command (⌘F), not a toolbar shortcut.
- **§4.5 Single tier tip:** a `NoticeBanner` in the Takeaways column with an "Open" action, not a popover.
- **§4.8/§8 Keys:** quiz 1–4 / S / Esc and Space-to-pause are handled at the session root (default focus) so they work whenever no text field has focus. ⌘↩ starts a lecture (Setup) and finishes it (Stop popover, alongside ↩). ⌘⇧T shows an inline title field in the toolbar's principal slot.
- **§3.1 Canvas:** `DS.Colors.canvas` is an opaque asset (`Canvas`), because `windowBackgroundColor` is translucent on macOS 26 and let the Library bleed through under a session (QA V1).
- **§9 Accessibility:** selectable or link-bearing text is exposed as one plain-string element (`children: .ignore` + label); `.combine` is never applied over selectable text (QA C1). Lecture cards are buttons with Open/Select actions; role pickers carry explicit labels.
- **§4.9 Export:** the PDF paginates block-by-block so a takeaway's title stays with its bullets (QA V8). The summary is built from whole sentences (QA F4).
- **Demo:** transcript timestamps follow the session clock at every speed (QA F3); takeaway ranges are clamped to end ≥ start in the app model.
- **§2.1 Navigation (retest):** the detail column renders exactly one of Library / Setup / Session (no NavigationStack, so nothing sits under a session); a toolbar chevron returns to the Library. **§4.5 Single tier:** Ask is a fourth pane (`Takeaways · Transcript · Slides · Ask`); ⌘1–4 select panes there and never open the inspector. **§4.4 Citations:** a slide citation is a manual override (hero shows the slide, Auto off, `setCurrentSlide`); a timestamp citation switches to Transcript and lands on the moment, unpinning live-follow. **Review › missed concepts** match questions to takeaways by grounding / source range / slides / concept text, never by ping time.
