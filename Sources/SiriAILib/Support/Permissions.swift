import Foundation
import ApplicationServices

/// Runtime permission checks and the System Settings deep links needed to
/// grant them. Both checks are live (queried at call time) so the wizard can
/// re-poll while the user flips the switch.
public enum Permissions {
    /// Accessibility permission for the *current* process (the terminal or app
    /// that launched siri-ai). Required by the Siri AX backend.
    public static var accessibilityGranted: Bool {
        //AXIsProcessTrustedWithOptions prompts when the prompt option is set;
        // the plain probe never prompts, making it safe for polling loops.
        AXIsProcessTrusted()
    }

    /// Screen Recording permission for the current process. Used by the
    /// diagnostics surface and any future OCR fallback. There is no public
    /// C API probe, so we check indirectly via CGPreflightScreenCaptureAccess.
    public static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Explanation strings for the wizard output.
    public static let accessibilityWhy = "Siri AX backend reads answers from the Siri AI app's UI tree"
    public static let screenRecordingWhy = "Used for diagnostics and any OCR fallback capture"
}
