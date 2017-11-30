import Async
import Bits
import Dispatch
import Foundation

/// Converts responses to Data.
public final class ResponseSerializer: Serializer {
    /// See InputStream.Input
    public typealias Input = Response

    /// See OutputStream.Output
    public typealias Output = ByteBuffer
    
    /// When an upgrade request is in progress, this is set
    public private(set) var upgradeHandler: OnUpgrade?

    /// Use a basic stream to easily implement our output stream.
    private var outputStream: BasicStream<Output>

    /// Create a new ResponseSerializer
    public init() {
        outputStream = .init()
    }

    /// See InputStream.onInput
    public func onInput(_ input: Response) {
        serialize(input).withByteBuffer(outputStream.onInput)
    }

    /// See InputStream.onError
    public func onError(_ error: Error) {
        outputStream.onError(error)
    }

    /// See OutputStream.onOutput
    public func onOutput<I>(_ input: I) where I: Async.InputStream, Output == I.Input {
        outputStream.onOutput(input)
    }

    /// See CloseableStream.close
    public func close() {
        outputStream.close()
    }

    /// See CloseableStream.onClose
    public func onClose(_ onClose: ClosableStream) {
        outputStream.onClose(onClose)
    }

    /// Efficiently serializes a response into Data.
    public func serialize(_ response: Response) -> Data {
        if let count = response.body.count {
            response.headers[.contentLength] = count.description
        } else if case .stream(_) = response.body.storage {
            response.headers[.transferEncoding] = "chunked"
        }
        
        self.upgradeHandler = response.onUpgrade

        let statusCode = Data(response.status.code.description.utf8)

        // prefix + status + space + message + eol
        let firstLineCount = http1Prefix.count + statusCode.count + 1 + response.status.messageData.count + eol.count

        // first line + headers + contentLengthHeader + EOL + body + EOL
        let messageSize = firstLineCount + response.headers.storage.count + eol.count + response.body.storage.count

        var data = Data(repeating: 0, count: messageSize)

        data.withUnsafeMutableBytes { (message: MutableBytesPointer) in
            var offset = 0

            // First line
            offset += copy(http1Prefix, to: message)
            offset += copy(statusCode, to: message.advanced(by: offset))
            message.advanced(by: offset).pointee = .space
            offset += 1
            offset += copy(response.status.messageData, to: message.advanced(by: offset))
            offset += copy(eol, to: message.advanced(by: offset))

            // headers
            offset += copy(response.headers.storage, to: message.advanced(by: offset))

            // End of headers
            offset += copy(eol, to: message.advanced(by: offset))

            switch response.body.storage {
            case .data(let data):
                offset += copy(data, to: message.advanced(by: offset))
            case .dispatchData(let data):
                offset += copy(Data(data), to: message.advanced(by: offset))
            case .staticString(let pointer):
                memcpy(message.advanced(by: offset), pointer.utf8Start, pointer.utf8CodeUnitCount)
                offset += pointer.utf8CodeUnitCount
            case .stream(let bodyStream):
                bodyStream.stream(to: ChunkEncoder()).drain(onInput: outputStream.onInput).catch(onError: self.onError)
            }
        }

        return data
    }
}

fileprivate func copy(_ data: Data, to pointer: MutableBytesPointer) -> Int {
    data.withUnsafeBytes { (dataPointer: BytesPointer) in
        _ = memcpy(pointer, dataPointer, data.count)
    }
    
    return data.count
}

internal let http1Prefix = Data("HTTP/1.1 ".utf8)
internal let eol = Data("\r\n".utf8)
internal let headerKeyValueSeparator: Data = Data(": ".utf8)

// MARK: Utilities

