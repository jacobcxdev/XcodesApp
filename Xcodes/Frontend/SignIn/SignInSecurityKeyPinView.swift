//
//  SignInSecurityKeyPin.swift
//  Xcodes
//
//  Created by Kino on 2024-09-26.
//  Copyright © 2024 Robots and Pencils. All rights reserved.
//

import SwiftUI
import XcodesLoginKit

struct SignInSecurityKeyPinView: View {
    @EnvironmentObject var appState: AppState
    @State private var pin: String = ""
    let authOptions: AuthOptionsResponse
    let sessionData: AppleSessionData
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(localizeString("SecurityKeyPinDescription"))
                .fixedSize(horizontal: false, vertical: true)
            
            HStack {
                Spacer()
                SecureField("PIN", text: $pin)
                Spacer()
            }
            .padding()
            
            HStack {
                Button("Cancel", action: appState.cancelAuthentication)
                    .keyboardShortcut(.cancelAction)
                Spacer()

                Button("PIN not set", action: submitWithoutPinCode)

                ProgressButton(isInProgress: appState.isProcessingAuthRequest,
                               action: submitPinCode) {
                    Text("Continue")
                }
                .keyboardShortcut(.defaultAction)
                // FIDO2 device pin codes must be at least 4 code points
                // https://docs.yubico.com/yesdk/users-manual/application-fido2/fido2-pin.html
                .disabled(pin.count < 4)
            }
            .frame(height: 25)
        }
        .padding()
        .frame(width: 452)
        .emittingError($appState.authError, recoveryHandler: { _ in })
        .handlingErrors(using: AlertErrorHandler(title: "SignInFailure"))
    }
    
    func submitPinCode() {
        appState.createAndSubmitSecurityKeyAssertationWithPinCode(pin, sessionData: sessionData, authOptions: authOptions)
    }

    func submitWithoutPinCode() {
        appState.createAndSubmitSecurityKeyAssertationWithPinCode(nil, sessionData: sessionData, authOptions: authOptions)
    }
}

#Preview { @MainActor in
    SignInSecurityKeyPinView(authOptions: AuthOptionsResponse(
                                trustedPhoneNumbers: nil,
                                trustedDevices: nil,
                                securityCode: .init(length: 6)
                             ), sessionData: AppleSessionData(serviceKey: "", sessionID: "", scnt: ""))
    .environmentObject(AppState())
}
