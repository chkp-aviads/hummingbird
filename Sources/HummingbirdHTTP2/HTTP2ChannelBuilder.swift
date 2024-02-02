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

import HummingbirdCore
import NIOCore
import NIOSSL

extension HBHTTPChannelBuilder {
    ///  Build HTTP channel with HTTP2 upgrade
    ///
    /// Use in ``Hummingbird/HBApplication`` initialization.
    /// ```
    /// let app = HBApplication(
    ///     router: router,
    ///     server: .http2Upgrade(tlsConfiguration: tlsConfiguration)
    /// )
    /// ```
    /// - Parameters:
    ///   - tlsConfiguration: TLS configuration
    ///   - additionalChannelHandlers: Additional channel handlers to call before handling HTTP
    /// - Returns: HTTPChannelHandler builder
    public static func http2Upgrade(
        tlsConfiguration: TLSConfiguration,
        idleTimeout: Duration = .seconds(30),
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = []
    ) throws -> HBHTTPChannelBuilder<HTTP2UpgradeChannel> {
        return .init { responder in
            return try HTTP2UpgradeChannel(
                tlsConfiguration: tlsConfiguration,
                idleTimeout: idleTimeout,
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder
            )
        }
    }
}