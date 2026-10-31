import CoreText
import Foundation
import PDFKit
import Translation

// English overlay PDF for non-English scans: each paragraph of the original
// page is covered with its English translation, in place — like Live Text's
// translate overlay on iPhone, but saved as a PDF.
//
// Everything here runs on-device. Translation uses Apple's Translation
// framework with language packs already installed on this Mac; a session
// created with init(installedSource:target:) can't download anything.

// MARK: - Layout

/// OCR lines that read as one paragraph: the unit we translate and redraw.
/// Rects are in upright page points, origin bottom-left.
struct TextBlock {
    var lineRects: [CGRect]
    var texts: [String]

    var rect: CGRect { lineRects.dropFirst().reduce(lineRects[0]) { $0.union($1) } }

    /// Median OCR line height — roughly the original font size.
    var lineHeight: CGFloat {
        let heights = lineRects.map(\.height).sorted()
        return heights[heights.count / 2]
    }

    /// Japanese and Chinese wrap lines mid-sentence without a space;
    /// everything else wraps at spaces.
    func text(language: String) -> String {
        texts.joined(separator: ["ja", "zh"].contains(language) ? "" : " ")
    }
}

func uprightSize(of page: PDFPage, quarterTurns: Int) -> CGSize {
    let size = page.bounds(for: .mediaBox).size
    return quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
}

/// Group OCR lines into paragraphs, in reading order. Vision returns one
/// observation per visual line; translating line by line splits sentences
/// mid-way, so we join lines that continue the paragraph above them.
func groupIntoBlocks(_ lines: [OCRLine], pageSize: CGSize) -> [TextBlock] {
    let placed = lines
        .map { line in
            (text: line.text,
             rect: CGRect(x: line.box.minX * pageSize.width,
                          y: line.box.minY * pageSize.height,
                          width: line.box.width * pageSize.width,
                          height: line.box.height * pageSize.height))
        }
        .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.rect.height > 0 }
        .sorted { $0.rect.maxY != $1.rect.maxY ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX }

    var blocks: [TextBlock] = []
    for line in placed {
        // Attach to the block whose last line sits closest above this one.
        var bestIndex: Int?
        var bestGap = CGFloat.greatestFiniteMagnitude
        for (i, block) in blocks.enumerated() {
            let prev = block.lineRects[block.lineRects.count - 1]
            let prevText = block.texts[block.texts.count - 1]
            guard continuesParagraph(prev: prev, prevText: prevText, next: line.rect) else { continue }
            let gap = prev.minY - line.rect.maxY
            if gap < bestGap {
                bestGap = gap
                bestIndex = i
            }
        }
        if let i = bestIndex {
            blocks[i].lineRects.append(line.rect)
            blocks[i].texts.append(line.text)
        } else {
            blocks.append(TextBlock(lineRects: [line.rect], texts: [line.text]))
        }
    }

    return blocks.sorted {
        $0.rect.maxY != $1.rect.maxY ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX
    }
}

/// Whether `next` continues the paragraph whose last line is `prev`:
/// similar size, directly below, same left edge, and `prev` wrapped
/// (long, running about as far right as `next`, not ending a sentence).
/// Short stacked lines — form labels, addresses, headings — stay separate.
func continuesParagraph(prev: CGRect, prevText: String, next: CGRect) -> Bool {
    let h = max(prev.height, next.height)
    guard min(prev.height, next.height) * 1.5 >= h else { return false }

    let gap = prev.minY - next.maxY
    guard gap > -0.5 * h, gap < 1.0 * h else { return false }

    guard abs(prev.minX - next.minX) < 1.5 * h else { return false }
    guard prev.width > 15 * h, prev.maxX > next.maxX - 1.5 * h else { return false }

    if let last = prevText.trimmingCharacters(in: .whitespaces).last,
       "。．.:：!?！？".contains(last) {
        return false
    }
    return true
}

// MARK: - Translation

struct TranslatedBlock {
    let block: TextBlock
    let english: String?   // nil if left untranslated (no source-language text, or it failed)
}

struct TranslatedPage {
    let scan: PageScan
    let pageSize: CGSize   // upright, in points
    let language: String
    let blocks: [TranslatedBlock]

    var translatedBlockCount: Int { blocks.filter { $0.english != nil }.count }

    /// The page in English, keeping the original for blocks left untranslated.
    var englishText: String {
        blocks.map { $0.english ?? $0.block.text(language: language) }.joined(separator: "\n")
    }
}

@MainActor
struct PageTranslator {
    private let session: TranslationSession
    private let language: String

