import SwiftUI

enum NotificationPreferencePresentation: Equatable {
    case checking
    case canEnable
    case disabled
    case enabled

    init(_ status: NotificationPermissionPromptStatus) {
        switch status {
        case .unknown:
            self = .checking
        case .notShown:
            self = .canEnable
        case .shownAndDenied:
            self = .disabled
        case .shownAndAccepted:
            self = .enabled
        }
    }
}

struct NotificationsView: View {
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @ObservedObject var notificationManager: NotificationManager

    init(notificationManager: NotificationManager = Current.notificationManager) {
        self.notificationManager = notificationManager
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            switch NotificationPreferencePresentation(notificationManager.notificationStatus) {
            case .checking:
                ProgressView("CheckingNotificationSettings")
                    .controlSize(.small)
            case .canEnable:
                Button("EnableNotifications") {
                    notificationManager.requestAccess()
                }
            case .disabled:
                Label("AccessDenied", systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("NotificationSettings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
                    NSWorkspace.shared.open(url)
                }
            case .enabled:
                Label("AccessGranted", systemImage: "checkmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            notificationManager.loadNotificationStatus()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if case .active = newScenePhase {
                notificationManager.loadNotificationStatus()
            }
        }
    }
}

struct NotificationsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NotificationsView()
        }
    }
}
