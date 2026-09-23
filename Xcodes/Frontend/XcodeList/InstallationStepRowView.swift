import SwiftUI
import XcodesKit

struct InstallationStepRowView: View {
    let installationStep: XcodeInstallationStep
    let cancel: () -> Void
    
    var body: some View {
        HStack {
            switch installationStep {
            case let .downloading(progress):
                // FB8955769 ProgressView.init(_: Progress) doesn't ensure that changes from the Progress object are applied to the UI on the main thread
                // This Progress is vended by URLSession so I don't think we can control that.
                // Use our own version of ProgressView that does this instead.
                ObservingProgressIndicator(
                    progress,
                    controlSize: .small,
                    style: .spinning
                )
            case .authenticating, .unarchiving, .moving, .trashingArchive, .checkingSecurity, .finishing:
                ProgressView()
                    .scaleEffect(0.5)
            }
            
            Text(String(format: localizeString("InstallationStepDescription"), installationStep.stepNumber, installationStep.stepCount, installationStep.message))
                .font(.footnote)
            
            Button(action: cancel) {
                Label("Cancel", systemImage: "xmark.circle.fill")
                    .labelStyle(IconOnlyLabelStyle())
                    .frame(minWidth: 20, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundStyle(.primary)
            .help("StopInstallation")
        }
        .frame(minWidth: 80)
    }
}

struct InstallView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ForEach(ColorScheme.allCases, id: \.self) { colorScheme in
                Group {
                    InstallationStepRowView(
                        installationStep: .downloading(
                            progress: configure(Progress(totalUnitCount: 100)) { $0.completedUnitCount = 40 }
                        ),
                        cancel: {}
                    )
                    
                    InstallationStepRowView(
                        installationStep: .unarchiving,
                        cancel: {}
                    )
                    
                    InstallationStepRowView(
                        installationStep: .moving(destination: "/Applications"),
                        cancel: {}
                    )
                    
                    InstallationStepRowView(
                        installationStep: .trashingArchive,
                        cancel: {}
                    )
                    
                    InstallationStepRowView(
                        installationStep: .checkingSecurity,
                        cancel: {}
                    )
                    
                    InstallationStepRowView(
                        installationStep: .finishing,
                        cancel: {}
                    )
                }
                .padding()
                .background(Color(.windowBackgroundColor))
                .environment(\.colorScheme, colorScheme)
            }
            
            ForEach(ColorScheme.allCases, id: \.self) { colorScheme in
                Group {
                    InstallationStepRowView(
                        installationStep: .downloading(
                            progress: configure(Progress(totalUnitCount: 100)) { $0.completedUnitCount = 40 }
                        ),
                        cancel: {}
                    )
                }
                .padding()
                .background(Color(.selectedContentBackgroundColor))
                .environment(\.colorScheme, colorScheme)
            }
        }
    }
}
