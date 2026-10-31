import AppKit
import Foundation
import NaturalLanguage
import PDFKit
import Vision
import FoundationModels

// MARK: - Structured output
//
// NOTE: We intentionally avoid the @Generable / @Guide macros here, because
// their implementation (the FoundationModelsMacros plugin) ships only with
// full Xcode — not with the Command Line Tools. Instead we ask the model for
// JSON and decode it ourselves.

struct DocumentAnalysis: Codable {
    var title: String
    var summary: String
    var keywords: [String]
}

// MARK: - PDF rendering

func renderPage(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
    let mediaBox = page.bounds(for: .mediaBox)
    let width = Int(mediaBox.width * scale)
    let height = Int(mediaBox.height * scale)

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }

    // White background
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Scale + shift for PDF coordinate origin
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)

    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

/// Transform `ctx` so that content drawn in a `size`-sized box at the origin
/// comes out rotated clockwise by `quarterTurns` × 90°, filling the rotated
/// bounds. Shared by the bitmap rotation below and the translated-PDF
/// writer, so OCR coordinates and the redrawn page always line up.
func applyQuarterTurns(_ quarterTurns: Int, sourceSize size: CGSize, to ctx: CGContext) {
    switch quarterTurns {
    case 1:
        ctx.translateBy(x: 0, y: size.width)
        ctx.rotate(by: -.pi / 2)
    case 2:
        ctx.translateBy(x: size.width, y: size.height)
        ctx.rotate(by: .pi)
    case 3:
        ctx.translateBy(x: size.height, y: 0)
        ctx.rotate(by: .pi / 2)
    default:
        break
    }
}

func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
    if quarterTurns == 0 { return image }
    let size = CGSize(width: image.width, height: image.height)
    let (outW, outH) = quarterTurns % 2 == 0 ? (image.width, image.height) : (image.height, image.width)

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }

    applyQuarterTurns(quarterTurns, sourceSize: size, to: ctx)
    ctx.draw(image, in: CGRect(origin: .zero, size: size))
    return ctx.makeImage()
}

// MARK: - OCR

struct OCRLine {
    let text: String
    let box: CGRect   // normalized to the image, origin bottom-left (Vision's convention)
}

/// Run a text-recognition request on an upright image and return the
/// recognized lines plus average confidence and total characters.
func recognizeText(
    cgImage: CGImage,
    level: VNRequestTextRecognitionLevel
) throws -> (lines: [OCRLine], confidence: Float, chars: Int) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.usesLanguageCorrection = (level == .accurate)
    // Recognize English + Japanese. Vision auto-detects which to use per
    // observation. Adding Japanese is essentially free for English-only
    // documents but enables OCR on Japanese scans.
    //
    // IMPORTANT: Japanese (and other CJK) recognition requires a recent
    // request revision. Pin to the latest revision the runtime supports
    // for this request type so CLT-based builds don't silently fall back
    // to an older Latin-only revision.
    let supported = VNRecognizeTextRequest.supportedRevisions
    if let latest = supported.max() {
        request.revision = latest
    }
    // Only ask for languages this level/revision supports — the fast
    // recognizer handles Latin scripts only.
    let wanted = ["en-US", "ja-JP"]
    if let available = try? request.supportedRecognitionLanguages() {
        let usable = wanted.filter { available.contains($0) }
        if !usable.isEmpty { request.recognitionLanguages = usable }
    } else {
        request.recognitionLanguages = wanted
    }
    request.automaticallyDetectsLanguage = true

    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
    try handler.perform([request])

    var lines: [OCRLine] = []
    var confSum: Float = 0
    var chars = 0
    for o in request.results ?? [] {
        guard let cand = o.topCandidates(1).first else { continue }
        lines.append(OCRLine(text: cand.string, box: o.boundingBox))
        confSum += cand.confidence
        chars += cand.string.count
    }
    let confidence = lines.isEmpty ? 0 : confSum / Float(lines.count)
    return (lines, confidence, chars)
}

