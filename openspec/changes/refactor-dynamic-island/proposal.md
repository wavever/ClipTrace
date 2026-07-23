## Why

The current Dynamic Island feature renders as small floating panels positioned *below* the menu bar and physical notch. On real hardware this produces three visible defects: the island sits in the wrong place (not anchored to the notch), copy-toast and menu content gets clipped or hidden behind the camera housing, and the brief copy "toast" and the expandable clipboard menu are two unrelated panels that pop in/out independently, so the experience feels disjointed rather than a single surface growing out of the notch.

The fix is an architectural one: replace the two separate below-notch panels with a **single top-anchored surface whose visible black shape is drawn in SwiftUI and morphs in place**, hugging the real notch geometry. The collapsed pill, the copy notification, and the expanded clipboard menu all become states of the *same* surface.

## What Changes

- **BREAKING (internal):** Replace the dual-panel model (`panel` for pill/toast + separate `menuPanel` for the clipboard menu) with one top-anchored notch panel. Both the toast and the expanded clipboard list now render inside this single surface.
- Anchor the panel to the **top edge of the notched built-in screen** (above the menu bar), centered on the physical notch, instead of offsetting it downward into the visible frame.
- Derive notch geometry from the screen directly: notch width from the menu-bar auxiliary areas on either side of the cutout, and notch height from the screen's top safe-area inset. Provide a simulated notch for non-notched built-in displays so the feature can still be previewed.
- Draw the island background as a **single morphing notch shape** with side "wings" extending from the notch's top edge and a rounded body hanging below it. Collapsed, toast, and expanded states animate by changing the shape's width / corner radius / extension — not by swapping windows.
- Lay out all content **strictly below the notch height**, reserving the central notch column as empty space so text and icons are never occluded by the camera area.
- Tune expand/collapse motion: a lightly-bouncy spring on open and a **critically-damped spring on close** (no overshoot, so the surface's bottom edge never rebounds to expose the cutout), with a fixed non-animated minimum height equal to the notch height.
- Harden window/hosting behavior for the notch panel: keyable non-activating panel above the menu-bar window level, first-click activation, and deferred AppKit constraint/layout updates to avoid `NSHostingView` re-entrancy.

## Capabilities

### New Capabilities
- `dynamic-island`: The notch-anchored clipboard surface — its placement relative to the physical notch, the geometry it derives from the display, how it keeps content clear of the camera area, and how it morphs between collapsed, copy-notification, and expanded-menu states.

### Modified Capabilities
<!-- No pre-existing OpenSpec specs in openspec/specs/; this is the first formalized capability. -->

## Impact

- **Code (rewritten):** `Clipth/Services/DynamicIslandController.swift` (panel lifecycle, positioning, single-panel model), `Clipth/Views/DynamicIslandView.swift` (states, morphing notch shape, content layout).
- **Code (touched):** integration points that call `DynamicIslandController.shared.flash(...)` in `Clipth/ViewModels/ClipboardViewModel.swift`; enable/anchor wiring in `Clipth/ClipthApp.swift`; settings/eligibility checks in `Clipth/Views/SettingsPanelView.swift`; reuse of `MenuBarView(surfaceStyle: .dynamicIsland)` as the expanded content.
- **New helpers:** notch geometry resolver and shared notch animation/shape definitions.
- **Behavior:** Notch-display detection and the "island replaces menu bar" eligibility logic are preserved; external/non-notched displays continue to be excluded (or use the simulated notch only where already gated).
- **No new third-party dependencies.** Pure AppKit + SwiftUI.
