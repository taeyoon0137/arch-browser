// Which capture devices a site's permission request needs the system's permission for. The tests do not read or request the system's own permission.
import ARCHEngine
import AVFoundation
import Testing

@Suite struct EngineCaptureAccessTests {
    @Test func onlyTheCameraAndMicrophoneNeedADevice() {
        #expect(EngineCaptureAccess.mediaTypes(for: [.camera, .geolocation, .microphone]) == [.video, .audio])
        #expect(EngineCaptureAccess.mediaTypes(for: [.screenCapture, .notifications, .clipboard, .midi]).isEmpty)
    }

    @Test func aRequestWithoutDevicesIsGrantedAtOnce() {
        var granted: Bool?
        EngineCaptureAccess.requestAccess(for: []) { granted = $0 }
        #expect(granted == true)
        #expect(!EngineCaptureAccess.isRefusedBySystem([]))
    }
}
