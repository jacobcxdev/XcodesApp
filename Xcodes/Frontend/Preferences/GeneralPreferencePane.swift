import SwiftUI
import XcodesLoginKit

enum AppleAccountPreferencePresentation: Equatable {
    case checking
    case signedIn
    case signedOut

    init(isRestoring: Bool, authenticationState: AuthenticationState) {
        if isRestoring {
            self = .checking
        } else {
            switch authenticationState {
            case .authenticated:
                self = .signedIn
            case .waitingForFederatedAuthentication, .waitingForSecondFactor:
                self = .checking
            case .unauthenticated, .notAppleDeveloper:
                self = .signedOut
            }
        }
    }
}

struct GeneralPreferencePane: View {
    @EnvironmentObject var appState: AppState
    @SwiftUI.Environment(\.openWindow) private var openWindow
   
    var body: some View {
        VStack(alignment: .leading) {
            GroupBox(label: Text("AppleAccount")) {
                switch AppleAccountPreferencePresentation(
                    isRestoring: appState.isRestoringAuthenticationState,
                    authenticationState: appState.authenticationState
                ) {
                case .checking:
                    ProgressView("CheckingAppleAccount")
                        .controlSize(.small)
                case .signedIn:
                    SignedInView()
                case .signedOut:
                    Button("SignIn") {
                        openWindow(id: "main")
                        appState.presentedSheet = .signIn
                    }
                }
            }
            .groupBoxStyle(PreferencesGroupBoxStyle())
            Divider()
            
            GroupBox(label: Text("Notifications")) {
                NotificationsView()
            }
            .groupBoxStyle(PreferencesGroupBoxStyle())
            Divider()
            
            GroupBox(label: Text("AppBehaviour")) {
                Toggle("TerminateAfterLastWindowClosed", isOn: $appState.terminateAfterLastWindowClosed)
                Toggle("GroupXcodeVersionsInList", isOn: $appState.enableGroupedXcodeList)
                    .disabled(PreferenceKey.enableGroupedXcodeList.isManaged())
            }
            .groupBoxStyle(PreferencesGroupBoxStyle())
        }
    }
}

struct GeneralPreferencePane_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        Group {
            GeneralPreferencePane()
                .environmentObject(AppState())
                .frame(maxWidth: 600)
        }
    }
}
