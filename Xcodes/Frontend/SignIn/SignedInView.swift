import SwiftUI

struct SignedInView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(appState.appleAccountDisplayName)
            Button("SignOut", action: appState.signOut)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SignedInView_Previews: PreviewProvider {
    static var previews: some View {
        SignedInView()
            .previewLayout(.sizeThatFits)
    }
}
