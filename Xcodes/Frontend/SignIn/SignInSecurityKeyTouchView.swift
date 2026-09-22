//
//  SignInSecurityKeyPin.swift
//  Xcodes
//
//  Created by Kino on 2024-09-26.
//  Copyright © 2024 Robots and Pencils. All rights reserved.
//

import SwiftUI
import XcodesLoginKit

struct SignInSecurityKeyTouchView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .center) {
            Image(systemName: "key.radiowaves.forward")
                .font(.system(size: 32)).bold()
                .accessibilityHidden(true)
                .padding(.bottom)
            HStack {
                Spacer()
                Text(localizeString("SecurityKeyTouchDescription"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            HStack {
                Button("Cancel", action: self.cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(x: 0.5, y: 0.5, anchor: .center)
                    .isHidden(!appState.isProcessingAuthRequest)
                
            }
            .frame(height: 25)
        }
        .padding()
        .frame(width: 452)
        .emittingError($appState.authError, recoveryHandler: { _ in })
        .handlingErrors(using: AlertErrorHandler(title: "SignInFailure"))
    }
    
    func cancel() {
        appState.cancelSecurityKeyAssertationRequest()
    }
}

#Preview { @MainActor in
    SignInSecurityKeyTouchView()
    .environmentObject(AppState())
}
