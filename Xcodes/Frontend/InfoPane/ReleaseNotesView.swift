//
//  ReleaseNotesView.swift
//  Xcodes
//
//  Created by Duong Thai on 13/10/2023.
//  Copyright © 2023 Robots and Pencils. All rights reserved.
//

import SwiftUI

struct ReleaseNotesView: View {
    let url: URL?

    @SwiftUI.Environment(\.openURL) var openURL: OpenURLAction

    var body: some View {
        if let url {
            Button(action: { openURL(url) }) {
                Label("ReleaseNotes.help", systemImage: "doc.text")
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.link)
            .contextMenu(menuItems: {
                CopyReleaseNoteButton(url: url)
            })
            .help("ReleaseNotes.help")
        } else {
            EmptyView()
        }
    }
}

#Preview {
  let url = URL(string: "https://developer.apple.com/documentation/xcode-release-notes/xcode-12_3-release-notes/")!

  return ReleaseNotesView(url: url)
    .padding()
}
