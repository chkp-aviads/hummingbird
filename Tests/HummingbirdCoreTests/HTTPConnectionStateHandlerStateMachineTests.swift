//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import HTTPTypes
import NIOCore
import NIOHTTPTypes
import Testing

@testable import HummingbirdCore

struct HTTPConnectionStateHandlerStateMachineTests {
    let start = NIODeadline.uptimeNanoseconds(0)

    /// Should close connection if idle timer triggers and no head read.
    @Test
    func idleTimeoutAfterActive() {
        var stateMachine = self.makeStateMachine()
        let activeAction = stateMachine.setActive(now: self.start)
        #expect(activeAction == .scheduleTimeout(deadline: self.deadline(seconds: 30)))

        let timeoutAction = stateMachine.idleTimeoutTriggered(now: self.deadline(seconds: 30))
        #expect(timeoutAction == .closeConnection)
    }

    /// Should close connection if idle timer triggers and only a head was read.
    @Test
    func idleTimeoutAfterHeadRead() {
        var stateMachine = self.makeStateMachine()
        let activeAction = stateMachine.setActive(now: self.start)
        #expect(activeAction == .scheduleTimeout(deadline: self.deadline(seconds: 30)))

        stateMachine.readHTTPPart(self.requestHead, now: self.deadline(seconds: 2))
        var timeoutAction = stateMachine.idleTimeoutTriggered(now: self.deadline(seconds: 30))
        #expect(timeoutAction == .rescheduleTimeout(deadline: self.deadline(seconds: 32)))

        timeoutAction = stateMachine.idleTimeoutTriggered(now: self.deadline(seconds: 32))
        #expect(timeoutAction == .closeConnection)
    }

    /// Should close connection if idle timer triggers while a request body is being read.
    @Test
    func idleTimeoutWhileReadingBody() {
        var stateMachine = self.makeStateMachine()
        _ = stateMachine.setActive(now: self.start)
        stateMachine.readHTTPPart(self.requestHead, now: self.deadline(seconds: 2))
        stateMachine.readHTTPPart(.body(.init()), now: self.deadline(seconds: 2))

        var timeoutAction = stateMachine.idleTimeoutTriggered(now: self.deadline(seconds: 30))
        #expect(timeoutAction == .rescheduleTimeout(deadline: self.deadline(seconds: 32)))

        timeoutAction = stateMachine.idleTimeoutTriggered(now: self.deadline(seconds: 32))
        #expect(timeoutAction == .closeConnection)
    }

    /// Should do nothing if the request was fully read and its response is being produced.
    @Test
    func noIdleTimeoutWhileProducingResponse() {
        var stateMachine = self.makeStateMachine()
        _ = stateMachine.setActive(now: self.start)
        stateMachine.readHTTPPart(self.requestHead, now: self.start)
        stateMachine.readHTTPPart(.body(.init()), now: self.start)
        stateMachine.readHTTPPart(.end(nil), now: self.start)
        #expect(stateMachine.writeHTTPPart(.head(.init(status: .ok)), now: self.start) == .doNothing)

        let timeoutAction = stateMachine.idleTimeoutTriggered(now: self.deadline(seconds: 30))
        #expect(timeoutAction == .doNothing)
    }

    /// Should schedule a fresh idle timeout after the response is complete.
    @Test
    func idleTimeoutAfterResponseWritten() {
        var stateMachine = self.makeStateMachine()
        _ = stateMachine.setActive(now: self.start)
        stateMachine.readHTTPPart(self.requestHead, now: self.start)
        stateMachine.readHTTPPart(.end(nil), now: self.start)

        let writeAction = stateMachine.writeHTTPPart(.end(nil), now: self.deadline(seconds: 2))
        #expect(writeAction == .scheduleTimeout(deadline: self.deadline(seconds: 32)))
        #expect(stateMachine.idleTimeoutTriggered(now: self.deadline(seconds: 32)) == .closeConnection)
    }

    /// Should close immediately when quiescing an idle connection.
    @Test
    func quiesceWithoutRequestsClosesConnection() {
        var stateMachine = self.makeStateMachine(quiesceTimeout: .seconds(5))

        let action = stateMachine.receivingQuiesceEvent(now: self.start)

        #expect(action == .closeConnection)
    }

    /// Should enforce a hard deadline while waiting for an in-flight request.
    @Test
    func quiesceWithRequestSchedulesTimeout() {
        var stateMachine = self.makeStateMachine(quiesceTimeout: .seconds(5))
        stateMachine.readHTTPPart(self.requestHead, now: self.start)

        let action = stateMachine.receivingQuiesceEvent(now: self.deadline(seconds: 2))

        #expect(action == .scheduleTimeout(deadline: self.deadline(seconds: 7)))
        #expect(stateMachine.receivingQuiesceEvent(now: self.deadline(seconds: 3)) == .doNothing)
    }

    /// Should close only after every pipelined response has been written.
    @Test
    func quiesceWaitsForAllResponses() {
        var stateMachine = self.makeStateMachine(quiesceTimeout: .seconds(5))
        stateMachine.readHTTPPart(self.requestHead, now: self.start)
        stateMachine.readHTTPPart(.end(nil), now: self.start)
        stateMachine.readHTTPPart(self.requestHead, now: self.start)
        stateMachine.readHTTPPart(.end(nil), now: self.start)
        _ = stateMachine.receivingQuiesceEvent(now: self.start)

        #expect(stateMachine.writeHTTPPart(.end(nil), now: self.start) == .doNothing)
        #expect(stateMachine.writeHTTPPart(.end(nil), now: self.start) == .closeConnection)
    }

    /// Without a hard deadline, quiescing should still close after the response completes.
    @Test
    func quiesceWithoutTimeoutWaitsForResponse() {
        var stateMachine = self.makeStateMachine(quiesceTimeout: nil)
        stateMachine.readHTTPPart(self.requestHead, now: self.start)

        #expect(stateMachine.receivingQuiesceEvent(now: self.start) == .doNothing)
        #expect(stateMachine.writeHTTPPart(.end(nil), now: self.start) == .closeConnection)
    }

    private var requestHead: HTTPRequestPart {
        .head(.init(method: .get, scheme: "http", authority: "127.0.0.1", path: "/"))
    }

    private func makeStateMachine(
        idleTimeout: TimeAmount? = .seconds(30),
        quiesceTimeout: TimeAmount? = nil
    ) -> HTTPConnectionStateHandler.StateMachine {
        .init(idleTimeout: idleTimeout, quiesceTimeout: quiesceTimeout, now: self.start)
    }

    private func deadline(seconds: Int64) -> NIODeadline {
        self.start + .seconds(seconds)
    }
}
