import SwiftUI
import XcodesKit

// MARK: - CommandMenu

struct XcodeCommands: Commands {
    // CommandMenus don't participate in the environment hierarchy, so we need to shuffle AppState along to the individual Commands manually.
    let appState: AppState
    
    var body: some Commands {
        CommandMenu("Xcode") {
            Group {
                
                InstallCommand()
                
                Divider()
                
                SelectCommand()
                OpenCommand()
                RevealCommand()
                CopyPathCommand()
                CreateSymbolicLinkCommand()
                
                Divider()
                
                UninstallCommand()
            }
            .environmentObject(appState)
        }
    }
}

// MARK: - Buttons
// These are used for both context menus and commands

struct InstallButton: View {
    @EnvironmentObject var appState: AppState

    let xcode: Xcode?

    var body: some View {
        Button {
            install()
        } label: {
            Text("Install")
                .help("InstallDescription")
        }
    }

    private func install() {
        guard let xcode = xcode else { return }
        appState.checkMinVersionAndInstall(id: xcode.id)
    }
}

struct CancelInstallButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?
    
    var body: some View {
        Button(action: cancelInstall) {
            Label("Cancel", systemImage: "xmark")
        }
        .help(localizeString("StopInstallation"))
        .buttonStyle(.plain)
    }
    
    private func cancelInstall() {
        guard let xcode = xcode else { return }
        appState.presentedAlert = .cancelInstall(xcode: xcode)
    }
}

struct CancelRuntimeInstallButton: View {
    @EnvironmentObject var appState: AppState
    let runtime: DownloadableRuntime?
    
    var body: some View {
        Button(action: cancelInstall) {
            Image(systemName: "xmark.circle.fill")
        }.help(localizeString("StopInstallation"))
            .buttonStyle(.plain)
    }
    
    private func cancelInstall() {
        guard let runtime = runtime else { return }
        appState.presentedAlert = .cancelRuntimeInstall(runtime: runtime)
    }
}

struct SelectButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?
    
    var body: some View {
        Button(action: select) {
            if xcode?.selected == true {
                Text("Active")
            } else {
                Text("MakeActive")
            }
        }
        .disabled(xcode?.selected != false)
        .help("Select")
    }
    
    private func select() {
        guard let xcode = xcode else { return }
        appState.select(xcode: xcode)
    }
}

struct OpenButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?
    
    var showsOpenInRosettaOption: Bool {
        appState.showOpenInRosettaOption && HostHardware.isAppleSilicon()
    }
    
    var body: some View {
        if showsOpenInRosettaOption {
            Menu("Open") {
                Button(action: open) {
                    Text("Open")
                }
                .help("Open")
                Button(action: openInRosetta) {
                    Text("Open In Rosetta")
                }
                .help("Open In Rosetta")
            }
        } else {
            Button(action: open) {
                Text("Open")
            }
            .help("Open")
        }
        
    }
    
    private func open() {
        guard let xcode = xcode else { return }
        appState.open(xcode: xcode)
    }

    private func openInRosetta() {
        guard let xcode = xcode else { return }
        appState.open(xcode: xcode, openInRosetta: true)
    }
}

struct UninstallButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?
    
    var body: some View {
        Button(action: {
            appState.xcodeBeingConfirmedForUninstallation = xcode
        }) {
            Text("Uninstall")
        }
        .foregroundColor(.red)
        .help("Uninstall")
    }
}

struct RevealButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?
    
    var body: some View {
        Button(action: reveal) {
            Text("RevealInFinder")
        }
        .help("RevealInFinder")
    }
    
    private func reveal() {
        guard let xcode = xcode else { return }
        appState.reveal(xcode.installedPath)
    }
}

struct CopyPathButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?
    
    var body: some View {
        Button(action: copyPath) {
            Text("CopyPath")
        }
        .help("CopyPath")
    }
    
    private func copyPath() {
        guard let xcode = xcode else { return }
        appState.copyPath(xcode: xcode)
    }
}

struct CopyReleaseNoteButton: View {
  let url: URL?
    
  @EnvironmentObject var appState: AppState

  var body: some View {
    Button(action: copyReleaseNote) {
      Text("CopyReleaseNoteURL")
    }
    .help("CopyReleaseNoteURL")
  }

  private func copyReleaseNote() {
    guard let url = url else { return }
    appState.copyReleaseNote(from: url)
  }
}


struct CreateSymbolicLinkButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?
    
    var body: some View {
        Button(action: createSymbolicLink) {
            Text("CreateSymLink")
        }
        .help("CreateSymLink")
    }
    
    private func createSymbolicLink() {
        guard let xcode = xcode else { return }
        appState.createSymbolicLink(xcode: xcode)
    }
}

