# Diagnosis: AI assistant freezes Clippy (100% CPU, ~2GB RAM, force-quit)

Status: ROOT CAUSE IDENTIFIED. No fix applied. No fix verified.

## Symptom (observed by user, 2026-06-17 ~02:23 EDT)
Using the AI assistant, Clippy locked up: ~2GB memory, 100% CPU, required force quit.
`clippy.log` contained nothing.

## Root cause
The streaming AI response renders a live message bubble with `.textSelection(.enabled)`.
That modifier is backed by SwiftUI's internal `SelectionOverlay` (an NSViewRepresentable).
Every streamed token mutates `message.text`, which re-runs `SelectionOverlay.updateNSView`
(recomputing AppKit text geometry: setFont / NSAttributedString.replacingLineBreakModes).
The AppKit layout invalidation re-enters the SwiftUI AttributeGraph transaction, which never
reaches a fixed point while tokens keep arriving. Result: main thread spins at ~100% on one
core, the run loop never completes a cycle, the autorelease pool never drains, and footprint
grows without bound until the app is force-quit.

Culprit: `Sources/Clippy/AI/AIAssistantPanelView.swift`
- line 498: `.textSelection(.enabled)` on the live (`isLive`) streaming `Text`
- line 509: `.textSelection(.enabled)` on the wrapping `Group` (also active while live)
- line 394: `ProgressView()` "Thinking..." spinner appears in the same loop as Apple's `AppKitProgressView`

A prior fix (comment at lines 491-493) already deferred `Markdown(...)` parsing until the turn
ends. That was correct but incomplete: text selection on the live bubble is the remaining trigger.
The defect is present on branch `feature/panel-redesign` (current code).

## Evidence files
- `spindump-2026-06-15-heaviest-stack.txt` - macOS CPU watchdog spindump. Footprint 147 -> 2105 MB
  (matches the ~2GB seen). Unresponsive, 1 thread, 88% CPU. Leaf: SelectionOverlay.updateNSView +
  LazyStack.place / _PaddingLayout.sizeThatFits.
- `spindump-2026-06-16-heaviest-stack.txt` - second incident. Footprint 100 -> 1611 MB. Unresponsive,
  96% CPU. Leaf: SelectionOverlay.updateNSView -> setFont / replacingLineBreakModes.
- `unified-log-ollama-stream-2026-06-17.txt` - tonight. Streaming from Ollama (127.0.0.1:11434),
  64.7s connection cancelled at force-quit; Clippy log volume collapses after 02:22 (frozen main thread).
- `source-AIAssistantPanelView-bubble.txt` - annotated source excerpt (lines 386-509).

Why clippy.log was empty: the freeze is a tight CPU loop inside SwiftUI's layout engine; the app
never returns to the run loop to flush its own logging.

## Proposed fix (NOT yet applied, NOT verified)
Gate selection off while streaming so SelectionOverlay leaves the per-token update path:
- remove `.textSelection(.enabled)` from the `isLive` `Text` (line 498)
- apply the Group-level `.textSelection(.enabled)` (line 509) only when `!isLive`

## How to verify a fix once applied (required before claiming done)
1. Build: `swift build -c release` (or the project's Xcode/SwiftPM build) -> expect success.
2. Run the app, open the AI assistant, send a prompt to the local Ollama model, let it stream a
   long (multi-paragraph) response.
3. Watch `Activity Monitor` (or `top -pid <Clippy pid>`): CPU must stay well below 100% of one core
   and memory must remain flat (tens of MB), not climb into the hundreds/GB.
4. Confirm no new `Clippy_*.cpu_resource.diag` appears in `/Library/Logs/DiagnosticReports/`.
5. Expected: streaming text is non-selectable mid-stream, fully selectable the instant the turn ends.
