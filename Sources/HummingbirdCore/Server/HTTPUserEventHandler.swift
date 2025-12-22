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

public import Logging
public import NIOCore
public import NIOHTTPTypes

public final class HTTPUserEventHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPRequestPart
    public typealias InboundOut = HTTPRequestPart
    public typealias OutboundIn = HTTPResponsePart
    public typealias OutboundOut = HTTPResponsePart

    var closeAfterResponseWritten: Bool = false
    var requestsBeingRead: Int = 0
    var requestsInProgress: Int = 0
    let logger: Logger
    let quieceTimeout: TimeAmount?
    private var quiesceTimeoutTask: Scheduled<Void>?

    public init(logger: Logger, quiesceTimeout: TimeAmount? = nil) {
        self.logger = logger
        self.quieceTimeout = quiesceTimeout
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        if case .end = part {
            self.requestsInProgress -= 1
            context.writeAndFlush(data, promise: promise)
            if self.closeAfterResponseWritten {
                context.close(promise: nil)
                self.closeAfterResponseWritten = false
                self.quiesceTimeoutTask?.cancel()
                self.quiesceTimeoutTask = nil
            }
        } else {
            context.write(data, promise: promise)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head:
            self.requestsInProgress += 1
            self.requestsBeingRead += 1
        case .end:
            self.requestsBeingRead -= 1
        default:
            break
        }
        context.fireChannelRead(data)
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            // we received a quiesce event. If we have any requests in progress we should
            // wait for them to finish
            if self.requestsInProgress > 0 {
                self.closeAfterResponseWritten = true
                // Schedule a timeout to close the connection after quiesceTimeout if specified
                if let quieceTimeout {
                    self.quiesceTimeoutTask = context.eventLoop.assumeIsolated().scheduleTask(in: quieceTimeout) {
                        self.logger.warning("Quiesce timeout reached, closing channel")
                        context.close(promise: nil)
                    }
                }
            } else {
                context.close(promise: nil)
            }

        case IdleStateHandler.IdleStateEvent.read:
            // if we get an idle read event and we haven't completed reading the request
            // close the connection, or a request hasnt been initiated
            if self.requestsBeingRead > 0 || self.requestsInProgress == 0 {
                self.logger.trace("Idle read timeout, so close channel")
                context.close(promise: nil)
            }

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    public func handlerRemoved(context: ChannelHandlerContext) {
        if let quiesceTimeoutTask {
            quiesceTimeoutTask.cancel()
            self.quiesceTimeoutTask = nil
            
            // Cancel the timeout task if the handler is removed
            if context.channel.isActive {
                self.logger.info("Did not quiesce before handler removal, closing channel")
                context.close(promise: nil)
            }
        }
    }
}
