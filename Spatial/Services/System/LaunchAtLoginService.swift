import Foundation

protocol LaunchAtLoginService {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}
