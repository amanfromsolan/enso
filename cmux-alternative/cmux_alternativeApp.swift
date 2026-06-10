//
//  cmux_alternativeApp.swift
//  cmux-alternative
//
//  Created by aman on 09/06/26.
//

import SwiftUI

@main
struct cmux_alternativeApp: App {
    @StateObject private var sessionStore = TerminalSessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: sessionStore)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            TerminalCommands(store: sessionStore)
        }
    }
}