    /// nil unless the source → English language pair is already installed.
    /// Otherwise the framework would have to ask to download it, which a
    /// background job can't do.
    init?(sourceLanguage: String) async {
        let source = Locale.Language(identifier: sourceLanguage == "zh" ? "zh-Hans" : sourceLanguage)
        let target = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            fputs("  translation: \(sourceLanguage) → English isn't downloaded. Add both in System Settings → General → Language & Region → Translation Languages.\n", stderr)
            return nil
        case .unsupported:
            fputs("  translation: \(sourceLanguage) → English isn't supported by Apple's Translation framework.\n", stderr)
            return nil
        @unknown default:
            fputs("  translation: unexpected availability for \(sourceLanguage) → English (\(status)).\n", stderr)
            return nil
        }
        session = TranslationSession(installedSource: source, target: target)
        language = sourceLanguage
    }

    func translate(_ scan: PageScan, in pdf: PDFDocument) async -> TranslatedPage {
        let size = pdf.page(at: scan.index).map { uprightSize(of: $0, quarterTurns: scan.quarterTurns) } ?? .zero

        var out: [TranslatedBlock] = []
        var failures = 0
        var firstError: Error?
        for block in groupIntoBlocks(scan.lines, pageSize: size) {
            let source = block.text(language: language)
            var english: String?
            if needsTranslation(source) {
                do {
                    let translated = try await session.translate(source).targetText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !translated.isEmpty && translated != source { english = translated }
                } catch {
                    failures += 1
                    firstError = firstError ?? error
                }
            }
            out.append(TranslatedBlock(block: block, english: english))
        }
        if let firstError {
            fputs("  page \(scan.index + 1): \(failures) of \(out.count) blocks failed to translate: \(firstError.localizedDescription)\n", stderr)
        }
        return TranslatedPage(scan: scan, pageSize: size, language: language, blocks: out)
    }

    /// Skip blocks with nothing to translate — numbers, dates, English names.
    /// Those stay as they are on the page.
    private func needsTranslation(_ text: String) -> Bool {
        if ["ja", "zh", "ko"].contains(language) {
            return text.unicodeScalars.contains(where: isCJK)
        }
        return text.filter(\.isLetter).count >= 2
    }
}

// MARK: - Rendering

/// Write an English version of `pdf`: each page upright, with every
/// translated block painted over in the page's own paper color and its
/// English drawn in the same spot, shrunk to fit.
func writeTranslatedPDF(_ pages: [TranslatedPage], from pdf: PDFDocument, to url: URL) throws {
    let info = [kCGPDFContextCreator as String: "folder-to-notes"] as CFDictionary
    guard let ctx = CGContext(url as CFURL, mediaBox: nil, info) else {
        throw NSError(domain: "ScanProcessor", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "Could not create PDF at \(url.path)"])
    }

    for tp in pages {
        guard let page = pdf.page(at: tp.scan.index) else { continue }
        var mediaBox = CGRect(origin: .zero, size: tp.pageSize)
        ctx.beginPage(mediaBox: &mediaBox)

        // The original page, turned upright exactly as it was for OCR.
        let source = page.bounds(for: .mediaBox)
        ctx.saveGState()
        applyQuarterTurns(tp.scan.quarterTurns, sourceSize: source.size, to: ctx)
        ctx.translateBy(x: -source.origin.x, y: -source.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        // The same bitmap OCR saw, for picking paper and ink colors.
        let bitmap = renderPage(page)
            .flatMap { rotate($0, quarterTurns: tp.scan.quarterTurns) }
            .flatMap { Bitmap($0) }

        for item in tp.blocks {
            guard let english = item.english else { continue }
            drawTranslation(english, over: item.block, in: ctx, bitmap: bitmap, pageSize: tp.pageSize)
        }
        ctx.endPage()
    }
    ctx.closePDF()
}

private let minFontSize: CGFloat = 5