struct DownloadRuntimeButton: View {
    @EnvironmentObject var appState: AppState
    let runtime: DownloadableRuntime?
    
    var body: some View {
        Button(action: install) {
            Text("Install")
                .help("Install")
        }
    }
    
    private func install() {
        guard let runtime = runtime else { return }
        appState.downloadRuntime(runtime: runtime)
    }
}

struct CreateSymbolicBetaLinkButton: View {
    @EnvironmentObject var appState: AppState
    let xcode: Xcode?

    var body: some View {
        Button(action: createSymbolicBetaLink) {
            Text("CreateSymLinkBeta")
        }
        .help("CreateSymLinkBeta")
    }

    private func createSymbolicBetaLink() {
        guard let xcode = xcode else { return }
        appState.createSymbolicLink(xcode: xcode, isBeta: true)
    }
}

enum XcodeCommandShortcuts {
    static let makeActive = KeyboardShortcut("s", modifiers: [.command, .option])
    static let open = KeyboardShortcut(.downArrow, modifiers: .command)
    static let reveal = KeyboardShortcut("r", modifiers: [.command, .option])
    static let copyPath = KeyboardShortcut("c", modifiers: [.command, .option])
    static let uninstall = KeyboardShortcut("u", modifiers: [.command, .option])
    static let createSymbolicLink = KeyboardShortcut("l", modifiers: [.command, .option])

    static let all = [makeActive, open, reveal, copyPath, uninstall, createSymbolicLink]
}

// MARK: - Commands

struct InstallCommand: View {
    @EnvironmentObject var appState: AppState
    @FocusedValue(\.selectedXcode) private var selectedXcode: SelectedXcode?

    var body: some View {
        if selectedXcode.unwrapped?.installState.installing == true {
            CancelInstallButton(xcode: selectedXcode.unwrapped)
                .keyboardShortcut(".", modifiers: [.command])            
        } else {
            InstallButton(xcode: selectedXcode.unwrapped)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(selectedXcode.unwrapped?.installState != .notInstalled)
        }
    }
}

struct SelectCommand: View {
    @EnvironmentObject var appState: AppState
    @FocusedValue(\.selectedXcode) private var selectedXcode: SelectedXcode?

    var body: some View {
        SelectButton(xcode: selectedXcode.unwrapped)
            .keyboardShortcut(XcodeCommandShortcuts.makeActive)
            .disabled(selectedXcode.unwrapped?.installState.installed != true)
    }
}

struct OpenCommand: View {
    @EnvironmentObject var appState: AppState
    @FocusedValue(\.selectedXcode) private var selectedXcode: SelectedXcode?

    var body: some View {
        OpenButton(xcode: selectedXcode.unwrapped)
            .keyboardShortcut(XcodeCommandShortcuts.open)
            .disabled(selectedXcode.unwrapped?.installState.installed != true)
    }
}

struct RevealCommand: View {
    @EnvironmentObject var appState: AppState
    @FocusedValue(\.selectedXcode) private var selectedXcode: SelectedXcode?

    var body: some View {
        RevealButton(xcode: selectedXcode.unwrapped)
            .keyboardShortcut(XcodeCommandShortcuts.reveal)
            .disabled(selectedXcode.unwrapped?.installState.installed != true)
    }
}

struct CopyPathCommand: View {
    @EnvironmentObject var appState: AppState
    @FocusedValue(\.selectedXcode) private var selectedXcode: SelectedXcode?

    var body: some View {
        CopyPathButton(xcode: selectedXcode.unwrapped)
            .keyboardShortcut(XcodeCommandShortcuts.copyPath)
            .disabled(selectedXcode.unwrapped?.installState.installed != true)
    }
}

struct UninstallCommand: View {
    @EnvironmentObject var appState: AppState
    @FocusedValue(\.selectedXcode) private var selectedXcode: SelectedXcode?
    
    var body: some View {
        UninstallButton(xcode: selectedXcode.unwrapped)
            .keyboardShortcut(XcodeCommandShortcuts.uninstall)
            .disabled(selectedXcode.unwrapped?.installState.installed != true)
    }
}

struct CreateSymbolicLinkCommand: View {
    @EnvironmentObject var appState: AppState
    @FocusedValue(\.selectedXcode) private var selectedXcode: SelectedXcode?
    
    var body: some View {
        CreateSymbolicLinkButton(xcode: selectedXcode.unwrapped)
            .keyboardShortcut(XcodeCommandShortcuts.createSymbolicLink)
            .disabled(selectedXcode.unwrapped?.installState.installed != true)
    }
}
