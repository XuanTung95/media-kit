import CoreGraphics
import Foundation

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void
  public typealias PictureInPicturePlaybackCallback = (Bool) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let pictureInPicturePlaybackCallback: PictureInPicturePlaybackCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false

  #if os(iOS)
    private static let sharedPictureInPicture = MediaKitPictureInPictureController()
    private let pictureInPicture = VideoOutput.sharedPictureInPicture
    private let pictureInPictureHandle: Int64
  #endif

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback,
    pictureInPicturePlaybackCallback: @escaping PictureInPicturePlaybackCallback
  ) {
    let playerHandle = OpaquePointer(bitPattern: Int(handle))
    assert(playerHandle != nil, "handle casting")

    self.handle = playerHandle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback
    self.pictureInPicturePlaybackCallback = pictureInPicturePlaybackCallback

    #if os(iOS)
      pictureInPictureHandle = handle
    #endif

    super.init()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    worker.cancel()
    if !disposed {
      #if os(iOS)
        pictureInPicture.detach(outputHandle: pictureInPictureHandle)
      #endif
      texture?.dispose()
      disposeTextureId()
    }
  }

  /// Stops rendering and releases the mpv render context before completion.
  /// The owning mpv core must remain alive until this callback is invoked.
  public func dispose(completion: @escaping () -> Void) {
    guard !disposed else {
      completion()
      return
    }
    disposed = true

    #if os(iOS)
      pictureInPicture.detach(outputHandle: pictureInPictureHandle)
    #endif

    // Serialize behind any render already queued on the worker. New update
    // callbacks are ignored once `disposed` is true.
    worker.enqueue { [self] in
      texture?.dispose()
      disposeTextureId { [self] in
        worker.cancel()
        completion()
      }
    }
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    if enableHardwareAcceleration {
      texture = SafeResizableTexture(
        TextureHW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self] () in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    } else {
      texture = SafeResizableTexture(
        TextureSW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self] () in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    }

    DispatchQueue.main.sync { [weak self] () in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId(completion: (() -> Void)? = nil) {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      if textureId_ >= 0 {
        registry_.unregisterTexture(textureId_)
      }
      completion?()
    }
  }

  public func updateCallback() {
    if disposed {
      return
    }
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    if disposed {
      return
    }
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    if currentSize != size {
      currentSize = size

      texture.resize(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // textureUpdateCallback must run on the main thread
        that.textureUpdateCallback(that.textureId, size)
      }
    }

    if disposed {
      return
    }

    texture.render(size)

    var shouldNotifyFlutter = true
    #if os(iOS)
      // Keep the latest frame ready and feed PiP without another copy.
      let safeTexture = texture as? SafeResizableTexture
      if let frame = safeTexture?.copyPixelBufferForPictureInPicture()?
        .takeRetainedValue()
      {
        pictureInPicture.enqueue(
          outputHandle: pictureInPictureHandle,
          pixelBuffer: frame
        )
      }
      let didFreezeFlutterTexture =
        safeTexture?.freezeFlutterTextureOutputIfRequested() == true
      shouldNotifyFlutter = safeTexture?.suppressFlutterTextureUpdates != true

      if didFreezeFlutterTexture {
        // Publish the next copied frame; later frames stay exclusive to PiP.
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.registry.textureFrameAvailable(self.textureId)
        }
      }
    #endif

    if shouldNotifyFlutter {
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // Textures must be marked as available from the main thread
        that.registry.textureFrameAvailable(that.textureId)
      }
    }
  }

  #if os(iOS)
    public func isPictureInPictureSupported() -> Bool {
      pictureInPicture.isSupported
    }

    public func isPictureInPictureActive() -> Bool {
      pictureInPicture.isActive
    }

    public func startPictureInPicture(
      playing: Bool,
      sourceRect: CGRect?,
      completion: @escaping (Bool, String?) -> Void
    ) {
      pictureInPicture.start(
        outputHandle: pictureInPictureHandle,
        playerHandle: handle,
        playing: playing,
        sourceRect: sourceRect,
        activeChanged: { [weak self] active in
          guard let self else { return }
          if active {
            (self.texture as? SafeResizableTexture)?.requestFlutterTextureOutputFreeze()
          } else {
            (self.texture as? SafeResizableTexture)?.resumeFlutterTextureOutput()
            DispatchQueue.main.async {
              self.registry.textureFrameAvailable(self.textureId)
            }
          }
        },
        playbackChanged: pictureInPicturePlaybackCallback,
        completion: completion
      )
    }

    public func stopPictureInPicture(completion: @escaping () -> Void) {
      pictureInPicture.stop(completion: completion)
    }

    public func updatePictureInPicturePlaying(_ playing: Bool) {
      pictureInPicture.updatePlaying(
        outputHandle: pictureInPictureHandle,
        playing: playing
      )
    }
  #endif

  private var videoSize: CGSize {
    // fixed size
    if width != nil && height != nil {
      return CGSize(
        width: Double(width!),
        height: Double(height!)
      )
    }

    let params = MPVHelpers.getVideoOutParams(handle)
    return CGSize(
      width: Double(
        width
          ?? (params.rotate == 0 || params.rotate == 180
            ? params.dw
            : params.dh)),
      height: Double(
        height
          ?? (params.rotate == 0 || params.rotate == 180
            ? params.dh
            : params.dw))
    )
  }
}
