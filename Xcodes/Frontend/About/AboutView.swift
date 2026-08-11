import SwiftUI

struct AboutView: View {
    let showAcknowledgementsWindow: @MainActor () -> Void
    @SwiftUI.Environment(\.openURL) var openURL: OpenURLAction
    
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Bundle.main.bundleName!)
                        .font(.largeTitle)

                    Text(String(format: localizeString("VersionWithBuild"), Bundle.main.shortVersion!, Bundle.main.version!))
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 16) {
                    Button(action: {
                        openURL(URL(string: "https://github.com/jacobcxdev/XcodesApp/")!)
                    }) {
                        Label("GithubRepo", systemImage: "link")
                    }
                    .buttonStyle(LinkButtonStyle())
                    
                    Button(action: showAcknowledgementsWindow) {
                        Label("Acknowledgements", systemImage: "doc")
                    }
                    .buttonStyle(LinkButtonStyle())
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("UnxipExperiment", systemImage: "lightbulb")

                    HStack(spacing: 16) {
                        Button(action: {
                            openURL(URL(string: "https://github.com/saagarjha/unxip/")!)
                        }) {
                            Label("GithubRepo", systemImage: "link")
                        }
                        .buttonStyle(LinkButtonStyle())

                        Button(action: {
                            openURL(URL(string: "https://github.com/saagarjha/unxip/blob/main/LICENSE")!)
                        }) {
                            Label("License", systemImage: "link")
                        }
                        .buttonStyle(LinkButtonStyle())
                    }
                }

                Divider()

                Text(Bundle.main.humanReadableCopyright!)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 320, alignment: .leading)
        }
        .padding(24)
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView(showAcknowledgementsWindow: {})
    }
}
