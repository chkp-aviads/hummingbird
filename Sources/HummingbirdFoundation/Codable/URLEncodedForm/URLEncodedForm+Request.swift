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

import Hummingbird
import HummingbirdCore

extension URLEncodedFormEncoder: HBResponseEncoder {
    /// Extend URLEncodedFormEncoder to support encoding `HBResponse`'s. Sets body and header values
    /// - Parameters:
    ///   - value: Value to encode
    ///   - request: Request used to generate response
    public func encode(_ value: some Encodable, from request: HBRequest, context: some HBBaseRequestContext) throws -> HBResponse {
        var buffer = context.allocator.buffer(capacity: 0)
        let string = try self.encode(value)
        buffer.writeString(string)
        return HBResponse(
            status: .ok,
            headers: [.contentType: "application/x-www-form-urlencoded"],
            body: .init(byteBuffer: buffer)
        )
    }
}

extension URLEncodedFormDecoder: HBRequestDecoder {
    /// Extend URLEncodedFormDecoder to decode from `HBRequest`.
    /// - Parameters:
    ///   - type: Type to decode
    ///   - request: Request to decode from
    public func decode<T: Decodable>(_ type: T.Type, from request: HBRequest, context: some HBBaseRequestContext) async throws -> T {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        let string = String(buffer: buffer)
        return try self.decode(T.self, from: string)
    }
}
