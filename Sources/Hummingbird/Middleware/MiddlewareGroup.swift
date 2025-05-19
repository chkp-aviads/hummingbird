//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Type-erased middleware wrapper for iOS 15 compatibility
public struct AnyMiddleware<Input, Output, Context>: Sendable {
    private let _handle: @Sendable (Input, Context, @escaping @Sendable (Input, Context) async throws -> Output) async throws -> Output
    
    public init<M: MiddlewareProtocol>(_ middleware: M) where M.Input == Input, M.Output == Output, M.Context == Context {
        self._handle = middleware.handle
    }
    
    public func handle(_ input: Input, context: Context, next: @Sendable @escaping (Input, Context) async throws -> Output) async throws -> Output {
        try await _handle(input, context, next)
    }
}

/// Group of middleware that can be used to create a responder chain. Each middleware calls the next one
public final class MiddlewareGroup<Context> {
    var middlewares: [AnyMiddleware<Request, Response, Context>]

    /// Initialize `MiddlewareGroup`
    init(middlewares: [AnyMiddleware<Request, Response, Context>] = []) {
        self.middlewares = middlewares
    }

    /// Add middleware to group
    ///
    /// This middleware will only be applied to endpoints added after this call.
    @discardableResult public func add<M: MiddlewareProtocol>(_ middleware: M) -> Self where M.Input == Request, M.Output == Response, M.Context == Context {
        self.middlewares.append(AnyMiddleware(middleware))
        return self
    }

    /// Construct responder chain from this middleware group
    /// - Parameter finalResponder: The responder the last middleware calls
    /// - Returns: Responder chain
    public func constructResponder(finalResponder: any HTTPResponder<Context>) -> any HTTPResponder<Context> {
        var currentResponser = finalResponder
        for i in (0..<self.middlewares.count).reversed() {
            let responder = MiddlewareResponder(middleware: middlewares[i], next: currentResponser.respond(to:context:))
            currentResponser = responder
        }
        return currentResponser
    }
}
