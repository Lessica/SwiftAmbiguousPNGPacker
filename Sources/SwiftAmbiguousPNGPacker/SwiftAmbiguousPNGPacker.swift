import Foundation
import ImageIO
import NIO
import CompressNIO
import DataCompression


private extension CGRect {
    func scaleToAspectFit(in rtarget: CGRect) -> CGFloat {
        // first try to match width
        let s = rtarget.width / self.width;
        // if we scale the height to make the widths equal, does it still fit?
        if self.height * s <= rtarget.height {
            return s
        }
        // no, match height instead
        return rtarget.height / self.height
    }
    func aspectFit(in rtarget: CGRect) -> CGRect {
        let s = scaleToAspectFit(in: rtarget)
        let w = width * s
        let h = height * s
        let x = rtarget.midX - w / 2
        let y = rtarget.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private extension CGImage {
    func rgbData(withContextsize contextSize: CGSize? = nil) -> Data {
        let contextSize = contextSize ?? CGSize(width: width, height: height)
        let dataSize = Int(contextSize.width) * Int(contextSize.height) * 4
        let alphaInfo: CGImageAlphaInfo = .noneSkipLast
        let colorRef = CGColorSpaceCreateDeviceRGB()
        let rawData = UnsafeMutablePointer<UInt8>.allocate(capacity: dataSize)
        guard let context = CGContext(
            data: rawData,
            width: Int(contextSize.width),
            height: Int(contextSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(contextSize.width) * 4,
            space: colorRef,
            bitmapInfo: alphaInfo.rawValue
        ) else {
            fatalError()
        }
        
        context.draw(
            self, in:
                CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height
                ).aspectFit(in: CGRect(origin: .zero, size: contextSize))
        )
        
        let rgbaData = Data(
            bytesNoCopy: rawData,
            count: dataSize,
            deallocator: .free
        )
        
        var byteIdx = 0
        return Data(rgbaData.compactMap {
            if (byteIdx + 1) % 4 == 0 {
                byteIdx += 1
                return nil
            }
            byteIdx += 1
            return $0
        })
    }
}

public struct SwiftAmbiguousPNGPacker {
    
    public static let shared = SwiftAmbiguousPNGPacker()
    
    private static let pngMagic: [UInt8] = [
        0x89, 0x50, 0x4e, 0x47, 0xd, 0xa, 0x1a, 0xa,
    ]
    
    public enum Error: Swift.Error {
        case cgDataProvider(_ url: URL)
        case cgImageSourceCreate(_ url: URL)
        case cgImageSourceCopyProperties(_ url: URL)
        case cgImageCreate(_ url: URL)
        case badFilterByte(_ offset: Int)
        case malformedDatagram
    }
    
    private func applyFilter(_ imageData: Data, width: Int) -> Data {
        var filtered = Data()
        let size = imageData.count
        let stride = width * 3
        for i in Swift.stride(from: 0, to: size, by: stride) {
            filtered += Data([UInt8](arrayLiteral: 0x0)) + Data(imageData[imageData.index(imageData.startIndex, offsetBy: i)..<min(imageData.index(imageData.startIndex, offsetBy: i + stride), imageData.endIndex)])
        }
        return filtered
    }
    
    private func checkFilterBytes(_ data: Data, width: Int) throws {
        let stride = width * 3 + 1
        for i in Swift.stride(from: 0, to: data.count, by: stride) {
            if data[i] != 0x0 {
                dump(data[data.index(data.startIndex, offsetBy: i - 10)..<data.index(data.startIndex, offsetBy: i + 10)])
                throw Error.badFilterByte(i)
            }
        }
    }
    
    private func verbatim(_ data: Data = Data(), last: Bool = false) -> Data {
        var result = last ? Data([UInt8](arrayLiteral: 0x1)) : Data([UInt8](arrayLiteral: 0x0))
        result += withUnsafeBytes(of: UInt16(data.count).littleEndian) { Data($0) }  // reporting overflow?
        result += withUnsafeBytes(of: (UInt16(data.count) ^ UInt16(0xffff)).littleEndian) { Data($0) }
        return result + data
    }
    
    private func decompressHeaderless(_ data: Data) throws -> Data {
        var inputBuffer = ByteBuffer(bytes: data)
        let outputBuffer = try inputBuffer.decompress(with: .ambiguousPNG)
        return Data(outputBuffer.getBytes(at: 0, length: outputBuffer.readableBytes)!)
    }
    
    private func compress(_ data: Data) throws -> Data {
        var inputBuffer = ByteBuffer(bytes: data)
        let outputBuffer = try inputBuffer.compress(with: .ambiguousPNG)
        return Data(outputBuffer.getBytes(at: 0, length: outputBuffer.readableBytes - 2)!)  // without finish flags
    }
    
    private func compressToSize(_ data: Data, size: Int) throws -> Data? {
        var attempt: Data!
        var remainder: Int!
        var found = false
        for i in 1..<data.count {
            let chunk = Data(data[data.startIndex..<data.index(data.endIndex, offsetBy: -i)])
            let compressedChunk = try compress(chunk)
            let ending = data[data.index(data.endIndex, offsetBy: -i)..<data.endIndex]
            attempt = verbatim() + compressedChunk + verbatim(ending)
            remainder = size - attempt!.count
            if remainder % 5 == 0 {
                found = true
                break
            }
        }
        if !found {
            return nil
        }
        if remainder < 0 {
            return nil
        }
        attempt += [Data](repeating: verbatim(), count: remainder / 5).flatMap { $0 }
        assert(attempt.count == size)
        assert(try! decompressHeaderless(attempt) == data)
        return attempt
    }

    private func writeChunk(_ stream: FileHandle, name: String, body: Data) throws {
        let nameData = name.data(using: .utf8)!
        try stream.write(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) })
        try stream.write(contentsOf: nameData)
        try stream.write(contentsOf: body)
        var crc = Crc32()
        crc.advance(withChunk: nameData)
        crc.advance(withChunk: body)
        try stream.write(contentsOf: withUnsafeBytes(of: crc.checksum.bigEndian) { Data($0) })
    }

