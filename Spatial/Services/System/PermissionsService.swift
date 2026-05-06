import ApplicationServices
import Foundation

protocol PermissionsService {
    var isScreenRecordingAuthorized: Bool { get }
    @discardableResult
    func requestScreenRecordingAuthorization() -> Bool
    func openScreenRecordingSettings()
}
