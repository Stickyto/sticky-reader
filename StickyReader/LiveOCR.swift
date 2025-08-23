import AVFoundation
import CoreGraphics
import Foundation
import Vision

@MainActor
class LiveOCR: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  // Capture
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "ocr.capture")
  private let videoOutput = AVCaptureVideoDataOutput()
  private var device: AVCaptureDevice?

  // One-shot OCR output (emitted only when scanNow() is called)
  @Published var lastText: String? = nil

  // Zoom controls expected by ContentView
  @Published var zoomError: String? = nil
  @Published var zoomFactor: CGFloat = 1.25 {  // default ~25% in
    didSet { applyZoom(zoomFactor) }
  }

  private var requestScan = false

  override init() {
    super.init()
    configureSession()
  }

  // MARK: - Session

  private func configureSession() {
    session.beginConfiguration()
    session.sessionPreset = .photo

    // Back wide camera
    let chosenDevice = AVCaptureDevice.default(
      .builtInWideAngleCamera, for: .video, position: .back)
    self.device = chosenDevice

    guard
      let device = chosenDevice,
      let input = try? AVCaptureDeviceInput(device: device)
    else {
      session.commitConfiguration()
      self.zoomError = "Back camera not available."
      return
    }

    if session.canAddInput(input) { session.addInput(input) }

    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

    if let conn = videoOutput.connections.first, conn.isVideoOrientationSupported {
      conn.videoOrientation = .portrait
    }

    // Apply initial zoom (will clamp to device limits)
    applyZoom(zoomFactor)

    session.commitConfiguration()
  }

  func start() async {
    if !session.isRunning {
      session.startRunning()
    }
  }

  func stop() {
    if session.isRunning {
      session.stopRunning()
    }
  }

  // Called by ContentView when the operator taps the screen
  func scanNow() {
    requestScan = true
  }

  // Let ContentView reset UI/state between receipts
  func reset() {
    lastText = ""
    requestScan = false
  }

  // MARK: - Zoom

  private func applyZoom(_ factor: CGFloat) {
    guard let device = self.device else {
      self.zoomError = "Camera not ready."
      return
    }
    do {
      try device.lockForConfiguration()
      let minZ = max(1.0, device.minAvailableVideoZoomFactor)
      let maxZ = device.activeFormat.videoMaxZoomFactor
      let clamped = min(max(factor, minZ), maxZ)
      device.videoZoomFactor = clamped
      device.unlockForConfiguration()

      // Report if we had to clamp, otherwise clear any previous error
      if abs(clamped - factor) > 0.001 {
        self.zoomError = String(
          format: "Requested %.2fx clamped to %.2fx (max %.2fx).", factor, clamped, maxZ)
      } else {
        self.zoomError = nil
      }
    } catch {
      self.zoomError = "Unable to set zoom: \(error.localizedDescription)"
    }
  }

  // MARK: - Delegate (tap-only OCR)

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard requestScan else { return }
    requestScan = false

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let request = VNRecognizeTextRequest { [weak self] req, err in
      guard let self else { return }
      if let results = req.results as? [VNRecognizedTextObservation] {
        let lines = results.compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n")
        DispatchQueue.main.async {
          self.lastText = joined
        }
      } else if let err {
        DispatchQueue.main.async {
          self.lastText = ""  // emit empty to avoid stale text
          self.zoomError = "OCR error: \(err.localizedDescription)"
        }
      }
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
    try? handler.perform([request])
  }
}
