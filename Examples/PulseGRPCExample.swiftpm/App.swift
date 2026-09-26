import Pulse
import PulseProxy
import PulseUI
import SwiftUI

@main
struct PulseGRPCExampleApp: App {
    init() {
        LoggerStore.shared.removeAll() // Start every launch with an empty console.
        NetworkLogger.enableProxy() // Logs URLSession traffic, for the REST call.
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var results: [String] = []
    @State private var isConsolePresented = false

    var body: some View {
        NavigationStack {
            List {
                Section("gRPC, in-process Echo server") {
                    ForEach(Demo.grpcCalls, id: \.title) { call in
                        Button(call.title) { run(call.action) }
                    }
                }
                Section("REST, URLSession") {
                    Button(Demo.rest.title) { run(Demo.rest.action) }
                }
                Section {
                    Button("Show Console") { isConsolePresented = true }
                }
                Section("Results") {
                    ForEach(Array(results.enumerated().reversed()), id: \.offset) { _, result in
                        Text(result).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("PulseGRPC")
        }
        .sheet(isPresented: $isConsolePresented) {
            NavigationStack { ConsoleView() }
        }
    }

    private func run(_ action: @escaping @Sendable () async -> String) {
        Task { results.append(await action()) }
    }
}
