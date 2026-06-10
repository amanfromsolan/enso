//
//  ContentView.swift
//  cmux-alternative
//
//  Created by aman on 09/06/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var store: TerminalSessionStore

    var body: some View {
        TerminalRootView(store: store)
    }
}

#Preview {
    ContentView(store: TerminalSessionStore.preview)
}
