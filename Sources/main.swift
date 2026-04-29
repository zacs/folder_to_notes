import AppKit
import Foundation
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

// MARK: - OCR

/// Run a text-recognition request at the given orientation and return
/// (recognized text, average confidence, total characters).
func recognizeText(
    cgImage: CGImage,
    orientation: CGImagePropertyOrientation,
    level: VNRequestTextRecognitionLevel
) throws -> (text: String, confidence: Float, chars: Int) {
    var pageText = ""
    var confidence: Float = 0
    var chars = 0
    let sema = DispatchSemaphore(value: 0)

    let request = VNRecognizeTextRequest { req, _ in
        defer { sema.signal() }
        guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
        var lines: [String] = []
        var confSum: Float = 0
        var confCount = 0
        for o in obs {
            guard let cand = o.topCandidates(1).first else { continue }
            lines.append(cand.string)
            confSum += cand.confidence
            confCount += 1
            chars += cand.string.count
        }
        pageText = lines.joined(separator: "\n")
        confidence = confCount > 0 ? confSum / Float(confCount) : 0
    }
    request.recognitionLevel = level
    request.usesLanguageCorrection = (level == .accurate)

    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    try handler.perform([request])
    sema.wait()

    return (pageText, confidence, chars)
}

/// Determine which of the 4 cardinal orientations a scanned page is in by
/// running a quick text-recognition pass at each. Vision's recognizer is
/// good enough that it can read upside-down or sideways text, so the raw
/// character counts at .up vs .down are often close. We therefore strongly
/// bias toward .up: a non-up orientation only "wins" if it produces
/// noticeably more text AND noticeably higher confidence than upright.
func detectOrientation(cgImage: CGImage) -> CGImagePropertyOrientation {
    // Score .up first as the baseline.
    guard let upScore = try? recognizeText(cgImage: cgImage, orientation: .up, level: .fast) else {
        return .up
    }

    // Heuristics for "this rotation is clearly better than upright":
    //   - at least 30% more recognized characters, AND
    //   - at least 0.05 higher average confidence
    // Tuned so that an actually-rotated page (where upright produces
    // mostly garbage) still flips, but a clean upright page never does.
    let charMargin: Double = 1.30
    let confMargin: Float = 0.05

    var best: (orientation: CGImagePropertyOrientation, chars: Int, confidence: Float) =
        (.up, upScore.chars, upScore.confidence)

    for o in [CGImagePropertyOrientation.right, .down, .left] {
        guard let r = try? recognizeText(cgImage: cgImage, orientation: o, level: .fast) else {
            continue
        }
        let charsBetter = Double(r.chars) >= Double(upScore.chars) * charMargin
        let confBetter  = r.confidence    >= upScore.confidence    + confMargin
        // Also require it to beat the current non-up best, if any.
        let beatsBest   = r.chars > best.chars ||
                          (r.chars == best.chars && r.confidence > best.confidence)
        if charsBetter && confBetter && beatsBest {
            best = (o, r.chars, r.confidence)
        }
    }
    return best.orientation
}

func extractText(from pdfURL: URL) throws -> String {
    guard let pdf = PDFDocument(url: pdfURL) else {
        throw NSError(domain: "ScanProcessor", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not load PDF at \(pdfURL.path)"])
    }

    var pages: [String] = []

    for i in 0..<pdf.pageCount {
        guard let page = pdf.page(at: i),
              let cgImage = renderPage(page) else { continue }

        // Auto-rotate: detect the correct orientation per page (handles
        // upside-down scans and landscape sheets), then OCR at that
        // orientation with the high-accuracy recognizer.
        let orientation = detectOrientation(cgImage: cgImage)
        if orientation != .up {
            let labels: [CGImagePropertyOrientation: String] =
                [.right: "90° CW", .down: "180°", .left: "90° CCW"]
            fputs("  page \(i + 1): rotated \(labels[orientation] ?? "?") — auto-correcting\n", stderr)
        }

        let result = try recognizeText(cgImage: cgImage, orientation: orientation, level: .accurate)
        if !result.text.isEmpty { pages.append(result.text) }
    }

    return pages.joined(separator: "\n\n---\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - AI analysis

func analyzeDocument(text: String, filename: String) async throws -> DocumentAnalysis {
    let model = SystemLanguageModel.default
    guard model.availability == .available else {
        throw NSError(domain: "ScanProcessor", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Foundation Models unavailable (\(model.availability)). Is Apple Intelligence enabled in System Settings?"])
    }

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

    // Trim to ~4000 chars — well within the on-device model's context window
    let excerpt = text.isEmpty
        ? "(No text could be extracted — document may be blank or purely graphical.)"
        : String(text.prefix(4000))

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

// MARK: - Output

struct Output: Codable {
    let title: String
    let summary: String
    let keywords: [String]
}

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count > 1 else {
    fputs("Usage: process_scan <path-to-pdf>\n", stderr)
    exit(1)
}

let pdfPath = args[1]
let pdfURL = URL(fileURLWithPath: pdfPath)
let filename = pdfURL.lastPathComponent

let sema = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    defer { sema.signal() }
    do {
        fputs("[\(filename)] Extracting text via OCR...\n", stderr)
        let text = try extractText(from: pdfURL)

        fputs("[\(filename)] Analysing with Foundation Models...\n", stderr)
        let analysis = try await analyzeDocument(text: text, filename: filename)

        let output = Output(title: analysis.title, summary: analysis.summary, keywords: analysis.keywords)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let json = try encoder.encode(output)
        print(String(data: json, encoding: .utf8)!)
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exitCode = 1
    }
}

sema.wait()
exit(exitCode)
