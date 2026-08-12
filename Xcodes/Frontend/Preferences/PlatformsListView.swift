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
    @State private var runtimes: OrderedDictionary<DownloadableRuntime.Platform, [InstalledPlatformRuntime]> = [:]
    @State private var selectedRuntime: InstalledPlatformRuntime?
    
    var body: some View {
        List(selection: $selectedRuntime) {
            Text("PlatformsList.Title")
                .font(.body)
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
                                Image(systemName: "trash")
                            }
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                        }
                        .frame(height: 30)
                    }
                   
                } header: {
                    HStack {
                        runtimeList.first!.runtime.icon()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20)
                        Text(platform.shortName)
                            .font(.headline)
                    }
                } footer: {
                    EmptyView()
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .task {
            loadRuntimes()
        }
        .onChange(of: appState.installedRuntimes) { _ in
            loadRuntimes()
        }
    }
    
    func loadRuntimes() {
        let filteredRuntimes = appState.installedPlatformRuntimes()
        runtimes = OrderedDictionary(grouping: filteredRuntimes, by: { $0.runtime.platform })
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