/// Determine which of the 4 cardinal orientations a scanned page is in by
/// running a quick text-recognition pass at each. Vision's recognizer is
/// good enough that it can read upside-down or sideways text, so the raw
/// character counts upright vs 180° are often close. We therefore strongly
/// bias toward upright: a rotation only "wins" if it produces noticeably
/// more text AND noticeably higher confidence than upright.
///
/// Returns the clockwise quarter turns that make the page upright, and the
/// image rotated by that much.
func detectOrientation(cgImage: CGImage) -> (quarterTurns: Int, image: CGImage) {
    // Score upright first as the baseline.
    guard let upScore = try? recognizeText(cgImage: cgImage, level: .fast) else {
        return (0, cgImage)
    }

    // Heuristics for "this rotation is clearly better than upright":
    //   - at least 30% more recognized characters, AND
    //   - at least 0.05 higher average confidence
    // Tuned so that an actually-rotated page (where upright produces
    // mostly garbage) still flips, but a clean upright page never does.
    let charMargin: Double = 1.30
    let confMargin: Float = 0.05

    var best: (quarterTurns: Int, image: CGImage, chars: Int, confidence: Float) =
        (0, cgImage, upScore.chars, upScore.confidence)

    for turns in 1...3 {
        guard let rotated = rotate(cgImage, quarterTurns: turns),
              let r = try? recognizeText(cgImage: rotated, level: .fast) else {
            continue
        }
        let charsBetter = Double(r.chars) >= Double(upScore.chars) * charMargin
        let confBetter  = r.confidence    >= upScore.confidence    + confMargin
        // Also require it to beat the current non-upright best, if any.
        let beatsBest   = r.chars > best.chars ||
                          (r.chars == best.chars && r.confidence > best.confidence)
        if charsBetter && confBetter && beatsBest {
            best = (turns, rotated, r.chars, r.confidence)
        }
    }
    return (best.quarterTurns, best.image)
}

struct PageScan {
    let index: Int          // page index in the source PDF
    let quarterTurns: Int   // clockwise rotation applied to make the page upright
    let lines: [OCRLine]    // boxes normalized to the upright page

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

func scanPages(of pdf: PDFDocument) throws -> [PageScan] {
    var pages: [PageScan] = []

    for i in 0..<pdf.pageCount {
        guard let page = pdf.page(at: i),
              let cgImage = renderPage(page) else { continue }

        // Auto-rotate: detect the correct orientation per page (handles
        // upside-down scans and landscape sheets), then OCR the upright
        // image with the high-accuracy recognizer.
        let (turns, upright) = detectOrientation(cgImage: cgImage)
        if turns != 0 {
            let labels = [1: "90° CW", 2: "180°", 3: "90° CCW"]
            fputs("  page \(i + 1): rotating \(labels[turns] ?? "?") to upright\n", stderr)
        }

        let result = try recognizeText(cgImage: upright, level: .accurate)
        pages.append(PageScan(index: i, quarterTurns: turns, lines: result.lines))
    }

    return pages
}

// MARK: - AI analysis

/// Strip OCR noise (typically misread barcodes, QR codes, and decorative
/// glyphs) so the language model sees mostly real prose. Foundation Models'
/// language detector throws "unsupported language or locale" if the input
/// is dominated by garbage tokens — even when most of the document is
/// perfectly normal English further down the page.
///
/// Heuristic: keep a line if it looks like natural language. We require
///   - at least 3 letters total, AND
///   - at least 60% of non-space characters are letters/digits/basic punct, AND
///   - it contains at least one word ≥ 3 letters long
func sanitizeOCRText(_ text: String) -> String {
    func isWordy(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }

        var letters = 0
        var sane = 0
        var nonSpace = 0
        for ch in trimmed {
            if ch.isWhitespace { continue }
            nonSpace += 1
            if ch.isLetter { letters += 1; sane += 1 }
            else if ch.isNumber { sane += 1 }
            else if ".,;:!?'\"()[]/-$%&@#".contains(ch) { sane += 1 }
        }
        guard letters >= 3, nonSpace > 0 else { return false }
        guard Double(sane) / Double(nonSpace) >= 0.60 else { return false }

        // Require at least one "real" word (3+ consecutive letters).
        let words = trimmed.split(whereSeparator: { !$0.isLetter })
        return words.contains(where: { $0.count >= 3 })
    }

    let kept = text.split(whereSeparator: \.isNewline).filter { isWordy(String($0)) }
    return kept.joined(separator: "\n")
}

