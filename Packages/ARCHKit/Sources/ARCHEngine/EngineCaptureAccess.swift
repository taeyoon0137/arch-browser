// The system's camera and microphone permission for the app, which both engine adapters check around a site's media capture request.
import AVFoundation
import Foundation

/// The macOS camera and microphone access checks that both adapters run before they grant a site's capture request.
public enum EngineCaptureAccess {
    /// The capture devices that `types` name: video for the camera, audio for the microphone. The other permissions need no device.
    public static func mediaTypes(for types: [EnginePermissionType]) -> [AVMediaType] {
        types.compactMap { type in
            switch type {
            case .camera: .video
            case .microphone: .audio
            default: nil
            }
        }
    }

    /// Whether the system already denies the app one of the devices, so a site's request for it is denied without asking the user.
    public static func isRefusedBySystem(_ mediaTypes: [AVMediaType]) -> Bool {
        mediaTypes.contains { mediaType in
            let status = AVCaptureDevice.authorizationStatus(for: mediaType)
            return status == .denied || status == .restricted
        }
    }

    /// Requests the system's permission for each device in turn, which asks the user only once per device. Completes on the main thread with `false` as soon as one is denied.
    public static func requestAccess(for mediaTypes: [AVMediaType], completion: @escaping (Bool) -> Void) {
        guard let mediaType = mediaTypes.first else { return completion(true) }
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            DispatchQueue.main.async {
                if granted {
                    requestAccess(for: Array(mediaTypes.dropFirst()), completion: completion)
                } else {
                    completion(false)
                }
            }
        }
    }
}
