import Testing

@Suite struct EchoHarnessTests {
    @Test func echoServerRespondsWithoutInterceptors() async throws {
        let reply = try await withEchoClient(interceptors: []) { client in
            try await client.get(.with { $0.text = "ping" })
        }
        #expect(reply.text == "ping")
    }
}