func analyzeDocument(text: String, filename: String) async throws -> DocumentAnalysis {
    let model = SystemLanguageModel.default
    guard model.availability == .available else {
        throw NSError(domain: "ScanProcessor", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Foundation Models unavailable (\(model.availability)). Is Apple Intelligence enabled in System Settings?"])
    }

    // Strip OCR garbage (barcodes, decorative glyphs) before sending. Falls
    // back to the raw text only if sanitization removed essentially everything.
    let cleaned = sanitizeOCRText(text)
    let usable = cleaned.count >= 40 ? cleaned : text

    // Try progressively shorter excerpts. Apple's on-device model surfaces
    // safety-guardrail rejections (common on financial/PII content) as a
    // generic "unsupported language or locale" error — and a smaller
    // header-only excerpt usually slips through where the full first 4000
    // chars trip it.
    let attempts: [(label: String, length: Int)] = [
        ("full",  4000),
        ("short", 800),
        ("tiny",  300),
    ]

    var lastError: Error?
    for attempt in attempts {
        do {
            return try await runAnalysis(text: usable, filename: filename,
                                         maxLen: attempt.length)
        } catch {
            lastError = error
            fputs("[\(filename)] AI attempt '\(attempt.label)' failed: \(error.localizedDescription) — retrying with smaller excerpt.\n", stderr)
        }
    }
    throw lastError ?? NSError(domain: "ScanProcessor", code: 5,
                               userInfo: [NSLocalizedDescriptionKey: "AI analysis failed for unknown reason."])
}

private func runAnalysis(text: String, filename: String, maxLen: Int) async throws -> DocumentAnalysis {
    let session = LanguageModelSession {
        """
        You are a document analyst helping organize a personal document archive. \
        Given OCR-extracted text from a scanned document, produce a clear title, \
        a concise summary, and relevant keywords. \
        Focus on actual content. If OCR quality is poor, do your best with available text.

        Always respond with a single JSON object — no prose, no code fences — \
        matching exactly this schema:
        {
          "title": String,        // 5–10 word descriptive title inferred from content (not filename)
          "summary": String,      // 2–3 sentences summarizing key content, purpose, dates, names, amounts
          "keywords": [String]    // 5–8 short keyword/topic tags
        }
        """
    }

    let excerpt = text.isEmpty
        ? "(No text could be extracted — document may be blank or purely graphical.)"
        : String(text.prefix(maxLen))

    let prompt = """
    Filename: \(filename)

    Extracted text:
    \(excerpt)

    Respond with the JSON object only.
    """

    let response = try await session.respond(to: prompt)
    let raw = response.content

    // Strip optional code fences and isolate the JSON object.
    var jsonString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let start = jsonString.firstIndex(of: "{"),
       let end = jsonString.lastIndex(of: "}") {
        jsonString = String(jsonString[start...end])
    }

    guard let data = jsonString.data(using: .utf8) else {
        throw NSError(domain: "ScanProcessor", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Could not encode model response as UTF-8."])
    }

    do {
        return try JSONDecoder().decode(DocumentAnalysis.self, from: data)
    } catch {
        throw NSError(domain: "ScanProcessor", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Could not decode model JSON: \(error.localizedDescription). Raw output: \(raw)"])
    }
}

// MARK: - Fallback metadata

/// Build a sensible DocumentAnalysis from just the filename + raw OCR text,
/// for cases when the AI model fails (unsupported language, guardrails,
/// network/availability issues, garbled OCR, etc.). The note still gets
/// created and the PDF still gets attached — just without the nice summary.
func fallbackAnalysis(text: String, filename: String, reason: String) -> DocumentAnalysis {
    // Prefer a title pulled from the cleaned OCR text — the filename is
    // often garbage on documents that trigger this path (scanner-generated
    // names full of barcode noise).
    let cleaned = sanitizeOCRText(text)
    let firstLine = cleaned
        .split(whereSeparator: \.isNewline)
        .first
        .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""

    let title: String
    if firstLine.count >= 5 {
        title = String(firstLine.prefix(80))
    } else {
        let base = (filename as NSString).deletingPathExtension
        let cleanedName = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        title = cleanedName.isEmpty ? filename : cleanedName
    }

    let snippet = cleaned.isEmpty
        ? "(No text could be extracted from this document.)"
        : String(cleaned.prefix(400))
    let summary = "AI analysis unavailable (\(reason)). First text excerpt: \(snippet)"

    return DocumentAnalysis(title: title, summary: summary, keywords: ["unanalyzed"])
}

// MARK: - Translation

/// Hiragana, Katakana, CJK Unified Ideographs, or Hangul Syllables.
func isCJK(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    return (0x3040...0x30FF).contains(v) ||      // Hiragana + Katakana
           (0x4E00...0x9FFF).contains(v) ||      // CJK Unified
           (0xAC00...0xD7AF).contains(v)         // Hangul
}

/// Detect the dominant language of the OCR'd text. Returns a BCP-47
/// language code (e.g., "en", "ja", "de") or nil if the text is English
/// or detection isn't confident enough to act on.
///
/// NLLanguageRecognizer is trained on clean prose and gets fooled by
/// noisy OCR — short snippets, mixed-language headers, and stray symbols
/// will often produce a confident-looking-but-wrong guess (e.g. Italian
/// or Catalan for English-with-some-Japanese-headers documents). We
/// counter that with three guardrails:
///   1. Strip non-letter noise so we score on real words.
///   2. Constrain hints to a realistic candidate set — heavy English
///      prior plus the major non-Latin scripts we actually care about.
///   3. Require high confidence for a non-English verdict, and require
///      English to be a distant runner-up. Otherwise: treat as English.
func detectLanguage(_ text: String) -> String? {
    // Use a generous sample so short docs still get a stable signal.
    let sample = String(text.prefix(4000))

    // Heuristic shortcut: if the sample contains a meaningful amount of
    // CJK / Hangul characters, trust the script over the recognizer.
    // Catches mixed docs like "mostly English with a Japanese header"
    // where we DON'T want to translate, and pure-Japanese docs where
    // we DO. Threshold: at least 40 CJK chars AND >= 15% of total letters.
    let scalars = sample.unicodeScalars
    var cjkCount = 0
    var letterCount = 0
    for s in scalars {
        if s.properties.isAlphabetic { letterCount += 1 }
        if isCJK(s) { cjkCount += 1 }
    }
    let cjkRatio = letterCount > 0 ? Double(cjkCount) / Double(letterCount) : 0
    fputs("  language detect: \(letterCount) letters, \(cjkCount) CJK (\(String(format: "%.0f%%", cjkRatio * 100)))\n", stderr)
    if cjkCount >= 40 && cjkRatio >= 0.15 {
        // Distinguish ja vs zh vs ko by which range dominates.
        var ja = 0, zh = 0, ko = 0
        for s in scalars {
            let v = s.value
            if (0x3040...0x30FF).contains(v) { ja += 1 }
            else if (0x4E00...0x9FFF).contains(v) { zh += 1 } // could be either
            else if (0xAC00...0xD7AF).contains(v) { ko += 1 }
        }
        if ko > ja && ko > zh { return "ko" }
        if ja > 0 { return "ja" }     // any kana -> Japanese
        if zh > 0 { return "zh" }
        return "ja"
    }

    let recognizer = NLLanguageRecognizer()
    // Bias heavily toward English; only consider a small set of
    // languages we'd plausibly see and want to translate.
    recognizer.languageHints = [
        .english:    0.7,
        .japanese:   0.1,
        .simplifiedChinese: 0.05,
        .korean:     0.05,
        .german:     0.025,
        .french:     0.025,
        .spanish:    0.025,
        .portuguese: 0.025,
    ]
    recognizer.processString(sample)

    let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
    guard let dominant = recognizer.dominantLanguage else { return nil }

    let hypString = hypotheses.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
    fputs("  language detect: dominant=\(dominant.rawValue) hypotheses=[\(hypString)]\n", stderr)

    // If English is even a plausible candidate, treat as English.
    let englishScore = hypotheses[.english] ?? 0
    if dominant == .english || englishScore >= 0.25 { return nil }

    // Require strong confidence for a non-English verdict.
    let topScore = hypotheses[dominant] ?? 0
    guard topScore >= 0.85 else { return nil }

    return dominant.rawValue
}

/// Translate non-English OCR text to English using Foundation Models.
/// Returns nil if translation fails for any reason — caller should treat
/// translation as best-effort and not block note creation on it.
func translateToEnglish(text: String, sourceLanguage: String) async -> String? {
    let model = SystemLanguageModel.default
    guard model.availability == .available else { return nil }

    // Map common ISO codes to friendly names so the model knows what to do.
    let langName: String = {
        switch sourceLanguage {
        case "ja":      return "Japanese"
        case "zh", "zh-Hans", "zh-Hant": return "Chinese"
        case "ko":      return "Korean"
        case "de":      return "German"
        case "fr":      return "French"
        case "es":      return "Spanish"
        case "it":      return "Italian"
        case "pt":      return "Portuguese"
        case "ru":      return "Russian"
        default:        return sourceLanguage
        }
    }()

    let session = LanguageModelSession {
        """
        You are a professional translator. Translate the user's text from \
        \(langName) into clear, natural English. Preserve paragraph breaks \
        and the original meaning. Output only the translation — no notes, \
        no commentary, no preamble.
        """
    }

    // Cap at ~3000 chars to stay well within the context window after the
    // English output has been generated.
    let excerpt = String(text.prefix(3000))

    do {
        let response = try await session.respond(to: excerpt)
        let translated = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? nil : translated
    } catch {
        fputs("  translation failed: \(error.localizedDescription)\n", stderr)
        return nil
    }
}

// MARK: - Output

struct Output: Codable {
    let title: String
    let summary: String
    let keywords: [String]
    let sourceLanguage: String?  // BCP-47, only set when non-English
    let translation: String?     // English translation, only set when non-English
    let translatedPdf: String?   // English overlay PDF path, only set when one was written
}

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count > 1 else {
    fputs("Usage: process_scan <path-to-pdf> [--translated-pdf <output.pdf>]\n", stderr)
    exit(1)
}

let pdfPath = args[1]
let pdfURL = URL(fileURLWithPath: pdfPath)
let filename = pdfURL.lastPathComponent

// Where to write an English overlay PDF if the document isn't in English.
let translatedPDFPath: String? = {
    guard let i = args.firstIndex(of: "--translated-pdf"), i + 1 < args.count else { return nil }
    return args[i + 1]
}()

/// Translate non-English pages with Apple's on-device Translation framework,
/// and write the English overlay PDF if asked to. Returns the English text,
/// or nil if the language pair isn't installed or nothing translated.
@MainActor
func translatePages(_ pages: [PageScan], of pdf: PDFDocument, language: String) async
    -> (text: String, pdfPath: String?)? {
    guard let translator = await PageTranslator(sourceLanguage: language) else { return nil }

    var translated: [TranslatedPage] = []
    for scan in pages {
        translated.append(await translator.translate(scan, in: pdf))
    }
    guard translated.contains(where: { $0.translatedBlockCount > 0 }) else { return nil }

    let text = translated.map(\.englishText).filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")

    var pdfPath: String?
    if let out = translatedPDFPath {
        do {
            try writeTranslatedPDF(translated, from: pdf, to: URL(fileURLWithPath: out))
            pdfPath = out
        } catch {
            fputs("[\(filename)] Could not write English PDF: \(error.localizedDescription)\n", stderr)
        }
    }
    return (text, pdfPath)
}

@MainActor
func run() async -> Int32 {
    do {
        guard let pdf = PDFDocument(url: pdfURL) else {
            throw NSError(domain: "ScanProcessor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not load PDF at \(pdfURL.path)"])
        }

        fputs("[\(filename)] Extracting text via OCR...\n", stderr)
        let pages = try scanPages(of: pdf)
        let text = pages.map(\.text).filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect language. Anything other than English (or unknown) gets
        // translated. We do this before the analysis step so the translated
        // English text drives summarization — better titles + summaries.
        var sourceLang: String? = nil
        var translation: String? = nil
        var translatedPDF: String? = nil
        var textForAnalysis = text
        if let lang = detectLanguage(text), lang != "en", !text.isEmpty {
            sourceLang = lang
            fputs("[\(filename)] Detected non-English content (\(lang)) — translating...\n", stderr)
            // Prefer the Translation framework: it's a dedicated translator
            // and works paragraph by paragraph, which is what lets us redraw
            // the pages in English. Without the language pack installed,
            // fall back to Foundation Models (text only, no PDF).
            if let result = await translatePages(pages, of: pdf, language: lang) {
                translation = result.text
                translatedPDF = result.pdfPath
            } else {
                fputs("[\(filename)] Translation framework unavailable — translating text with Foundation Models.\n", stderr)
                translation = await translateToEnglish(text: text, sourceLanguage: lang)
            }
            if let translation {
                textForAnalysis = translation
            } else {
                fputs("[\(filename)] Translation unavailable — analyzing original text.\n", stderr)
            }
        }

        fputs("[\(filename)] Analysing with Foundation Models...\n", stderr)
        let analysis: DocumentAnalysis
        do {
            analysis = try await analyzeDocument(text: textForAnalysis, filename: filename)
        } catch {
            // Don't lose the file just because the model choked. Common causes:
            // unsupported language/locale, safety guardrails, garbled OCR.
            // Fall back to filename-derived metadata so the note still lands.
            fputs("[\(filename)] AI analysis failed: \(error.localizedDescription) — using filename-only fallback.\n", stderr)
            analysis = fallbackAnalysis(text: textForAnalysis, filename: filename,
                                        reason: error.localizedDescription)
        }

        let output = Output(
            title: analysis.title,
            summary: analysis.summary,
            keywords: analysis.keywords,
            sourceLanguage: sourceLang,
            translation: translation,
            translatedPdf: translatedPDF
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let json = try encoder.encode(output)
        print(String(data: json, encoding: .utf8)!)
        return 0
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

// Run on the main actor and keep the main queue serviced (rather than
// blocking it on a semaphore), so frameworks that call back on the main
// thread can't deadlock us.
Task { @MainActor in
    let code = await run()
    exit(code)
}
dispatchMain()
