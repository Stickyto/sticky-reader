import AVFoundation
import SwiftUI

struct ContentView: View {
  @StateObject private var ocr = LiveOCR()

  // OCR text we most recently sent (shown in failure modal)
  @State private var lastText: String = ""

  // API call & result modal
  @State private var isCallingAPI = false
  @State private var showResult = false
  @State private var resultSuccess = false
  @State private var resultDetail = ""

  // Credentials persisted in UserDefaults
  @AppStorage("bearerToken") private var storedBearerToken: String = ""  // Private key (Bearer)
  @AppStorage("applicationId") private var storedApplicationId: String = ""  // Flow ID
  @AppStorage("federatedUserPrivateKey") private var storedFederatedUserPrivateKey: String = ""  // Team member private key (optional)

  @State private var showLogin: Bool = false
  @State private var inputToken: String = ""
  @State private var inputApplicationId: String = ""
  @State private var inputFederatedUserPrivateKey: String = ""  // optional input
  @State private var loginError: String? = nil

  // Persisted Zoom
  @AppStorage("zoomFactor") private var storedZoom: Double = 1.25  // default ~25% in

  // Fixed API URL
  private let apiURL = URL(
    string: "https://sticky.to/v2/connectionhook/---/CONNECTION_EXTERNAL_PAYMENT/private--payment")!

  // Logged in = only private key + flow id required
  private var isLoggedIn: Bool {
    !storedBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !storedApplicationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    // Base content
    let base = ZStack {
      Color.black.ignoresSafeArea()

      // Live camera; tap anywhere to Scan Now
      CameraView(session: ocr.session)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { ocr.scanNow() }

      // Bottom controls: Zoom slider + Log out (only when logged in & not on login modal)
      VStack {
        Spacer()
        if isLoggedIn && !showLogin {
          VStack(alignment: .leading, spacing: 8) {
            Text("Zoom: \(String(format: "%.2fx", ocr.zoomFactor))")
              .font(.footnote)
              .foregroundColor(.white)
              .padding(.horizontal)

            Slider(
              value: Binding(
                get: { Double(ocr.zoomFactor) },
                set: { newVal in
                  let val = CGFloat(newVal)
                  ocr.zoomFactor = val
                  storedZoom = Double(val)
                }
              ),
              in: 1.0...5.0,
              step: 0.05
            )
            .padding(.horizontal)

            HStack {
              Button("Log out") {
                storedBearerToken = ""
                storedApplicationId = ""
                storedFederatedUserPrivateKey = ""
                inputToken = ""
                inputApplicationId = ""
                inputFederatedUserPrivateKey = ""
                loginError = nil
                showLogin = true
                lastText = ""
                ocr.reset()
              }
              .buttonStyle(.bordered)
              .tint(.white)

              Spacer()
            }
            .padding(.horizontal)
          }
          .padding(.bottom, 16)
        } else {
          Color.clear.frame(height: 16)
        }
      }
    }
    // TAP-ONLY OCR: listen to one-shot results
    .onReceive(ocr.$lastText) { text in
      guard let text, !text.isEmpty else { return }
      guard isLoggedIn, !showLogin, !showResult, !isCallingAPI else { return }

      lastText = text.uppercased()  // source of truth for API + error display
      isCallingAPI = true
      Task { await sendToAPI(cartText: lastText) }
    }
    // Optional: surface zoom failures if LiveOCR publishes them
    .onReceive(ocr.$zoomError) { msg in
      guard let msg, !msg.isEmpty else { return }
      isCallingAPI = false
      resultSuccess = false
      resultDetail = "Camera zoom failed: \(msg)"
      showResult = true
      ocr.zoomError = nil
    }
    .task {
      // Show login if missing required creds
      showLogin = !isLoggedIn
      // Apply persisted zoom to OCR engine on launch
      let z = max(1.0, storedZoom)
      if ocr.zoomFactor != CGFloat(z) {
        ocr.zoomFactor = CGFloat(z)
      }
      await ocr.start()
    }

    // Compose overlays in correct stacking order
    base
      .overlay(loadingOverlay.zIndex(4))  // Loading modal (white spinner card)
      .overlay(resultOverlay.zIndex(5))  // Result modal (success/fail)
      .overlay(loginOverlay.zIndex(6))  // Login modal – topmost when shown
  }

