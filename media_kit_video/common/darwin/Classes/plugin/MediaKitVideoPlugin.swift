#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class MediaKitVideoPlugin: NSObject, FlutterPlugin {
  private static let CHANNEL_NAME = "com.alexmercerind/media_kit_video"

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if canImport(Flutter)
      let binaryMessenger = registrar.messenger()
      let registry = registrar.textures()
      let utils: UtilsProtocol? = nil
    #elseif canImport(FlutterMacOS)
      let binaryMessenger = registrar.messenger
      let registry = registrar.textures
      let utils: UtilsProtocol? = Utils(registrar)
    #endif

    let channel = FlutterMethodChannel(
      name: CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    let instance = MediaKitVideoPlugin(
      registry: registry,
      channel: channel,
      utils: utils
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let channel: FlutterMethodChannel
  private let videoOutputManager: VideoOutputManager
  private let utils: UtilsProtocol?

  init(
    registry: FlutterTextureRegistry,
    channel: FlutterMethodChannel,
    utils: UtilsProtocol?
  ) {
    self.channel = channel
    videoOutputManager = VideoOutputManager(
      registry: registry
    )
    self.utils = utils
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "VideoOutputManager.Create":
      handleCreateMethodCall(call.arguments, result)
    case "VideoOutputManager.SetSize":
      handleSetSizeMethodCall(call.arguments, result)
    case "VideoOutputManager.Dispose":
      handleDisposeMethodCall(call.arguments, result)
    #if os(iOS)
      case "VideoOutputManager.PictureInPicture.IsSupported":
        handlePictureInPictureIsSupported(call.arguments, result)
      case "VideoOutputManager.PictureInPicture.IsActive":
        handlePictureInPictureIsActive(call.arguments, result)
      case "VideoOutputManager.PictureInPicture.Start":
        handlePictureInPictureStart(call.arguments, result)
      case "VideoOutputManager.PictureInPicture.Stop":
        handlePictureInPictureStop(call.arguments, result)
      case "VideoOutputManager.PictureInPicture.UpdatePlaying":
        handlePictureInPictureUpdatePlaying(call.arguments, result)
    #endif
    case "Utils.EnterNativeFullscreen":
      handleEnterNativeFullscreenMethodCall(call.arguments, result)
    case "Utils.ExitNativeFullscreen":
      handleExitNativeFullscreenMethodCall(call.arguments, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  #if os(iOS)
    private func pictureInPictureHandle(_ arguments: Any?) -> Int64? {
      let args = arguments as? [String: Any]
      return Int64(args?["handle"] as? String ?? "")
    }

    private func pictureInPicturePlaying(_ arguments: Any?) -> Bool {
      let args = arguments as? [String: Any]
      return args?["playing"] as? Bool ?? false
    }

    private func pictureInPictureSourceRect(_ arguments: Any?) -> CGRect? {
      let args = arguments as? [String: Any]
      let rect = args?["sourceRect"] as? [String: Any]
      guard let left = rect?["left"] as? NSNumber,
        let top = rect?["top"] as? NSNumber,
        let width = rect?["width"] as? NSNumber,
        let height = rect?["height"] as? NSNumber
      else { return nil }
      return CGRect(
        x: left.doubleValue,
        y: top.doubleValue,
        width: width.doubleValue,
        height: height.doubleValue
      )
    }

    private func handlePictureInPictureIsSupported(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      guard let handle = pictureInPictureHandle(arguments) else {
        result(FlutterError(code: "invalid_handle", message: nil, details: nil))
        return
      }
      result(videoOutputManager.isPictureInPictureSupported(handle: handle))
    }

    private func handlePictureInPictureIsActive(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      guard let handle = pictureInPictureHandle(arguments) else {
        result(FlutterError(code: "invalid_handle", message: nil, details: nil))
        return
      }
      result(videoOutputManager.isPictureInPictureActive(handle: handle))
    }

    private func handlePictureInPictureStart(
      _ arguments: Any?,
      _ result: @escaping FlutterResult
    ) {
      guard let handle = pictureInPictureHandle(arguments) else {
        result(FlutterError(code: "invalid_handle", message: nil, details: nil))
        return
      }
      let playing = pictureInPicturePlaying(arguments)
      videoOutputManager.startPictureInPicture(
        handle: handle,
        playing: playing,
        sourceRect: pictureInPictureSourceRect(arguments)
      ) { started, error in
        if let error {
          result(FlutterError(code: "pip_unavailable", message: error, details: nil))
        } else {
          result(started)
        }
      }
    }

    private func handlePictureInPictureStop(
      _ arguments: Any?,
      _ result: @escaping FlutterResult
    ) {
      guard let handle = pictureInPictureHandle(arguments) else {
        result(FlutterError(code: "invalid_handle", message: nil, details: nil))
        return
      }
      videoOutputManager.stopPictureInPicture(handle: handle) {
        result(nil)
      }
    }

    private func handlePictureInPictureUpdatePlaying(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      guard let handle = pictureInPictureHandle(arguments) else {
        result(FlutterError(code: "invalid_handle", message: nil, details: nil))
        return
      }
      videoOutputManager.updatePictureInPicturePlaying(
        handle: handle,
        playing: pictureInPicturePlaying(arguments)
      )
      result(nil)
    }
  #endif

  private func handleCreateMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)
    let configDict = args?["configuration"] as! [String: Any]
    let configuration = VideoOutputConfiguration.fromDict(configDict)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.create(
      handle: handle!,
      configuration: configuration,
      textureUpdateCallback: { (_ textureId: Int64, _ size: CGSize) in
        self.channel.invokeMethod(
          "VideoOutput.Resize",
          arguments: [
            "handle": handle!,
            "id": textureId,
            "rect": [
              "top": 0,
              "left": 0,
              "width": size.width,
              "height": size.height,
            ],
          ] as [String: Any]
        )
      },
      pictureInPicturePlaybackCallback: { playing in
        self.channel.invokeMethod(
          "VideoOutput.PictureInPicture.SetPlaying",
          arguments: [
            "handle": handle!,
            "playing": playing,
          ] as [String: Any]
        )
      }
    )

    result(nil)
  }

  private func handleSetSizeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let widthStr = args?["width"] as! String
    let heightStr = args?["height"] as! String

    let handle: Int64? = Int64(handleStr)
    let width: Int64? = Int64(widthStr)
    let height: Int64? = Int64(heightStr)

    assert(handle != nil, "handle must be an Int64")

    self.videoOutputManager.setSize(
      handle: handle!,
      width: width,
      height: height
    )

    result(nil)
  }

  private func handleDisposeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.destroy(
      handle: handle!
    )

    result(nil)
  }

  private func handleEnterNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.enterNativeFullscreen()
    result(nil)
  }

  private func handleExitNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.exitNativeFullscreen()
    result(nil)
  }
}
