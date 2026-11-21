# Nimbus UI/UX & Code Architecture Style Guide

This document defines the UI design system, copy conventions, e-ink hardware constraints, and modular Lua mixin architecture for **Nimbus** (`koreader/nimbus.koplugin`), derived from the **Storefront**, **Libbee**, **Beeline**, and **Sink** design systems.

---

## 1. Code Architecture & Mixin Pattern

### Three-Layer Separation
Keep files small, single-purpose (target **under 450 lines per file**), and strictly layered:

1. **Layer 1 — Data & CloudFS Transport (Zero UI)**
   - `nimbus_constants.lua`, `nimbus_settings.lua`, `nimbus_http.lua`, `nimbus_cloud.lua`, `nimbus_cloud_*.lua`
2. **Layer 2 — Pure Domain Logic (100% Headless Testable)**
   - `nimbus_hash.lua`, `nimbus_matcher.lua`, `nimbus_merge.lua`, `nimbus_scanner.lua`, `nimbus_covers.lua`, `nimbus_stats.lua`, `nimbus_sync.lua`
3. **Layer 3 — UI Primitives & Mixins**
   - `nimbus_theme.lua` — Design tokens (`sc`, borders, radii, monochrome colors, font sizes).
   - `nimbus_progress.lua` — Unified cancelable `ProgressWidget` dialog.
   - `nimbus_ui_widgets.lua` — Shared UI builders (`createIconButton`, `createButton`, `createBadge`, `createSectionHeader`, `createSettingRow`, `createCheckboxRow`, `createTwoTabBar`, `showCardDialog`, `showConfirmDialog`, `showInputDialog`, `showToast`, `applyMixin`).
   - Feature Mixins: `nimbus_ui_book_card.lua`, `nimbus_ui_upload.lua` — merged into `UILibrary` via `Widgets.applyMixin(UILibrary, Module)`.
   - Top-Level Views: `nimbus_ui_library.lua`, `nimbus_ui_settings.lua`.

### Mixin & Widget Rules
- Use `Widgets.applyMixin(target, source)` (matching `xray.koplugin`) to compose focused UI workflows without creating monolithic files.
- Never duplicate widget styling or button/row builders inside feature files; always call `nimbus_ui_widgets.lua`.
- **Never use unstyled native KOReader popups** (`InfoMessage`, `ConfirmBox`, `InputDialog`, `ButtonDialog`) in user-facing UI; always use `Widgets.showToast`, `Widgets.showConfirmDialog`, `Widgets.showInputDialog`, and `Widgets.showCardDialog`.
- **KOReader `Button` Border Rule**: For secondary (white) buttons, pass `background = nil` (or explicitly set `btn.frame.color = Blitbuffer.COLOR_BLACK`), because KOReader's `Button:init()` sets `border_color = background_color` whenever `background` is non-nil.

### Lua 5.1 / LuaJIT & E-Ink Hygiene
- **Strict Lua 5.1 / LuaJIT**: Never use Lua 5.2+ syntax (`goto`, `_ENV`, `&`/`|`); use `bit.*` for bitwise operations.
- **Zero Global Leakage**: Every variable, helper, and module must be declared `local`.
- **Protected Boundaries**: Wrap file I/O, JSON decode, `RenderImage`, and `DocumentRegistry` calls in `pcall`.
- **Memory Management**: Explicitly `:free()` temporary `BlitBuffer` objects after scaling/saving covers.
- **Non-Intrusive Background Sync**: Automated hooks (`onReaderReady`, `onCloseDocument`, `onSuspend`) must never show blocking modal popups on network errors; log with `logger.warn`/`logger.info`.

---

## 2. UI/UX Design Tokens (`nimbus_theme.lua`)

- **Monochrome E-Ink Clarity (No Grey on E-Ink)**: Do not use grey (`COLOR_GRAY`, `COLOR_DARK_GRAY`, `COLOR_LIGHT_GRAY`, `Color8(...)`) for text, icons, or readable UI elements — grey is hard to read on e-ink displays. Always use pure black (`Blitbuffer.COLOR_BLACK`) on pure white (`Blitbuffer.COLOR_WHITE`) for all text and labels, and keep thin structural rules crisp.
- **Minimal E-Ink Progress Dialogs**: Keep progress dialogs uncluttered (status + title/item only) and throttle redraws (≥ 1.2 s) without rapid byte-counter churn (e.g., avoid `xx MB / XX MB`).
- **Dynamic Screen Scaling**: All sizes, paddings, borders, and margins pass through `sc(val)` (`Device.screen:scaleBySize`).
- **Single-Choice vs. Toggle**: Use `Widgets.createRadioRow` for mutually exclusive single-choice pickers (filters, providers, matching methods) and `Widgets.createCheckboxRow` only for boolean on/off toggles or multi-select checklists.
- **Dense Bordered Menus**: Action menus (`Library Menu`, `Book Actions`, `Settings`) should wrap rows in `Widgets.createMenuList` (1px outer border, rounded corners, 1px `COLOR_LIGHT_GRAY` dividers, compact `sc(3)` vertical padding).
- **Feather SVG Icons**: Uniform `stroke="#000000" stroke-width="1.2"` across all header and row icons.
- **Header Density**: Keep the top-right header to at most **1–2 action icons** (`[⋯]` in Home Screen mode; `[⋯]` + `[✕]` in Plugin Overlay mode). Place search directly in the header bar (`[ 🔍 Search library... ]`) and filter/view/sync in the sub-toolbar below the tabs.
- **Home Screen Neutrality**: When running as the KOReader Home Screen, show `[☰]` (to open KOReader's native top menu) without `"Nimbus"` branding or an `X` close button.
- **Neutral Terminology**: Never use trademarked terms such as `"Whispersync"` in UI copy, settings, or comments; use `"Reading Sync"` / `"Auto-Jump to Latest Page"`.

### Typography
Always use KOReader's fontmap slots (`tfont` / `cfont`) rather than hardcoded `.ttf` filenames so Nimbus automatically inherits KOReader / SimpleUI font choices.

| Role | Font Face | Base Size | Usage |
| :--- | :--- | :--- | :--- |
| **Title / Header** | `tfont` | 20–22 pt (bold) | View headers and card titles |
| **Book Titles** | `cfont` | 14–18 pt (bold) | Book titles in Grid & List views |
| **Body / Labels** | `cfont` | 16–18 pt | Setting rows, checklists, buttons |
| **Subtext / Meta** | `cfont` | 13–15 pt | Authors, progress, provider status |
| **Section Headers** | `cfont` (bold) | 13 pt uppercase | Uppercase group pills (`CLOUD STORAGE`) |

---

## 3. Copy, Punctuation & Localization

- **Zero spaces around forward slashes**: `On Device/Cloud`, `Open/Close`, `Upload/Sync` (never `On Device / Cloud`).
- **Attached three-dot ASCII ellipses** for in-flight actions: `Syncing...`, `Uploading...`, `Downloading...`.
- **Title Case** for menu entries, dialog titles, and buttons; **Sentence case** for subtitles and alerts.
- **Localization**: Wrap all user-facing strings in `_("...")` with `string.format` placeholders; never translate the brand name `"Nimbus"`.
