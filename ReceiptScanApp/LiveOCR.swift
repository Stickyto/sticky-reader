import Foundation
import AVFoundation
import Vision
import UIKit
import CoreImage

@MainActor
final class LiveOCR: NSObject, ObservableObject {
  enum State { case findingROI, unstable, processing, ready }

  @Published var state: State = .findingROI
  @Published var stableText: String?

  // Capture
  let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "ocr.capture")
  private var permissionGranted = false

  // Auto stability (still available)
  private let windowSize = 6
  private let jaccardThreshold = 0.90
  private let minLinesToTrigger = 4
  private let fireCooldown: TimeInterval = 1.0
  private var lastFire: TimeInterval = 0

  // Scene-change & dedupe (auto mode)
  private var textWindow: [[String]] = []
  private var lastSignature: Set<String>? = nil
  private var lastRect: CGRect? = nil
  private let rectIouResetThreshold: CGFloat = 0.65
  private let signatureRepeatThreshold: Double = 0.80

  // One-shot trigger
  private var forceCapture = false

  // Vision requests
  private lazy var textFast: VNRecognizeTextRequest = {
    let r = VNRecognizeTextRequest(completionHandler: nil)
    r.recognitionLevel = .fast
    r.usesLanguageCorrection = false
    r.minimumTextHeight = 0.02
    // Optional: r.recognitionLanguages = ["en-US","en-GB"]
    return r
  }()

  private lazy var textAccurate: VNRecognizeTextRequest = {
    let r = VNRecognizeTextRequest(completionHandler: nil)
    r.recognitionLevel = .accurate
    r.usesLanguageCorrection = false
    r.minimumTextHeight = 0.01
    // Optional: r.recognitionLanguages = ["en-US","en-GB"]
    return r
  }()

  private lazy var rectRequest: VNDetectRectanglesRequest = {
    let r = VNDetectRectanglesRequest()
    r.minimumAspectRatio = 0.2
    r.maximumObservations = 1
    r.minimumSize = 0.2
    return r
  }()

  // MARK: - Public

  func start() async {
    guard await requestPermission() else { return }
    configureSession()
    session.startRunning()
  }

  func reset() {
    textWindow.removeAll()
    lastSignature = nil
    lastRect = nil
    stableText = nil
    state = .findingROI
  }

  /// Force a one-shot OCR of the next incoming frame (no debouncing)
  func scanNow() {
    forceCapture = true
  }

  // MARK: - Permissions & Session

  private func requestPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      permissionGranted = true
    case .notDetermined:
      permissionGranted = await withCheckedContinuation { cont in
        AVCaptureDevice.requestAccess(for: .video) { granted in
          cont.resume(returning: granted)
        }
      }
    default:
      permissionGranted = false
    }
    if !permissionGranted {
      state = .findingROI
    }
    return permissionGranted
  }

  private func configureSession() {
    session.beginConfiguration()
    session.sessionPreset = .high

    guard
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: device)
    else { return }

    if session.canAddInput(input) { session.addInput(input) }

    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ]
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

    if let conn = videoOutput.connections.first, conn.isVideoOrientationSupported {
      conn.videoOrientation = .portrait
    }

    session.commitConfiguration()
  }

  // MARK: - Frame Handling

  private func handle(pixelBuffer: CVPixelBuffer, forced: Bool) {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])

    var roiCG: CGImage?
    var roiSize: CGSize = .zero

    do {
      try handler.perform([rectRequest])
      if let rect = rectRequest.results?.first as? VNRectangleObservation {
        let bbox = rect.boundingBox
        if !forced, let prev = lastRect, iou(prev, bbox) < rectIouResetThreshold {
          textWindow.removeAll()
          lastSignature = nil
          setStateIfNeeded(.unstable)
        }
        lastRect = bbox

        if let warped = ciImage.warped(to: bbox) {
          roiCG = warped.toCGImage()
          roiSize = CGSize(width: warped.extent.width, height: warped.extent.height)
          if !forced { setStateIfNeeded(.unstable) }
        }
      }

      if roiCG == nil {
        let ctx = CIContext()
        roiCG = ctx.createCGImage(ciImage, from: ciImage.extent)
        roiSize = CGSize(width: ciImage.extent.width, height: ciImage.extent.height)
        if !forced { setStateIfNeeded(.unstable) }
      }
    } catch {
      return
    }

    guard let cg = roiCG, roiSize != .zero else { return }

    let textHandler = VNImageRequestHandler(cgImage: cg, options: [:])
    let request = forced ? textAccurate : textFast

    do {
      try textHandler.perform([request])

      // Use observations so we can sort by geometry.
      let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
      let orderedLines = readingOrderLines(from: observations, roiSize: roiSize)

      if forced {
        let plain = orderedLines.joined(separator: "\n")
        DispatchQueue.main.async {
          self.stableText = plain
          self.state = .ready
          self.textWindow.removeAll()
          self.lastSignature = Set(orderedLines)
        }
      } else {
        // Auto mode uses stability window but now with ordered lines
        updateStability(lines: orderedLines)
      }
    } catch {
      return
    }
  }

  // MARK: - Reading order

  /// Convert observations to text lines sorted top→bottom, left→right.
  private func readingOrderLines(from obs: [VNRecognizedTextObservation], roiSize: CGSize) -> [String] {
    // Build (text, rect) with pixel-space rects (origin: top-left for convenience)
    struct Box { let text: String; let rect: CGRect }

    let w = roiSize.width, h = roiSize.height

    var boxes: [Box] = []
    boxes.reserveCapacity(obs.count)

    for o in obs {
      guard let txt = o.topCandidates(1).first?.string else { continue }
      let bb = o.boundingBox // normalized, origin bottom-left
      // convert to pixel rect with origin top-left
      let x = bb.minX * w
      let yTop = (1.0 - bb.maxY) * h
      let rect = CGRect(x: x, y: yTop, width: bb.width * w, height: bb.height * h)
      let norm = normalize(txt)
      if !norm.isEmpty {
        boxes.append(Box(text: norm, rect: rect))
      }
    }

    guard !boxes.isEmpty else { return [] }

    // Group into rows by y using a dynamic threshold based on median height
    let heights = boxes.map { $0.rect.height }.sorted()
    let medianH = heights[heights.count / 2]
    let rowThresh = max(6.0, Double(medianH) * 0.6) // pixels

    // Sort by top y, then left x
    let sorted = boxes.sorted { a, b in
      if abs(a.rect.minY - b.rect.minY) > rowThresh {
        return a.rect.minY < b.rect.minY // top to bottom
      } else {
        return a.rect.minX < b.rect.minX // left to right within row
      }
    }

    // Merge tokens that sit on the same row into a single line string.
    var lines: [String] = []
    var currentY: CGFloat = -1
    var currentLine: [String] = []

    func flush() {
      if !currentLine.isEmpty {
        lines.append(currentLine.joined(separator: " "))
        currentLine.removeAll()
      }
    }

    for b in sorted {
      if currentY < 0 { currentY = b.rect.minY }
      if abs(b.rect.minY - currentY) > rowThresh {
        flush()
        currentY = b.rect.minY
      }
      currentLine.append(b.text)
    }
    flush()

    return lines
  }

  // MARK: - Stability (auto mode)

  private func updateStability(lines: [String]) {
    let dedup = Array(Set(lines))
    guard dedup.count >= minLinesToTrigger else {
      textWindow.removeAll()
      return
    }

    textWindow.append(dedup)
    if textWindow.count > windowSize { _ = textWindow.removeFirst() }
    guard textWindow.count == windowSize else { return }

    let a = Set(textWindow.first ?? [])
    let b = Set(textWindow.last ?? [])
    let j = jaccard(a, b)
    guard j >= jaccardThreshold else { return }

    let mergedSet = Set(textWindow.flatMap { $0 })
    if let last = lastSignature, jaccard(last, mergedSet) >= signatureRepeatThreshold {
      return // same receipt as last fire
    }

    let now = CACurrentMediaTime()
    guard now - lastFire > fireCooldown else { return }
    lastFire = now

    setStateIfNeeded(.processing)
    let plain = Array(mergedSet).joined(separator: "\n")

    DispatchQueue.main.async {
      self.stableText = plain
      self.state = .ready
      self.textWindow.removeAll()
      self.lastSignature = mergedSet
    }
  }

  // MARK: - Helpers

  private func setStateIfNeeded(_ s: State) {
    if state != s { state = s }
  }

  private func normalize(_ s: String) -> String {
    var out = s.lowercased()
    out = out.folding(options: .diacriticInsensitive, locale: .current)
    out = out.replacingOccurrences(of: "[^a-z0-9+ .:/-]", with: " ", options: .regularExpression)
    out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
    let inter = a.intersection(b).count
    let uni = a.union(b).count
    guard uni > 0 else { return 0 }
    return Double(inter) / Double(uni)
  }

  private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    if inter.isNull || inter.isEmpty { return 0 }
    let interA = inter.width * inter.height
    let unionA = a.width * a.height + b.width * b.height - interA
    guard unionA > 0 else { return 0 }
    return interA / unionA
  }
}

// MARK: - AVCapture delegate

extension LiveOCR: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput,
                     didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let forced = forceCapture
    forceCapture = false
    handle(pixelBuffer: pb, forced: forced)
  }
}

// MARK: - CIImage helpers

private extension CIImage {
  // Crop to a normalized bbox (no perspective correction here).
  func warped(to bbox: CGRect) -> CIImage? {
    let w = extent.width, h = extent.height
    let rect = CGRect(x: bbox.origin.x * w,
                      y: (1 - bbox.origin.y - bbox.size.height) * h,
                      width: bbox.size.width * w,
                      height: bbox.size.height * h)
    return self.cropped(to: rect)
  }

  func toCGImage() -> CGImage? {
    let ctx = CIContext(options: nil)
    return ctx.createCGImage(self, from: extent)
  }
}