private func drawTranslation(_ text: String, over block: TextBlock, in ctx: CGContext,
                             bitmap: Bitmap?, pageSize: CGSize) {
    let rect = block.rect
    let pad = block.lineHeight * 0.15
    var cover = rect.insetBy(dx: -pad, dy: -pad)

    // Match the scan's paper and ink so the patch blends in. Fall back to
    // black or white text if the sampled ink is too close to the paper.
    var paper = RGB.white
    var ink = RGB.black
    if let sampled = bitmap?.colors(in: cover, pageSize: pageSize) {
        paper = sampled.paper
        ink = abs(sampled.paper.luminance - sampled.ink.luminance) >= 0.3
            ? sampled.ink
            : (paper.luminance > 0.5 ? .black : .white)
    }

    let maxFontSize = min(max(block.lineHeight * 0.85, minFontSize), 28)
    let fitted = fitText(text, width: rect.width, height: rect.height,
                         maxFontSize: maxFontSize, color: ink.cgColor)

    // Top-align paragraphs, center single lines. If the English doesn't fit
    // even at the minimum size, let it run below the original block.
    let textRect: CGRect
    if fitted.height > rect.height {
        textRect = CGRect(x: rect.minX, y: rect.maxY - fitted.height, width: rect.width, height: fitted.height)
        cover = cover.union(textRect.insetBy(dx: -pad, dy: -pad))
    } else if block.lineRects.count == 1 {
        textRect = CGRect(x: rect.minX, y: rect.midY - fitted.height / 2, width: rect.width, height: fitted.height)
    } else {
        textRect = CGRect(x: rect.minX, y: rect.maxY - fitted.height, width: rect.width, height: fitted.height)
    }

    ctx.setFillColor(paper.cgColor)
    ctx.fill(cover)

    let frame = CTFramesetterCreateFrame(fitted.framesetter, CFRange(location: 0, length: 0),
                                         CGPath(rect: textRect, transform: nil), nil)
    ctx.saveGState()
    ctx.textMatrix = .identity
    CTFrameDraw(frame, ctx)
    ctx.restoreGState()
}

/// Lay out `text` at the largest font size (up to `maxFontSize`) whose
/// wrapped height fits in `height`. If nothing fits, returns the layout at
/// the minimum size, whose height will exceed `height`.
private func fitText(_ text: String, width: CGFloat, height: CGFloat,
                     maxFontSize: CGFloat, color: CGColor) -> (framesetter: CTFramesetter, height: CGFloat) {
    func layout(_ size: CGFloat) -> (framesetter: CTFramesetter, height: CGFloat) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        // +1 so rounding never drops the last line.
        return (framesetter, ceil(suggested.height) + 1)
    }

    let largest = layout(maxFontSize)
    if largest.height <= height { return largest }

    var best = layout(minFontSize)
    guard best.height <= height else { return best }

    var lo = minFontSize
    var hi = maxFontSize
    for _ in 0..<8 {
        let mid = (lo + hi) / 2
        let attempt = layout(mid)
        if attempt.height <= height {
            best = attempt
            lo = mid
        } else {
            hi = mid
        }
    }
    return best
}

// MARK: - Color sampling

struct RGB {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 1, g: 1, b: 1)

    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// A page bitmap we can read pixels from.
struct Bitmap {
    let width: Int
    let height: Int
    private let pixels: [UInt8]   // RGBA, top row first

    init?(_ image: CGImage) {
        let w = image.width
        let h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: buffer.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        pixels = data
    }

    /// Paper color (average of the lighter half) and ink color (average of
    /// the darkest 15%) of the pixels under `rect`, given in page points.
    func colors(in rect: CGRect, pageSize: CGSize) -> (paper: RGB, ink: RGB)? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let sx = CGFloat(width) / pageSize.width
        let sy = CGFloat(height) / pageSize.height
        let x0 = max(0, Int(rect.minX * sx)), x1 = min(width, Int(rect.maxX * sx))
        let y0 = max(0, Int(rect.minY * sy)), y1 = min(height, Int(rect.maxY * sy))
        guard x1 > x0, y1 > y0 else { return nil }

        // Sample at most ~4000 pixels.
        let step = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 4000).squareRoot()))
        var samples: [RGB] = []
        for y in stride(from: y0, to: y1, by: step) {
            let row = height - 1 - y   // page y runs up; bitmap rows run down
            for x in stride(from: x0, to: x1, by: step) {
                let i = (row * width + x) * 4
                samples.append(RGB(r: CGFloat(pixels[i]) / 255,
                                   g: CGFloat(pixels[i + 1]) / 255,
                                   b: CGFloat(pixels[i + 2]) / 255))
            }
        }
        samples.sort { $0.luminance < $1.luminance }

        let paper = average(samples[(samples.count / 2)...])
        let ink = average(samples[..<max(1, samples.count * 15 / 100)])
        return (paper, ink)
    }

    private func average(_ colors: ArraySlice<RGB>) -> RGB {
        let n = CGFloat(colors.count)
        return RGB(r: colors.reduce(0) { $0 + $1.r } / n,
                   g: colors.reduce(0) { $0 + $1.g } / n,
                   b: colors.reduce(0) { $0 + $1.b } / n)
    }
}
