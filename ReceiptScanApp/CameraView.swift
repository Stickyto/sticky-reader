import SwiftUI
import AVFoundation

struct CameraView: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewView {
    let v = PreviewView()
    v.videoPreviewLayer.session = session
    v.videoPreviewLayer.videoGravity = .resizeAspectFill
    return v
  }

  func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
