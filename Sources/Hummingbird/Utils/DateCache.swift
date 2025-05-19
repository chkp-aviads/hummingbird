//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncAlgorithms
import Atomics
import NIOCore
import NIOPosix
import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Current date formatted cache service
///
/// Getting the current date formatted is an expensive operation. This creates a task that will
/// update a cached version of the date in the format as detailed in RFC9110 once every second.
final class DateCache: Service {
    final class DateContainer: AtomicReference, Sendable {
        let date: String

        init(date: String) {
            self.date = date
        }
    }

    let dateContainer: ManagedAtomic<DateContainer>
    let evenetLoop: EventLoop

    init(eventLoop: EventLoop) {
        self.evenetLoop = eventLoop
        self.dateContainer = .init(.init(date: Date.now.httpHeader))
    }

    public func run() async throws {
        let timerSequence = NIOAsyncTimerSequence(interval: TimeAmount.seconds(1), eventLoop: evenetLoop)
            .cancelOnGracefulShutdown()
        for try await _ in timerSequence {
            self.dateContainer.store(.init(date: Date.now.httpHeader), ordering: .releasing)
        }
    }

    public var date: String {
        self.dateContainer.load(ordering: .acquiring).date
    }
}

/// An `AsyncSequence` that produces elements at regular intervals using SwiftNIO.
public struct NIOAsyncTimerSequence: AsyncSequence {
  public typealias Element = DispatchTime
  
  /// The iterator for a `NIOAsyncTimerSequence` instance.
  public struct Iterator: AsyncIteratorProtocol {
    var eventLoop: EventLoop?
    let interval: TimeAmount
    var last: DispatchTime?
    
    init(interval: TimeAmount, eventLoop: EventLoop) {
      self.eventLoop = eventLoop
      self.interval = interval
    }
    
    public mutating func next() async -> DispatchTime? {
      guard let eventLoop = self.eventLoop else {
        return nil
      }
      
      let now = DispatchTime.now()
      let nextTime: DispatchTime
      
      if let last = self.last {
        // Schedule next tick based on the previous time
        nextTime = DispatchTime(uptimeNanoseconds: last.uptimeNanoseconds + UInt64(interval.nanoseconds))
        
        // Calculate wait duration
        let waitTimeNanos = Int64(nextTime.uptimeNanoseconds) - Int64(now.uptimeNanoseconds)
        if waitTimeNanos > 0 {
          do {
            try await sleep(for: TimeAmount.nanoseconds(waitTimeNanos), on: eventLoop)
          } catch {
            self.eventLoop = nil
            return nil
          }
        }
      } else {
        // First iteration - start immediately
        nextTime = now
      }
      
      let currentTime = DispatchTime.now()
      self.last = nextTime
      return currentTime
    }
    
    private func sleep(for duration: TimeAmount, on eventLoop: EventLoop) async throws {
      try await withCheckedThrowingContinuation { continuation in
        let scheduled = eventLoop.scheduleTask(in: duration) {
          continuation.resume()
        }
        
        // Handle task cancellation
        Task {
          await withTaskCancellationHandler {
            // Nothing needed here - onCancel will handle it
          } onCancel: {
            scheduled.cancel()
            continuation.resume(throwing: CancellationError())
          }
        }
      }
    }
  }
  
  let eventLoop: EventLoop
  let interval: TimeAmount
  
  /// Create a `NIOAsyncTimerSequence` with a given repeating interval.
  public init(interval: TimeAmount, eventLoop: EventLoop) {
    self.eventLoop = eventLoop
    self.interval = interval
  }
  
  public func makeAsyncIterator() -> Iterator {
    Iterator(interval: interval, eventLoop: eventLoop)
  }
}

extension NIOAsyncTimerSequence {
  /// Create a `NIOAsyncTimerSequence` with a given repeating interval.
  public static func repeating(
    every interval: TimeAmount,
    eventLoop: EventLoop
  ) -> NIOAsyncTimerSequence {
    return NIOAsyncTimerSequence(interval: interval, eventLoop: eventLoop)
  }
}

extension NIOAsyncTimerSequence: Sendable {}

@available(*, unavailable)
extension NIOAsyncTimerSequence.Iterator: Sendable {}

