#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class VideoOutputManager: NSObject {
  private let registry: FlutterTextureRegistry
  private var videoOutputs = [Int64: VideoOutput]()

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  public func create(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    textureUpdateCallback: @escaping VideoOutput.TextureUpdateCallback,
    pictureInPicturePlaybackCallback: @escaping VideoOutput.PictureInPicturePlaybackCallback
  ) {
    let videoOutput = VideoOutput(
      handle: handle,
      configuration: configuration,
      registry: self.registry,
      textureUpdateCallback: textureUpdateCallback,
      pictureInPicturePlaybackCallback: pictureInPicturePlaybackCallback
    )

    self.videoOutputs[handle] = videoOutput
  }

  public func setSize(
    handle: Int64,
    width: Int64?,
    height: Int64?
  ) {
    let videoOutput = self.videoOutputs[handle]
    if videoOutput == nil {
      return
    }

    videoOutput!.setSize(
      width: width,
      height: height
    )
  }

  public func destroy(
    handle: Int64,
    completion: @escaping () -> Void
  ) {
    guard let videoOutput = self.videoOutputs[handle] else {
      completion()
      return
    }

    videoOutput.dispose { [weak self, weak videoOutput] in
      if let current = self?.videoOutputs[handle], current === videoOutput {
        self?.videoOutputs[handle] = nil
      }
      completion()
    }
  }

  #if os(iOS)
    public func isPictureInPictureSupported(handle: Int64) -> Bool {
      videoOutputs[handle]?.isPictureInPictureSupported() ?? false
    }

    public func isPictureInPictureActive(handle: Int64) -> Bool {
      videoOutputs[handle]?.isPictureInPictureActive() ?? false
    }

    public func startPictureInPicture(
      handle: Int64,
      playing: Bool,
      sourceRect: CGRect?,
      completion: @escaping (Bool, String?) -> Void
    ) {
      guard let output = videoOutputs[handle] else {
        completion(false, "Video output was not found.")
        return
      }
      output.startPictureInPicture(
        playing: playing,
        sourceRect: sourceRect,
        completion: completion
      )
    }

    public func stopPictureInPicture(
      handle: Int64,
      completion: @escaping () -> Void
    ) {
      guard let output = videoOutputs[handle] else {
        completion()
        return
      }
      output.stopPictureInPicture(completion: completion)
    }

    public func updatePictureInPicturePlaying(handle: Int64, playing: Bool) {
      videoOutputs[handle]?.updatePictureInPicturePlaying(playing)
    }
  #endif
}