    private func writeChunk( _ buffer: inout ByteBuffer, name: String, body: Data) throws {
        let nameData = name.data(using: .utf8)!
        buffer.writeBytes(withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) })
        buffer.writeBytes(nameData)
        buffer.writeBytes(body)
        var crc = Crc32()
        crc.advance(withChunk: nameData)
        crc.advance(withChunk: body)
        buffer.writeBytes(withUnsafeBytes(of: crc.checksum.bigEndian) { Data($0) })
    }
    
    public func pack(
        appleImageURL: URL,
        otherImageURL: URL,
        outputURL: URL
    ) throws {
        
        guard let appleImageDataProvider = CGDataProvider(url: appleImageURL as CFURL) else {
            throw Error.cgDataProvider(appleImageURL)
        }
        guard let appleImageSource = CGImageSourceCreateWithDataProvider(appleImageDataProvider, nil) else {
            throw Error.cgImageSourceCreate(appleImageURL)
        }
        guard let appleImageProps = CGImageSourceCopyPropertiesAtIndex(appleImageSource, 0, nil) as? [AnyHashable: Any] else {
            throw Error.cgImageSourceCopyProperties(appleImageURL)
        }
        
        let _appleImageWidth = appleImageProps[kCGImagePropertyPixelWidth] as? Int ?? 0
        let _appleImageHeight = appleImageProps[kCGImagePropertyPixelHeight] as? Int ?? 0
        
        guard let otherImageDataProvider = CGDataProvider(url: otherImageURL as CFURL) else {
            throw Error.cgDataProvider(otherImageURL)
        }
        guard let otherImageSource = CGImageSourceCreateWithDataProvider(otherImageDataProvider, nil) else {
            throw Error.cgImageSourceCreate(otherImageURL)
        }
        guard let otherImageProps = CGImageSourceCopyPropertiesAtIndex(otherImageSource, 0, nil) as? [AnyHashable: Any] else {
            throw Error.cgImageSourceCopyProperties(otherImageURL)
        }
        
        let _otherImageWidth = otherImageProps[kCGImagePropertyPixelWidth] as? Int ?? 0
        let _otherImageHeight = otherImageProps[kCGImagePropertyPixelHeight] as? Int ?? 0

        let width = max(_appleImageWidth, _otherImageWidth)
        var height = max(_appleImageHeight, _otherImageHeight)
        let size = CGSize(width: width, height: height)
        
        guard let appleImage = CGImageSourceCreateImageAtIndex(appleImageSource, 0, nil) else {
            throw Error.cgImageCreate(appleImageURL)
        }
        
        guard let otherImage = CGImageSourceCreateImageAtIndex(otherImageSource, 0, nil) else {
            throw Error.cgImageCreate(otherImageURL)
        }
        
        let appleImageRGBData = appleImage.rgbData(withContextsize: size)
        let otherImageRGBData = otherImage.rgbData(withContextsize: size)
        
        let targetSize = width * 3 + 1
        let msg1 = applyFilter(appleImageRGBData, width: width)
        let msg2 = applyFilter(otherImageRGBData, width: width)
        
        var a = Data()
        a += verbatim(Data([UInt8](repeating: 0x0, count: targetSize)))  // row of empty pixels
        a += verbatim(Data([UInt8](repeating: 0x0, count: targetSize)))[..<5]  // row of empty pixels
        
        var b = Data()
        
        var ypos = 0
        while ypos < height {
            var found = false
            var pieceheight: Int = 1
            guard height - ypos >= 2 else {
                throw Error.malformedDatagram
            }
            for _ in 2..<height - ypos {  // TODO: binary search
                pieceheight += 1
                let start = targetSize * ypos
                let end = targetSize * (ypos + pieceheight)
                let acomp = try compressToSize(Data(msg1[msg1.index(msg1.startIndex, offsetBy: start)..<msg1.index(msg1.startIndex, offsetBy: end)]), size: targetSize - 5)
                guard acomp != nil else {
                    found = true
                    break
                }
                let bcomp = try compressToSize(Data(msg2[msg2.index(msg2.startIndex, offsetBy: start)..<msg2.index(msg2.startIndex, offsetBy: end)]), size: targetSize - 5)
                guard bcomp != nil else {
                    found = true
                    break
                }
            }
            if !found {
                pieceheight += 1
            }
            pieceheight -= 1

            let start = targetSize * ypos
            let end = targetSize * (ypos + pieceheight)
            let acomp = try compressToSize(msg1[start..<end], size: targetSize - 5)
            let bcomp = try compressToSize(msg2[start..<end], size: targetSize - 5)
            
            b += acomp!
            b += verbatim(Data([UInt8](repeating: 0x0, count: targetSize)))[..<5]
            b += bcomp!
            b += verbatim(Data([UInt8](repeating: 0x0, count: targetSize)))[..<5]
            
            ypos += pieceheight + 1
        }
        
        // re-sync the zlib streams
        b = Data(b[b.startIndex..<b.index(b.endIndex, offsetBy: -5)])
        b += verbatim()
        b += verbatim(last: true)
        
        var interp_1 = Data()
        interp_1 += try decompressHeaderless(a)
        interp_1 += try decompressHeaderless(b)
        let interp_2 = try decompressHeaderless(a + b)
        
        try checkFilterBytes(interp_1, width: width)
        try checkFilterBytes(interp_2, width: width)
        
        a = Data([UInt8](arrayLiteral: 0x78, 0xda)) + a
        b += withUnsafeBytes(of: interp_2.adler32().checksum.bigEndian) { Data($0) }

        height = ypos + 1

        try Data().write(to: outputURL)
        let outputStream = try FileHandle(forWritingTo: outputURL)
        try outputStream.write(contentsOf: SwiftAmbiguousPNGPacker.pngMagic)

        var ihdr = Data()
        ihdr += withUnsafeBytes(of: UInt32(width).bigEndian) { Data($0) }  // len = 4
        ihdr += withUnsafeBytes(of: UInt32(height).bigEndian) { Data($0) }  // len = 4
        ihdr += withUnsafeBytes(of: UInt8(8).bigEndian) { Data($0) }  // len = 1, bitdepth
        ihdr += withUnsafeBytes(of: UInt8(2).bigEndian) { Data($0) }  // len = 1, true colour
        ihdr += withUnsafeBytes(of: UInt8(0).bigEndian) { Data($0) }  // len = 1, compression method
        ihdr += withUnsafeBytes(of: UInt8(0).bigEndian) { Data($0) }  // len = 1, filter method
        ihdr += withUnsafeBytes(of: UInt8(0).bigEndian) { Data($0) }  // len = 1, interlace method

        try writeChunk(outputStream, name: "IHDR", body: ihdr)

        var idatChunks = ByteBuffer()
        try writeChunk(&idatChunks, name: "IDAT", body: a)
        let firstOffset = idatChunks.writerIndex
        try writeChunk(&idatChunks, name: "IDAT", body: b)

        let n = 2
        let idotSize = 24 + 8 * n

        var idot = Data()
        idot += withUnsafeBytes(of: Int32(n).bigEndian) { Data($0) }  // len = 4, height divisor
        idot += withUnsafeBytes(of: Int32(0).bigEndian) { Data($0) }  // len = 4, unknown
        idot += withUnsafeBytes(of: Int32(1).bigEndian) { Data($0) }  // len = 4, divided height
        idot += withUnsafeBytes(of: Int32(idotSize).bigEndian) { Data($0) }  // len = 4, unknown
        idot += withUnsafeBytes(of: Int32(1).bigEndian) { Data($0) }  // len = 4, first height
        idot += withUnsafeBytes(of: Int32(height - 1).bigEndian) { Data($0) }  // len = 4, second height
        idot += withUnsafeBytes(of: Int32(idotSize + firstOffset).bigEndian) { Data($0) }  // len = 4, idat restart offset

        try writeChunk(outputStream, name: "iDOT", body: idot)
        idatChunks.moveReaderIndex(to: 0)
        let readableBytes = idatChunks.readableBytes
        try outputStream.write(contentsOf: idatChunks.readBytes(length: readableBytes)!)

        try writeChunk(outputStream, name: "IEND", body: Data())
        try outputStream.close()
    }
}