  // MARK: - Loading Overlay
  @ViewBuilder
  private var loadingOverlay: some View {
    if isCallingAPI && !showResult {
      ZStack {
        Color.black.opacity(0.6).ignoresSafeArea()
        VStack {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .black))
            .scaleEffect(2.0)
        }
        .padding(40)
        .frame(maxWidth: 160, maxHeight: 160)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(radius: 16)
      }
      .allowsHitTesting(true)
    }
  }

  // MARK: - Result Overlay
  @ViewBuilder
  private var resultOverlay: some View {
    if showResult {
      ZStack {
        Color.black.opacity(0.6).ignoresSafeArea()

        VStack(spacing: 20) {
          Image(systemName: resultSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(.system(size: 72, weight: .bold))
            .foregroundColor(resultSuccess ? .green : .red)

          if resultSuccess {
            Text("Success!")
              .font(.system(size: 26, weight: .bold))
              .foregroundColor(.black)
              .multilineTextAlignment(.center)

            if !resultDetail.isEmpty {
              Text(resultDetail)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.black.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
          } else {
            if !resultDetail.isEmpty {
              Text(resultDetail)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
            if !lastText.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("Scanned text")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundColor(.black.opacity(0.8))
                ScrollView {
                  Text(lastText)
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(12)
                .background(Color.black.opacity(0.06))
                .cornerRadius(10)
              }
              .padding(.horizontal)
            }
          }

          Button(action: {
            showResult = false
            lastText = ""
            ocr.reset()
          }) {
            Text("Dismiss")
              .font(.system(size: 20, weight: .bold))
              .foregroundColor(.white)
              .frame(maxWidth: .infinity)
              .padding()
              .background(Color.black)
              .cornerRadius(12)
          }
          .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: 360)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(radius: 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 24)
      }
      .allowsHitTesting(true)
    }
  }

  // MARK: - Login Overlay
  @ViewBuilder
  private var loginOverlay: some View {
    if showLogin {
      ZStack {
        Color.black.opacity(0.6).ignoresSafeArea()
        VStack(alignment: .leading, spacing: 16) {
          Text("Private key")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.black)

          TextField("Enter private key", text: $inputToken)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .font(.system(size: 18))
            .padding(12)
            .background(Color.black.opacity(0.06))
            .cornerRadius(10)

          Text("Flow ID")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.black)

          TextField("Enter Flow ID", text: $inputApplicationId)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .font(.system(size: 18))
            .padding(12)
            .background(Color.black.opacity(0.06))
            .cornerRadius(10)

          Text("Team member private key (optional)")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.black)

          TextField("Enter team member private key (optional)", text: $inputFederatedUserPrivateKey)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .font(.system(size: 18))
            .padding(12)
            .background(Color.black.opacity(0.06))
            .cornerRadius(10)

          if let loginError {
            Text(loginError)
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(.red)
          }

          Button(action: {
            let token = inputToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let appId = inputApplicationId.trimmingCharacters(in: .whitespacesAndNewlines)
            let fedKey = inputFederatedUserPrivateKey.trimmingCharacters(
              in: .whitespacesAndNewlines)  // optional

            if token.isEmpty || appId.isEmpty {
              loginError = "Please enter both Private key and Flow ID."
            } else {
              storedBearerToken = token
              storedApplicationId = appId
              // Save optional only if provided (empty is fine to save/overwrite)
              storedFederatedUserPrivateKey = fedKey
              inputToken = ""
              inputApplicationId = ""
              inputFederatedUserPrivateKey = ""
              loginError = nil
              showLogin = false
            }
          }) {
            Text("Log in")
              .font(.system(size: 20, weight: .bold))
              .foregroundColor(.white)
              .frame(maxWidth: .infinity)
              .padding()
              .background(Color.black)
              .cornerRadius(12)
          }
          .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(radius: 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 24)
      }
      .allowsHitTesting(true)
    }
  }

  // MARK: - API

  private func sendToAPI(cartText: String) async {
    // Exact local names as requested:
    let _storedBearerToken = storedBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let _storedApplicationId = storedApplicationId.trimmingCharacters(in: .whitespacesAndNewlines)
    let _storedFederatedUserPrivateKey = storedFederatedUserPrivateKey.trimmingCharacters(
      in: .whitespacesAndNewlines)  // may be empty

    guard !_storedBearerToken.isEmpty, !_storedApplicationId.isEmpty else {
      await MainActor.run {
        showLogin = true
        isCallingAPI = false
      }
      return
    }

    var req = URLRequest(
      url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    req.httpMethod = "POST"

    // Authorization header rule:
    // - Only bearer → "Bearer TOKEN"
    // - Bearer + federated → "Bearer TOKEN//FEDKEY"
    if _storedFederatedUserPrivateKey.isEmpty {
      req.setValue("Bearer \(_storedBearerToken)", forHTTPHeaderField: "Authorization")
    } else {
      req.setValue(
        "Bearer \(_storedBearerToken)//\(_storedFederatedUserPrivateKey)",
        forHTTPHeaderField: "Authorization")
    }

    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Body: { "cart": "<OCR TEXT>", "applicationId": "<Flow ID>" }
    let payload: [String: String] = [
      "cart": cartText,
      "applicationId": _storedApplicationId,
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

      if code == 200 {
        var plain: String? = nil
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          plain = obj["asPlainText"] as? String
        }
        await MainActor.run {
          presentResult(success: true, detail: plain ?? "Success!")
        }
      } else {
        let body = String(data: data, encoding: .utf8) ?? ""
        await MainActor.run {
          presentResult(success: false, detail: String(body.prefix(400)))
        }
      }
    } catch {
      await MainActor.run {
        presentResult(success: false, detail: error.localizedDescription)
      }
    }
  }

  @MainActor
  private func presentResult(success: Bool, detail: String) {
    resultSuccess = success
    resultDetail = detail
    showResult = true
    isCallingAPI = false
  }
}
