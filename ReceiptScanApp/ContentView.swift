import SwiftUI
import AVFoundation

struct ContentView: View {
  @StateObject private var ocr = LiveOCR()
  @State private var green = false
  @State private var lastText: String = ""
  @State private var reason: String? = "Align receipt in frame"

  var body: some View {
    ZStack {
      // Live camera preview
      CameraView(session: ocr.session)
        .ignoresSafeArea()

      // Overlay HUD
      VStack {
        // Status pill (GREEN/RED + short reason)
        HStack(spacing: 8) {
          Circle()
            .fill(green ? .green : .red)
            .frame(width: 16, height: 16)
          Text(green ? "READY" : "HOLD")
            .font(.headline)
            .foregroundColor(.white)
          if let reason, !green {
            Text("· \(reason)")
              .font(.subheadline)
              .foregroundColor(.white.opacity(0.9))
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 12)

        Spacer()

        // Extracted text + actions
        VStack(alignment: .leading, spacing: 10) {
          Text("Extracted")
            .font(.caption)
            .foregroundColor(.white.opacity(0.85))

          ScrollView {
            Text(lastText.isEmpty ? "—" : lastText)
              .font(.footnote)
              .foregroundColor(.white)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 2)
          }
          .frame(maxHeight: 180)

          HStack {
            Button("Reset") {
              ocr.reset()
              lastText = ""
              green = false
              reason = "Align receipt in frame"
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button("Scan Now") {
              // Force a one-shot OCR of the next frame (no debouncing)
              ocr.scanNow()
              reason = "Scanning…"
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Spacer()

            Button("Simulate API call") {
              // Wire your API call here using `lastText`
            }
            .buttonStyle(.borderedProminent)
          }
        }
        .padding(14)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 16)
      }
    }
    // Receive stable OCR text (auto or forced)
    .onReceive(ocr.$stableText) { text in
      guard let text = text else { return }
      lastText = text

      // GREEN stub logic: go green if extracted text contains "COFFEE"
      let hasCoffee = text.localizedCaseInsensitiveContains("coffee")
      green = hasCoffee
      reason = hasCoffee ? nil : "No ‘COFFEE’ detected yet"
    }
    // Receive state updates from the OCR engine (auto mode feedback)
    .onReceive(ocr.$state) { state in
      switch state {
      case .findingROI:
        green = false; reason = "Align receipt in frame"
      case .unstable:
        green = false; reason = "Hold steady…"
      case .processing:
        green = false; reason = "Processing…"
      case .ready:
        break
      }
    }
    // Start capture/OCR
    .task {
      await ocr.start()
    }
  }
}
