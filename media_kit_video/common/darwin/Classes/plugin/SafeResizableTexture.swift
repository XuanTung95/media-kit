import CoreGraphics
import CoreVideo
import Foundation

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class avoids data race when called from a thread
public class SafeResizableTexture:
  NSObject,
  FlutterTexture,
  ResizableTextureProtocol
{
  private let lock = NSRecursiveLock()
  private let child: ResizableTextureProtocol
  public var suppressFlutterTextureUpdates = false
  private var freezeFlutterTextureOutputOnNextFrame = false
  private var frozenFlutterPixelBuffer: CVPixelBuffer?

  init(_ child: ResizableTextureProtocol) {
    self.child = child
  }

  public func resize(_ size: CGSize) {
    return locked {
      return child.resize(size)
    }
  }

  public func render(_ size: CGSize) {
    return locked {
      return child.render(size)
    }
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    if suppressFlutterTextureUpdates {
      guard let frozenFlutterPixelBuffer else { return nil }
      return Unmanaged.passRetained(frozenFlutterPixelBuffer)
    }
    return child.copyPixelBuffer()
  }

  public func copyPixelBufferForPictureInPicture() -> Unmanaged<CVPixelBuffer>? {
    return child.copyPixelBuffer()
  }

  public func requestFlutterTextureOutputFreeze() {
    locked {
      guard !suppressFlutterTextureUpdates else { return }
      freezeFlutterTextureOutputOnNextFrame = true
    }
  }

  /// Copies the next frame for Flutter before PiP takes ownership of later frames.
  @discardableResult
  public func freezeFlutterTextureOutputIfRequested() -> Bool {
    return locked {
      guard freezeFlutterTextureOutputOnNextFrame else { return false }
      freezeFlutterTextureOutputOnNextFrame = false
      guard let source = child.copyPixelBuffer()?.takeRetainedValue(),
        let frozenFlutterPixelBuffer = copyPixelBuffer(source)
      else { return false }
      self.frozenFlutterPixelBuffer = frozenFlutterPixelBuffer
      suppressFlutterTextureUpdates = true
      return true
    }
  }

  public func resumeFlutterTextureOutput() {
    locked {
      freezeFlutterTextureOutputOnNextFrame = false
      frozenFlutterPixelBuffer = nil
      suppressFlutterTextureUpdates = false
    }
  }

  private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    var destination: CVPixelBuffer?
    guard CVPixelBufferCreate(
      kCFAllocatorDefault,
      CVPixelBufferGetWidth(source),
      CVPixelBufferGetHeight(source),
      CVPixelBufferGetPixelFormatType(source),
      attributes as CFDictionary,
      &destination
    ) == kCVReturnSuccess, let destination else { return nil }

    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }

    let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
    let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
    let bytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)
    guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(source),
      let destinationBaseAddress = CVPixelBufferGetBaseAddress(destination)
    else { return nil }

    for row in 0..<CVPixelBufferGetHeight(source) {
      memcpy(
        destinationBaseAddress.advanced(by: row * destinationBytesPerRow),
        sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
        bytesPerRow
      )
    }
    return destination
  }

  private func locked<T>(do block: () -> T) -> T {
    lock.lock()
    defer {
      lock.unlock()
    }

    return block()
  }
}
