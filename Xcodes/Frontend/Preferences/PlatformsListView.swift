//
//  PlatformsListView.swift
//  Xcodes
//
//  Created by Matt Kiazyk on 2023-12-20.
//

import Foundation
import SwiftUI
import Path
import XcodesKit
import OrderedCollections

struct PlatformsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedRuntime: InstalledPlatformRuntime?

    private var runtimes: OrderedDictionary<DownloadableRuntime.Platform, [InstalledPlatformRuntime]> {
        OrderedDictionary(grouping: appState.installedPlatformRuntimes(), by: { $0.runtime.platform })
    }
    
    var body: some View {
        List(selection: $selectedRuntime) {
            Text("PlatformsList.Title")
                .font(.body)
            if appState.isRefreshingInstalledRuntimes {
                ProgressView("RefreshDescription")
                    .controlSize(.small)
            } else if let error = appState.installedRuntimesError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("RuntimeLoadError", systemImage: "exclamationmark.triangle")
                    Text(error.legibleLocalizedDescription)
                        .font(.callout)
                        .textSelection(.enabled)
                    Button("Refresh") { appState.updateInstalledRuntimes() }
                }
            } else if runtimes.isEmpty {
                ContentUnavailableView {
                    Label("NoRuntimesToShow", systemImage: "iphone")
                } actions: {
                    Button("Refresh") {
                        appState.updateDownloadableRuntimes()
                        appState.updateInstalledRuntimes()
                    }
                }
            }
            ForEach(runtimes.elements.sorted(\.key.order), id: \.key) { platform, runtimeList in
                Section {
                    ForEach(runtimeList) { installedRuntime in
                        let runtime = installedRuntime.runtime
                        HStack {
                            Text(runtime.name)
                            Spacer()
                            Text(runtime.downloadFileSizeString)
                            Button {
                                deleteRuntime(runtime: installedRuntime)
                            } label: {
                                Label("Alert.DeletePlatform.PrimaryButton", systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityValue(runtime.name)
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                            .disabled(appState.isRefreshingInstalledRuntimes)
                        }
                        .frame(height: 30)
                    }
                   
                } header: {
                    HStack {
                        runtimeList.first!.runtime.icon()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(platform.shortName)
                            .font(.headline)
                    }
                } footer: {
                    EmptyView()
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
    
    func deleteRuntime(runtime: InstalledPlatformRuntime) {
        appState.presentedPlatformAlert = .deletePlatform(runtime: runtime)
    }
}


#Preview { @MainActor in
    PlatformsListView()
        .environmentObject({ () -> AppState in
            let a = AppState()
          
            a.installedRuntimes = installedRuntimes
            a.downloadableRuntimes = downloadableRuntimes
        
            return a
          
        }())
}
