import ApplicationServices
import Foundation

protocol PermissionsService {
    var isScreenRecordingAuthorized: Bool { get }
    func requestScreenRecordingAuthorization()
    func openScreenRecordingSettings()
}
