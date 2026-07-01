import SwiftUI
import AppKit
import CoreText
import CoreImage

// MARK: - Continuous live-text selection layer

/// A fragment positioned in display coordinates, ready to be laid out by the
/// selection layer.
struct DisplayFragment {
    let text: String
    /// Bounding box in the layer's coordinate space (top-left origin).
    let rect: CGRect
    let fontSize: CGFloat
}

/// A single, transparent overlay spanning the **whole** image that owns the
/// selection for *every* OCR fragment at once.
///
/// The previous design placed one `NSTextView` per fragment, so a drag begun in
/// one fragment was captured by that view alone and could never extend into its
/// neighbours — selection "truncated" at each box boundary. Here a lone view
/// receives the mouse-down and then tracks the entire drag, mapping points to a
/// `(fragment, character)` caret with Core Text so the highlight flows
/// continuously across lines, exactly like macOS Live Text.
struct LiveTextSelectionLayer: NSViewRepresentable {
    let fragments: [DisplayFragment]
    /// Called with the assembled text when the user copies a selection.
    let onCopy: (String) -> Void

    func makeNSView(context: Context) -> LiveTextSelectionView {
        let view = LiveTextSelectionView()
        view.onCopy = onCopy
        view.setFragments(fragments)
        return view
    }

    func updateNSView(_ view: LiveTextSelectionView, context: Context) {
        view.onCopy = onCopy
        view.setFragments(fragments)
    }
}

final class LiveTextSelectionView: NSView {
    var onCopy: ((String) -> Void)?

    /// A laid-out fragment with a cached Core Text line for hit-testing.
    private struct Frag {
        let text: NSString
        let rect: CGRect
        let line: CTLine
        /// Typographic width of the unscaled line.
        let width: CGFloat
        /// UTF-16 length (matches Core Text string indices).
        let length: Int
    }

    /// A caret position, ordered by reading order then character offset.
    private struct Caret: Comparable {
        let frag: Int
        let char: Int
        static func < (a: Caret, b: Caret) -> Bool {
            a.frag != b.frag ? a.frag < b.frag : a.char < b.char
        }
    }

    private var frags: [Frag] = []
    private var anchor: Caret?
    private var head: Caret?
    private var signature = 0

