import AppKit
import AVFoundation
import CoreGraphics
import Foundation

enum Permissions {
    /// Screen Recording TCC. CGPreflightScreenCaptureAccess does not prompt;
    /// CGRequestScreenCaptureAccess prompts once and then requires System
    /// Settings. Window titles in CGWindowList also need this permission.
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        // Triggers the TCC prompt + adds us to the list, then opens the pane.
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
