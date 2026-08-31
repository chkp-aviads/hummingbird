//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import HTTPTypes
public import Logging
public import NIOCore
public import NIOHTTPTypes

/// Tracks HTTP connection activity and closes connections that become idle or finish quiescing.
@available(hummingbird 2.0, *)
public final class HTTPConnectionStateHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPRequestPart
    public typealias InboundOut = HTTPRequestPart
    public typealias OutboundIn = HTTPResponsePart
    public typealias OutboundOut = HTTPResponsePart

    let logger: Logger
    var state: StateMachine
    private var scheduledIdleTask: Scheduled<Void>?
    private var scheduledQuiesceTask: Scheduled<Void>?

    public init(idleTimeout: TimeAmount? = nil, quiesceTimeout: TimeAmount? = nil, logger: Logger) {
        self.logger = logger
        self.state = .init(idleTimeout: idleTimeout, quiesceTimeout: quiesceTimeout)
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.handleSetActiveAction(self.state.setActive(), context: context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.cancelScheduledTasks()
    }

    public func channelActive(context: ChannelHandlerContext) {
        self.handleSetActiveAction(self.state.setActive(), context: context)
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.state.setInactive()
        self.cancelScheduledTasks()
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        self.state.readHTTPPart(part)
        context.fireChannelRead(data)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = self.unwrapOutboundIn(data)
        switch self.state.writeHTTPPart(part) {
        case .scheduleTimeout(let deadline):
            self.scheduleIdleTask(context, deadline: deadline)
            context.write(data, promise: promise)
        case .closeConnection:
            self.cancelQuiesceTask()
            context.writeAndFlush(data, promise: promise)
            context.close(promise: nil)
        case .doNothing:
            context.write(data, promise: promise)
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            switch self.state.receivingQuiesceEvent() {
            case .scheduleTimeout(let deadline):
                self.scheduleQuiesceTask(context, deadline: deadline)
            case .closeConnection:
                context.close(promise: nil)
            case .doNothing:
                break
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func handleSetActiveAction(_ action: StateMachine.SetActiveAction, context: ChannelHandlerContext) {
        switch action {
        case .scheduleTimeout(let deadline):
            self.scheduleIdleTask(context, deadline: deadline)
        case .doNothing:
            break
        }
    }

    private func scheduleIdleTask(_ context: ChannelHandlerContext, deadline: NIODeadline) {
        guard self.scheduledIdleTask == nil else { return }
        self.scheduledIdleTask = context.eventLoop.assumeIsolatedUnsafeUnchecked().scheduleTask(
            in: deadline - .now()
        ) {
            self.scheduledIdleTask = nil
            switch self.state.idleTimeoutTriggered() {
            case .rescheduleTimeout(let deadline):
                self.scheduleIdleTask(context, deadline: deadline)
            case .closeConnection:
                context.close(promise: nil)
            case .doNothing:
                break
            }
        }
    }

    private func scheduleQuiesceTask(_ context: ChannelHandlerContext, deadline: NIODeadline) {
        guard self.scheduledQuiesceTask == nil else { return }
        self.scheduledQuiesceTask = context.eventLoop.assumeIsolatedUnsafeUnchecked().scheduleTask(
            in: deadline - .now()
        ) {
            self.scheduledQuiesceTask = nil
            self.logger.warning("Quiesce timeout reached, closing channel")
            context.close(promise: nil)
        }
    }

    private func cancelQuiesceTask() {
        self.scheduledQuiesceTask?.cancel()
        self.scheduledQuiesceTask = nil
    }

    private func cancelScheduledTasks() {
        self.scheduledIdleTask?.cancel()
        self.scheduledIdleTask = nil
        self.cancelQuiesceTask()
    }
}

@available(hummingbird 2.0, *)
extension HTTPConnectionStateHandler {
    struct StateMachine {
        let idleTimeout: TimeAmount?
        let quiesceTimeout: TimeAmount?

        var requestsInProgress: Int = 0
        var isRequestBeingRead: Bool = false
        var lastActiveTime: NIODeadline
        var isActive: Bool = false
        var closeAfterResponseWritten: Bool = false
        var isQuiescing: Bool = false

        @inlinable
        init(
            idleTimeout: TimeAmount?,
            quiesceTimeout: TimeAmount? = nil,
            now: NIODeadline = .now()
        ) {
            self.idleTimeout = idleTimeout
            self.quiesceTimeout = quiesceTimeout
            self.lastActiveTime = now
        }

        enum SetActiveAction: Equatable {
            case scheduleTimeout(deadline: NIODeadline)
            case doNothing
        }

        @inlinable
        mutating func setActive(now: NIODeadline = .now()) -> SetActiveAction {
            self.isActive = true
            if let idleTimeout {
                return .scheduleTimeout(deadline: now + idleTimeout)
            }
            return .doNothing
        }

        @inlinable
        mutating func setInactive() {
            self.isActive = false
        }

        @inlinable
        mutating func readHTTPPart(_ part: HTTPRequestPart, now: NIODeadline = .now()) {
            self.lastActiveTime = now
            switch part {
            case .head:
                self.isRequestBeingRead = true
                self.requestsInProgress += 1
            case .body:
                break
            case .end:
                self.isRequestBeingRead = false
            }
        }

        enum WritePartAction: Equatable {
            case scheduleTimeout(deadline: NIODeadline)
            case closeConnection
            case doNothing
        }

        @inlinable
        mutating func writeHTTPPart(_ part: HTTPResponsePart, now: NIODeadline = .now()) -> WritePartAction {
            guard case .end = part else { return .doNothing }

            self.requestsInProgress -= 1
            if self.requestsInProgress == 0 {
                if self.closeAfterResponseWritten {
                    return .closeConnection
                }
                if let idleTimeout, self.isActive {
                    self.lastActiveTime = now
                    return .scheduleTimeout(deadline: now + idleTimeout)
                }
            }
            return .doNothing
        }

        enum IdleTimeoutTriggeredAction: Equatable {
            case closeConnection
            case rescheduleTimeout(deadline: NIODeadline)
            case doNothing
        }

        @inlinable
        mutating func idleTimeoutTriggered(now: NIODeadline = .now()) -> IdleTimeoutTriggeredAction {
            guard let idleTimeout, self.isActive else { return .doNothing }

            // Do not time out while a fully-read request is still being processed.
            if self.isRequestBeingRead == false, self.requestsInProgress > 0 {
                return .doNothing
            }

            let deadline = self.lastActiveTime + idleTimeout
            if now >= deadline {
                return .closeConnection
            }
            return .rescheduleTimeout(deadline: deadline)
        }

        enum ReceivedQuiesceAction: Equatable {
            case scheduleTimeout(deadline: NIODeadline)
            case closeConnection
            case doNothing
        }

        @inlinable
        mutating func receivingQuiesceEvent(now: NIODeadline = .now()) -> ReceivedQuiesceAction {
            guard self.requestsInProgress > 0 else { return .closeConnection }

            self.closeAfterResponseWritten = true
            guard self.isQuiescing == false else { return .doNothing }
            self.isQuiescing = true
            if let quiesceTimeout {
                return .scheduleTimeout(deadline: now + quiesceTimeout)
            }
            return .doNothing
        }
    }
}

@available(*, unavailable)
extension HTTPConnectionStateHandler: Sendable {}