    override var isFlipped: Bool { true }                       // top-left origin, matches SwiftUI
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    func setFragments(_ display: [DisplayFragment]) {
        // Skip the costly rebuild (and selection reset) when nothing changed —
        // updateNSView fires on every SwiftUI re-render, e.g. while panning.
        var hasher = Hasher()
        for d in display {
            hasher.combine(d.text)
            hasher.combine(Int(d.rect.minX.rounded()))
            hasher.combine(Int(d.rect.minY.rounded()))
            hasher.combine(Int(d.rect.width.rounded()))
            hasher.combine(Int(d.rect.height.rounded()))
        }
        let sig = hasher.finalize()
        if sig == signature, !frags.isEmpty { return }
        signature = sig

        // Reading order: top-to-bottom, then left-to-right within a line band.
        let sorted = display.sorted { lhs, rhs in
            let band = min(lhs.rect.height, rhs.rect.height) * 0.5
            if abs(lhs.rect.minY - rhs.rect.minY) > band {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
        frags = sorted.map { d in
            let attr = NSAttributedString(
                string: d.text,
                attributes: [.font: NSFont.systemFont(ofSize: d.fontSize)]
            )
            let line = CTLineCreateWithAttributedString(attr)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return Frag(
                text: d.text as NSString,
                rect: d.rect,
                line: line,
                width: width,
                length: (d.text as NSString).length
            )
        }
        anchor = nil
        head = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Hit testing

    /// Pass drags that start on bare image through to SwiftUI (pan/zoom); only
    /// claim the event when the mouse-down lands on or near text.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for f in frags where f.rect.insetBy(dx: -3, dy: -3).contains(p) {
            return self
        }
        return nil
    }

    private func caret(at point: CGPoint) -> Caret? {
        guard !frags.isEmpty else { return nil }
        // Nearest fragment: smallest vertical gap, then horizontal gap. This
        // lets a drag that strays into the gutter still resolve to a sensible
        // line, so dragging downward keeps extending the selection.
        var best = 0
        var bestV = CGFloat.greatestFiniteMagnitude
        var bestH = CGFloat.greatestFiniteMagnitude
        for (i, f) in frags.enumerated() {
            let v = max(0, max(f.rect.minY - point.y, point.y - f.rect.maxY))
            let h = max(0, max(f.rect.minX - point.x, point.x - f.rect.maxX))
            if v < bestV - 0.01 || (abs(v - bestV) <= 0.01 && h < bestH) {
                bestV = v; bestH = h; best = i
            }
        }
        return Caret(frag: best, char: charIndex(in: frags[best], x: point.x))
    }

    private func charIndex(in f: Frag, x: CGFloat) -> Int {
        guard f.width > 0, f.rect.width > 0 else { return 0 }
        // The box is fit to the rendered glyphs, so map box-space back to
        // line-space by the same horizontal scale used when drawing.
        let scale = f.rect.width / f.width
        let localX = (x - f.rect.minX) / scale
        if localX <= 0 { return 0 }
        if localX >= f.width { return f.length }
        let idx = CTLineGetStringIndexForPosition(f.line, CGPoint(x: localX, y: 0))
        return max(0, min(idx, f.length))
    }

    // MARK: Selection geometry

    private func selectionRange() -> (lo: Caret, hi: Caret)? {
        guard let a = anchor, let h = head else { return nil }
        let lo = min(a, h), hi = max(a, h)
        return lo == hi ? nil : (lo, hi)
    }

    /// The (start, end) character range selected within fragment `index`.
    private func charRange(forFragment index: Int, in sel: (lo: Caret, hi: Caret)) -> (Int, Int)? {
        guard index >= sel.lo.frag, index <= sel.hi.frag else { return nil }
        let start = index == sel.lo.frag ? sel.lo.char : 0
        let end = index == sel.hi.frag ? sel.hi.char : frags[index].length
        return end > start ? (start, end) : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let sel = selectionRange() else { return }
        ctx.setFillColor(sageHighlight().cgColor)
        for i in sel.lo.frag...sel.hi.frag {
            guard let (s, e) = charRange(forFragment: i, in: sel) else { continue }
            let f = frags[i]
            let scale = f.rect.width / f.width
            let x0 = CTLineGetOffsetForStringIndex(f.line, s, nil) * scale
            let x1 = CTLineGetOffsetForStringIndex(f.line, e, nil) * scale
            let r = CGRect(x: f.rect.minX + x0, y: f.rect.minY, width: x1 - x0, height: f.rect.height)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
        }
    }

    private func sageHighlight() -> NSColor {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        let base = isDark
            ? NSColor(red: 0.58, green: 0.76, blue: 0.65, alpha: 1.0)
            : NSColor(red: 0.47, green: 0.65, blue: 0.54, alpha: 1.0)
        return base.withAlphaComponent(0.35)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 3 {            // triple-click → select everything
            selectAll(nil)
            return
        }
        if event.clickCount == 2 {            // double-click → select the line
            if let c = caret(at: p) {
                anchor = Caret(frag: c.frag, char: 0)
                head = Caret(frag: c.frag, char: frags[c.frag].length)
            }
            needsDisplay = true
            return
        }
        anchor = caret(at: p)
        head = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        head = caret(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        head = caret(at: convert(event.locationInWindow, from: nil))
        if let a = anchor, a == head { anchor = nil; head = nil }   // bare click clears
        needsDisplay = true
    }

    override func resetCursorRects() {
        for f in frags { addCursorRect(f.rect, cursor: .iBeam) }
    }

    // MARK: Copy / select-all

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c": copy(nil); return true
        case "a": selectAll(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        guard let last = frags.indices.last else { return }
        anchor = Caret(frag: 0, char: 0)
        head = Caret(frag: last, char: frags[last].length)
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedString()
        guard !text.isEmpty else { return }
        onCopy?(text)
    }

    private func selectedString() -> String {
        guard let sel = selectionRange() else { return "" }
        var parts: [String] = []
        for i in sel.lo.frag...sel.hi.frag {
            guard let (s, e) = charRange(forFragment: i, in: sel) else { continue }
            parts.append(frags[i].text.substring(with: NSRange(location: s, length: e - s)))
        }
        return parts.joined(separator: "\n")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard selectionRange() != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: L("common.copy"), action: #selector(copy(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }
}

// MARK: - OCR Result View

/// Full-bleed image modal with "Live Text" style selection.  The image is
/// displayed as-is; after OCR completes, transparent selectable text overlays
/// are placed at the exact bounding-box positions so the user can click-drag
/// to select text directly on the image.
@MainActor
struct OCRResultView: View {
    let item: ClipboardItem
    let onClose: () -> Void

    @State private var fragments: [OCRFragment] = []
    @State private var isRecognizing: Bool = true
    @State private var image: NSImage?

    // Zoom / pan / rotate state
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var rotation: Angle = .zero
    @State private var lastRotation: Angle = .zero

    private var hasTransform: Bool {
        scale != 1 || offset != .zero || rotation != .zero
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            imageArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 900, height: 640)
        .task {
            let reference = ImagePayloadStore.reference(for: item)
            async let loadedImage = ImagePayloadStore.imageAsync(for: reference)
            async let recognized = OCRService.shared.recognizeFragments(reference: reference)
            image = await loadedImage
            fragments = await recognized
            isRecognizing = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(Color.appAccent)
            Text(L("ocr.title"))
                .font(.system(size: 14, weight: .semibold))

            if !isRecognizing, fragments.isEmpty {
                Label(L("ocr.empty"), systemImage: "text.badge.xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(PaperIconButtonStyle(size: 28))
            .help(L("common.close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Image + live-text overlays

    private var imageArea: some View {
        GeometryReader { geo in
            if let image {
                let displaySize = fittedSize(
                    image: image,
                    in: geo.size
                )

                // Fragment rects in display coordinates, shared by the hint
                // boxes and the selection layer.
                let displayFragments = fragments.map { frag -> DisplayFragment in
                    let rect = visionToDisplay(frag.boundingBox, displaySize: displaySize)
                    let box = CGRect(
                        x: rect.origin.x, y: rect.origin.y,
                        width: max(rect.width, 4), height: max(rect.height, 4)
                    )
                    return DisplayFragment(
                        text: frag.text,
                        rect: box,
                        fontSize: max(box.height * 0.82, 9)
                    )
                }

                ZStack(alignment: .topLeading) {
                    // The image itself, centered in the available space.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displaySize.width, height: displaySize.height)

                    // Sage hint boxes — pure decoration, never hit-tested so
                    // they don't swallow the selection drag or a pan gesture.
                    ForEach(Array(displayFragments.enumerated()), id: \.offset) { _, frag in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.appAccent.opacity(0.4), lineWidth: 0.75)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.appAccent.opacity(0.06))
                            )
                            .frame(width: frag.rect.width, height: frag.rect.height)
                            .offset(x: frag.rect.origin.x, y: frag.rect.origin.y)
                            .allowsHitTesting(false)
                    }

                    // One overlay owns selection for every fragment, so a drag
                    // flows continuously across lines instead of truncating at
                    // each box boundary.
                    LiveTextSelectionLayer(fragments: displayFragments) { text in
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        ClipboardMonitor.markInternalWrite()
                        ToastCenter.shared.show(
                            L("common.copied"),
                            systemImage: "doc.on.doc",
                            tint: .appAccent
                        )
                    }
                    .frame(width: displaySize.width, height: displaySize.height)
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .scaleEffect(scale)
                .rotationEffect(rotation)
                .offset(offset)
                .gesture(zoomGesture)
                .gesture(panGesture)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            } else {
                Color.appPaper
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                    }
            }

            if isRecognizing {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(L("ocr.recognizing"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = lastScale * value
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func resetTransform() {
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = 1; lastScale = 1
            offset = .zero; lastOffset = .zero
            rotation = .zero; lastRotation = .zero
        }
    }

    // MARK: - Coordinate conversion

    private func fittedSize(image: NSImage, in container: CGSize) -> CGSize {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return .zero }
        let scale = min(container.width / iw, container.height / ih)
        return CGSize(width: iw * scale, height: ih * scale)
    }

    private func visionToDisplay(_ box: CGRect, displaySize: CGSize) -> CGRect {
        let x = box.origin.x * displaySize.width
        let y = (1 - box.origin.y - box.height) * displaySize.height
        let w = box.width * displaySize.width
        let h = box.height * displaySize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !isRecognizing, !fragments.isEmpty {
                Button {
                    let fullText = fragments.map(\.text).joined(separator: "\n")
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(fullText, forType: .string)
                    ClipboardMonitor.markInternalWrite()
                    ToastCenter.shared.show(
                        L("common.copied"),
                        systemImage: "doc.on.doc",
                        tint: .appAccent
                    )
                } label: {
                    Label(L("ocr.copyAll"), systemImage: "doc.on.doc")
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
            }

            Spacer()

            // Rotate buttons
            HStack(spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        rotation -= .degrees(90)
                        lastRotation = rotation
                    }
                } label: {
                    Image(systemName: "rotate.left")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .help(L("ocr.rotateLeft"))

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        rotation += .degrees(90)
                        lastRotation = rotation
                    }
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .help(L("ocr.rotateRight"))
            }

            Button(action: resetTransform) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PaperActionButtonStyle(role: .plain))
            .help(L("ocr.resetView"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - QR / Barcode Result View

/// Image modal for QR code and barcode decoding. The left side keeps the
/// original image visible with Vision bounding boxes; the right side lists
/// every decoded payload with one-click copy controls.
@MainActor
struct BarcodeResultView: View {
    let item: ClipboardItem
    let onClose: () -> Void

    @State private var detections: [BarcodeDetection] = []
    @State private var isScanning: Bool = true
    @State private var image: NSImage?
    @State private var selectedID: BarcodeDetection.ID?

    // Zoom / pan state
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                imageArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                resultList
                    .frame(width: 330)
            }
            Divider()
            footer
        }
        .frame(width: 980, height: 640)
        .task {
            let reference = ImagePayloadStore.reference(for: item)
            async let loadedImage = ImagePayloadStore.imageAsync(for: reference)
            async let scanned = BarcodeService.shared.detect(reference: reference)
            image = await loadedImage
            detections = await scanned
            selectedID = detections.first?.id
            isScanning = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder")
                .foregroundStyle(Color.appAccent)
            Text(L("barcode.title"))
                .font(.system(size: 14, weight: .semibold))

            if !isScanning, detections.isEmpty {
                Label(L("barcode.empty"), systemImage: "qrcode")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(PaperIconButtonStyle(size: 28))
            .help(L("common.close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Image + bounding boxes

    private var imageArea: some View {
        GeometryReader { geo in
            if let image {
                let displaySize = fittedSize(image: image, in: geo.size)

                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displaySize.width, height: displaySize.height)

                    ForEach(Array(detections.enumerated()), id: \.element.id) { index, detection in
                        let rect = visionToDisplay(detection.boundingBox, displaySize: displaySize)
                        let selected = detection.id == selectedID

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    selected ? Color.appAccent : Color.appAccent.opacity(0.55),
                                    lineWidth: selected ? 2 : 1
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.appAccent.opacity(selected ? 0.12 : 0.06))
                                )

                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.appAccent)
                                )
                                .offset(x: 4, y: 4)
                        }
                        .frame(width: max(rect.width, 16), height: max(rect.height, 16))
                        .offset(x: rect.origin.x, y: rect.origin.y)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = detection.id
                        }
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(zoomGesture)
                .gesture(panGesture)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            } else {
                Color.appPaper
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 36, weight: .light))
                            Text(L("barcode.noImage"))
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.secondary)
                    }
            }

            if isScanning {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(L("barcode.scanning"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appPaper.opacity(0.35))
            }
        }
    }

    // MARK: - Results

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("barcode.results"), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !detections.isEmpty {
                    Text("\(detections.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.appAccent.opacity(0.12))
                        )
                }
            }

            if isScanning {
                Spacer()
            } else if detections.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 30, weight: .light))
                    Text(L("barcode.empty"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(detections.enumerated()), id: \.element.id) { index, detection in
                            BarcodeDetectionRow(
                                index: index + 1,
                                detection: detection,
                                isSelected: detection.id == selectedID,
                                onSelect: { selectedID = detection.id },
                                onCopy: { copy(detection.payload) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(Color.appPaper)
    }

    // MARK: - Gestures / Geometry

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = lastScale * value
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func resetTransform() {
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = 1; lastScale = 1
            offset = .zero; lastOffset = .zero
        }
    }

    private func fittedSize(image: NSImage, in container: CGSize) -> CGSize {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return .zero }
        let scale = min(container.width / iw, container.height / ih)
        return CGSize(width: iw * scale, height: ih * scale)
    }

    private func visionToDisplay(_ box: CGRect, displaySize: CGSize) -> CGRect {
        let x = box.origin.x * displaySize.width
        let y = (1 - box.origin.y - box.height) * displaySize.height
        let w = box.width * displaySize.width
        let h = box.height * displaySize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Footer / Copy

    private var footer: some View {
        HStack(spacing: 10) {
            if !isScanning, !detections.isEmpty {
                Button {
                    copy(detections.map(\.payload).joined(separator: "\n"))
                } label: {
                    Label(L("barcode.copyAll"), systemImage: "doc.on.doc")
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
            }

            Spacer()

            Button(action: resetTransform) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PaperActionButtonStyle(role: .plain))
            .help(L("ocr.resetView"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardMonitor.markInternalWrite()
        ToastCenter.shared.show(
            L("common.copied"),
            systemImage: "doc.on.doc",
            tint: .appAccent
        )
    }
}

private struct BarcodeDetectionRow: View {
    let index: Int
    let detection: BarcodeDetection
    let isSelected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.appAccent))

                VStack(alignment: .leading, spacing: 2) {
                    Text(detection.displaySymbology)
                        .font(.system(size: 12, weight: .semibold))
                    Text(L("barcode.confidenceFormat", Double(detection.confidence * 100)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .help(L("barcode.copyValue"))
            }

            Text(detection.payload)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.appCard.opacity(0.82))
                )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.appAccent.opacity(0.12) : Color.appCard.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.appAccent.opacity(0.65) : Color.appCardBorder,
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Text QR Code Preview

/// Generates crisp QR code images from text clips. Kept small and local to the
/// preview UI so the feature stays offline and dependency-free.
private enum QRCodeImageFactory {
    private static let context = CIContext(options: nil)

    static func makeImage(from text: String, sideLength: CGFloat = 360) -> NSImage? {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return nil }

        guard let qrFilter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        qrFilter.setValue(data, forKey: "inputMessage")
        qrFilter.setValue("M", forKey: "inputCorrectionLevel")

        guard let qrImage = qrFilter.outputImage else { return nil }
        let outputImage: CIImage
        if let colorFilter = CIFilter(name: "CIFalseColor") {
            colorFilter.setValue(qrImage, forKey: kCIInputImageKey)
            colorFilter.setValue(CIColor.black, forKey: "inputColor0")
            colorFilter.setValue(CIColor.white, forKey: "inputColor1")
            outputImage = colorFilter.outputImage ?? qrImage
        } else {
            outputImage = qrImage
        }

        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = sideLength / max(extent.width, extent.height)
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent.integral) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
    }
}

@MainActor
struct TextQRCodePreviewView: View {
    let item: ClipboardItem
    let onClose: () -> Void

    @State private var qrImage: NSImage?
    @State private var didGenerate = false

    /// Use protected display text as the QR source: the preview renders the
    /// string, encodes it into the QR image, and the copy actions emit it — none
    /// of which is a raw-reuse path, so sensitive spans must stay masked here.
    private var text: String { item.redactedForDisplay(item.content) }
    private var byteCount: Int { text.data(using: .utf8)?.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                qrPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                contentPanel
                    .frame(width: 320)
            }
        }
        .frame(width: 760, height: 500)
        .task(id: item.id) {
            qrImage = QRCodeImageFactory.makeImage(from: text)
            didGenerate = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode")
                .foregroundStyle(Color.appAccent)
            Text(L("qr.title"))
                .font(.system(size: 14, weight: .semibold))

            if didGenerate, qrImage == nil {
                Label(L("qr.unableToGenerate"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(PaperIconButtonStyle(size: 28))
            .help(L("common.close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var qrPanel: some View {
        ZStack {
            Color.appPaper
            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 360, height: 360)
                    .padding(18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.appCardBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
                .padding(24)
            } else {
                VStack(spacing: 10) {
                    if didGenerate {
                        Image(systemName: "qrcode")
                            .font(.system(size: 36, weight: .light))
                        Text(L("qr.unableToGenerate"))
                            .font(.system(size: 12))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("qr.generating"))
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(.secondary)
            }

            if qrImage != nil {
                Button(action: copyQRCodeImage) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(PaperIconButtonStyle(size: 28))
                .help(L("qr.copyImage"))
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var contentPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("qr.sourceText"), systemImage: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(L("qr.byteCountFormat", byteCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button(action: copyText) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(PaperIconButtonStyle(size: 28))
                .help(L("qr.copyText"))
            }

            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appCard.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
            )
        }
        .padding(14)
        .background(Color.appPaper)
    }

    private func copyText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardMonitor.markInternalWrite()
        ToastCenter.shared.show(
            L("common.copied"),
            systemImage: "doc.on.doc",
            tint: .appAccent
        )
    }

    private func copyQRCodeImage() {
        guard let qrImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([qrImage])
        ClipboardMonitor.markInternalWrite()
        ToastCenter.shared.show(
            L("qr.copiedImage"),
            systemImage: "qrcode",
            tint: .appAccent
        )
    }
}
