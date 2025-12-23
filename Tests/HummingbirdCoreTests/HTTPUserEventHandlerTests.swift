//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import HummingbirdCore
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTPTypes
import Testing

@Suite("HTTPUserEventHandlerTests")
struct HTTPUserEventHandlerTests {
    private final class DiscardInboundHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPRequestPart

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            // Intentionally discard
        }
    }

    @Test func testQuiesceTimeoutClosesChannelAfterQuiesceEvent() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        // Ensure the embedded channel is active so we can assert on `isActive`.
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
        try channel.connect(to: address).wait()

        let handler = HTTPUserEventHandler(
            logger: Logger(label: #function),
            quiesceTimeout: .milliseconds(10)
        )

        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(DiscardInboundHandler())

        // Create an in-flight request so `requestsInProgress > 0`.
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/", headerFields: .init())
        channel.pipeline.fireChannelRead(HTTPRequestPart.head(request))

        // Trigger quiescing; handler should schedule timeout instead of closing immediately.
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        #expect(channel.isActive)

        // Advance time to just before the timeout; channel should still be active.
        let embeddedEventLoop = channel.eventLoop as! EmbeddedEventLoop
        embeddedEventLoop.advanceTime(by: .milliseconds(5))
        embeddedEventLoop.run()
        #expect(channel.isActive)

        // Advance past the timeout so the scheduled close fires.
        embeddedEventLoop.advanceTime(by: .milliseconds(10))
        embeddedEventLoop.run()
        embeddedEventLoop.run()

        // Ensure the close has been fully processed.
        try channel.closeFuture.wait()
        #expect(channel.isActive == false)
    }

    @Test func testQuiesceTimeoutCancelledWhenResponseEnds() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        // Ensure the embedded channel is active so we can assert on `isActive`.
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12346)
        try channel.connect(to: address).wait()

        let handler = HTTPUserEventHandler(
            logger: Logger(label: #function),
            quiesceTimeout: .milliseconds(50)
        )

        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(DiscardInboundHandler())

        // Create an in-flight request so `requestsInProgress > 0`.
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/", headerFields: .init())
        channel.pipeline.fireChannelRead(HTTPRequestPart.head(request))

        // Trigger quiescing; handler should schedule a timeout.
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        #expect(channel.isActive)

        let embeddedEventLoop = channel.eventLoop as! EmbeddedEventLoop
        embeddedEventLoop.advanceTime(by: .milliseconds(10))
        embeddedEventLoop.run()
        #expect(channel.isActive)

        // Finish the response; handler should close immediately and cancel any pending timeout.
        let response = HTTPResponse(status: .ok, headerFields: .init())
        try channel.writeOutbound(HTTPResponsePart.head(response))
        try channel.writeOutbound(HTTPResponsePart.end(nil))
        embeddedEventLoop.run()

        try channel.closeFuture.wait()
        #expect(channel.isActive == false)

        // Advancing time beyond the original timeout should not "re-close" or otherwise change state.
        embeddedEventLoop.advanceTime(by: .milliseconds(100))
        embeddedEventLoop.run()
        #expect(channel.isActive == false)
    }
}
