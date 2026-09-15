import AVFoundation
import AVKit
import UIKit

#if SWIFT_PACKAGE
  import Mpv
#endif

/// Availability-safe wrapper because media_kit_video still supports pre-iOS 15.
final class MediaKitPictureInPictureController {
  private final class PendingStart {
    let outputHandle: Int64
    let playerHandle: OpaquePointer
    let playing: Bool
    let sourceRect: CGRect?
    let activeChanged: (Bool) -> Void
    let playbackChanged: (Bool) -> Void
    let completion: (Bool, String?) -> Void

    init(
      outputHandle: Int64,
      playerHandle: OpaquePointer,
      playing: Bool,
      sourceRect: CGRect?,
      activeChanged: @escaping (Bool) -> Void,
      playbackChanged: @escaping (Bool) -> Void,
      completion: @escaping (Bool, String?) -> Void
    ) {
      self.outputHandle = outputHandle
      self.playerHandle = playerHandle
      self.playing = playing
      self.sourceRect = sourceRect
      self.activeChanged = activeChanged
      self.playbackChanged = playbackChanged
      self.completion = completion
    }
  }

  private let frameLock = NSLock()
  private var implementation: AnyObject?
  private var latestFrames: [Int64: CVPixelBuffer] = [:]
  private var selectedHandle: Int64?
  private var pendingStart: PendingStart?
  private var preparingImplementation = false

  deinit {
    frameLock.lock()
    let implementation = implementation
    frameLock.unlock()
    if #available(iOS 15.0, *) {
      (implementation as? MediaKitPictureInPictureImplementation)?.dispose()
    }
  }

  var isSupported: Bool {
    guard #available(iOS 15.0, *) else { return false }
    return AVPictureInPictureController.isPictureInPictureSupported()
  }

  var isActive: Bool {
    frameLock.lock()
    let implementation = implementation
    frameLock.unlock()
    guard #available(iOS 15.0, *),
      let implementation = implementation as? MediaKitPictureInPictureImplementation
    else { return false }
    return implementation.isActive
  }

  func start(
    outputHandle: Int64,
    playerHandle: OpaquePointer,
    playing: Bool,
    sourceRect: CGRect?,
    activeChanged: @escaping (Bool) -> Void,
    playbackChanged: @escaping (Bool) -> Void,
    completion: @escaping (Bool, String?) -> Void
  ) {
    guard isSupported else {
      completion(false, "System Picture in Picture requires iOS 15 or newer.")
      return
    }

    if #available(iOS 15.0, *) {
      let request = PendingStart(
        outputHandle: outputHandle,
        playerHandle: playerHandle,
        playing: playing,
        sourceRect: sourceRect,
        activeChanged: activeChanged,
        playbackChanged: playbackChanged,
        completion: completion
      )
      frameLock.lock()
      let initialFrame = latestFrames[outputHandle]
      let existingImplementation = implementation
      if initialFrame == nil || existingImplementation == nil {
        let previousRequest = pendingStart
        pendingStart = request
        frameLock.unlock()
        previousRequest?.completion(false, "Picture in Picture start was superseded.")
        return
      }
      selectedHandle = outputHandle
      frameLock.unlock()
      performStart(
        request,
        initialFrame: initialFrame!,
        implementation: existingImplementation
          as! MediaKitPictureInPictureImplementation
      )
    }
  }

  @available(iOS 15.0, *)
  private func performStart(
    _ request: PendingStart,
    initialFrame: CVPixelBuffer,
    implementation: MediaKitPictureInPictureImplementation
  ) {
    implementation.start(
      playerHandle: request.playerHandle,
      initialFrame: initialFrame,
      playing: request.playing,
      sourceRect: request.sourceRect,
      activeChanged: request.activeChanged,
      playbackChanged: request.playbackChanged,
      completion: request.completion
    )
  }

  func stop(completion: @escaping () -> Void) {
    frameLock.lock()
    let implementation = implementation
    frameLock.unlock()
    guard #available(iOS 15.0, *),
      let implementation = implementation as? MediaKitPictureInPictureImplementation
    else {
      completion()
      return
    }
    implementation.stop(completion: completion)
  }

  func updatePlaying(outputHandle: Int64, playing: Bool) {
    frameLock.lock()
    let isSelected = selectedHandle == outputHandle
    frameLock.unlock()
    guard isSelected else { return }

    frameLock.lock()
    let implementation = implementation
    frameLock.unlock()
    guard #available(iOS 15.0, *),
      let implementation = implementation as? MediaKitPictureInPictureImplementation
    else { return }
    implementation.updatePlaying(playing)
  }

  func enqueue(outputHandle: Int64, pixelBuffer: CVPixelBuffer) {
    frameLock.lock()
    latestFrames[outputHandle] = pixelBuffer
    let implementation = implementation
    let isSelected = selectedHandle == outputHandle
    let startRequest =
      pendingStart?.outputHandle == outputHandle
      ? pendingStart
      : nil
    if startRequest != nil, implementation != nil {
      pendingStart = nil
      selectedHandle = outputHandle
    }
    let shouldPrepare = implementation == nil && !preparingImplementation
    if shouldPrepare {
      preparingImplementation = true
    }
    frameLock.unlock()

    guard #available(iOS 15.0, *), isSupported else { return }
    if let implementation = implementation as? MediaKitPictureInPictureImplementation {
      if isSelected {
        implementation.enqueue(pixelBuffer)
      }
      if let startRequest {
        performStart(
          startRequest,
          initialFrame: pixelBuffer,
          implementation: implementation
        )
      }
      return
    }
    guard shouldPrepare else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.frameLock.lock()
      let existingImplementation = self.implementation
      self.frameLock.unlock()

      let implementation =
        existingImplementation as? MediaKitPictureInPictureImplementation
        ?? MediaKitPictureInPictureImplementation()
      self.frameLock.lock()
      self.implementation = implementation
      self.preparingImplementation = false
      let startRequest = self.pendingStart
      let startFrame = startRequest.flatMap {
        self.latestFrames[$0.outputHandle]
      }
      if startRequest != nil, startFrame != nil {
        self.pendingStart = nil
        self.selectedHandle = startRequest?.outputHandle
      }
      self.frameLock.unlock()
      implementation.prewarm(pixelBuffer)
      if let startRequest, let startFrame {
        self.performStart(
          startRequest,
          initialFrame: startFrame,
          implementation: implementation
        )
      }
    }
  }

  func detach(outputHandle: Int64) {
    frameLock.lock()
    latestFrames[outputHandle] = nil
    let implementation = implementation
    let isSelected = selectedHandle == outputHandle
    let cancelledStart =
      pendingStart?.outputHandle == outputHandle
      ? pendingStart
      : nil
    if cancelledStart != nil {
      pendingStart = nil
    }
    if isSelected {
      selectedHandle = nil
    }
    frameLock.unlock()

    cancelledStart?.completion(false, "Video output was disposed before its first frame.")

    guard isSelected, #available(iOS 15.0, *),
      let implementation = implementation as? MediaKitPictureInPictureImplementation
    else { return }
    implementation.showPlaceholder()
  }
}

@available(iOS 15.0, *)
private final class MediaKitPictureInPictureImplementation: NSObject {
  private let displayLayer = AVSampleBufferDisplayLayer()
  private let frameLock = NSLock()

  private var sourceView: UIView?
  private var controller: AVPictureInPictureController?
  private var prepared = false
  private var pictureInPictureActive = false
  private var playerHandle: OpaquePointer?
  private var activeChanged: ((Bool) -> Void)?
  private var playbackChanged: ((Bool) -> Void)?
  private var startCompletion: ((Bool, String?) -> Void)?
  private var stopCompletions: [() -> Void] = []

  deinit {
    let controller = controller
    let displayLayer = displayLayer
    let sourceView = sourceView
    DispatchQueue.main.async {
      controller?.stopPictureInPicture()
      displayLayer.flushAndRemoveImage()
      sourceView?.removeFromSuperview()
    }
  }

  var isActive: Bool {
    frameLock.lock()
    defer { frameLock.unlock() }
    return pictureInPictureActive
  }

  func prewarm(_ initialFrame: CVPixelBuffer) {
    let action = {
      self.prepareIfNeeded()
      _ = self.enqueueSample(initialFrame)
    }
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  func start(
    playerHandle: OpaquePointer,
    initialFrame: CVPixelBuffer,
    playing: Bool,
    sourceRect: CGRect?,
    activeChanged: @escaping (Bool) -> Void,
    playbackChanged: @escaping (Bool) -> Void,
    completion: @escaping (Bool, String?) -> Void
  ) {
    let action = {
      guard self.startCompletion == nil else {
        completion(false, "Picture in Picture is already starting.")
        return
      }
      self.attach(
        playerHandle: playerHandle,
        activeChanged: activeChanged,
        playbackChanged: playbackChanged
      )
      self.prepareIfNeeded()
      self.updateSourceRect(sourceRect)
      guard let controller = self.controller else {
        completion(false, "Picture in Picture is not ready.")
        return
      }
      // AVKit caches this value when the PiP controls are first displayed.
      // Seed it from PlayerState and invalidate before starting PiP.
      self.setBoolProperty("pause", !playing)
      controller.invalidatePlaybackState()
      if controller.isPictureInPictureActive {
        self.setPictureInPictureActive(true)
        self.displayLayer.flush()
        _ = self.enqueueSample(initialFrame)
        self.activeChanged?(true)
        completion(true, nil)
        return
      }

      self.startCompletion = completion
      guard self.enqueueSample(initialFrame), controller.isPictureInPicturePossible else {
        self.finishStart(false, "Picture in Picture is not ready.")
        return
      }
      // Freeze Flutter before system PiP starts; delegates can be delayed on reuse.
      self.activeChanged?(true)
      controller.startPictureInPicture()
    }
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  func stop(completion: @escaping () -> Void) {
    let action = {
      guard let controller = self.controller,
        controller.isPictureInPictureActive || self.isActive
          || self.startCompletion != nil
      else {
        completion()
        return
      }
      self.stopCompletions.append(completion)
      if self.stopCompletions.count == 1 {
        controller.stopPictureInPicture()
      }
    }
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  func updatePlaying(_ playing: Bool) {
    let action = {
      self.setBoolProperty("pause", !playing)
      self.controller?.invalidatePlaybackState()
    }
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  func showPlaceholder() {
    let action = {
      self.activeChanged?(false)
      self.activeChanged = nil
      self.playbackChanged = nil
      self.playerHandle = nil
      if let placeholder = self.makeBlackPixelBuffer() {
        self.displayLayer.flush()
        _ = self.enqueueSample(placeholder)
      }
      self.controller?.invalidatePlaybackState()
    }
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  private func attach(
    playerHandle: OpaquePointer,
    activeChanged: @escaping (Bool) -> Void,
    playbackChanged: @escaping (Bool) -> Void
  ) {
    self.activeChanged?(false)
    self.playerHandle = playerHandle
    self.activeChanged = activeChanged
    self.playbackChanged = playbackChanged
  }

  private func finishStop() {
    let completions = stopCompletions
    stopCompletions.removeAll()
    completions.forEach { $0() }
  }

  @discardableResult
  func enqueue(_ source: CVPixelBuffer) -> Bool {
    return enqueueSample(source)
  }

  private func enqueueSample(_ source: CVPixelBuffer) -> Bool {
    guard let sampleBuffer = makeSampleBuffer(source) else { return false }

    let action = {
      if self.displayLayer.status == .failed {
        self.displayLayer.flush()
      }
      guard self.displayLayer.isReadyForMoreMediaData else { return false }
      self.displayLayer.enqueue(sampleBuffer)
      return true
    }
    if Thread.isMainThread {
      return action()
    }
    DispatchQueue.main.async { _ = action() }
    return true
  }

  private func prepareIfNeeded() {
    guard !prepared else { return }
    guard let window = activeWindow() else { return }

    let view = UIView(
      frame: CGRect(x: window.bounds.maxX - 2, y: 0, width: 2, height: 2)
    )
    view.isUserInteractionEnabled = false
    view.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
    displayLayer.frame = view.bounds
    displayLayer.videoGravity = .resizeAspect
    view.layer.addSublayer(displayLayer)

    if let flutterView = window.rootViewController?.view,
      flutterView.superview === window
    {
      window.insertSubview(view, belowSubview: flutterView)
    } else {
      window.addSubview(view)
      window.sendSubviewToBack(view)
    }
    sourceView = view

    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    self.controller = controller

    frameLock.lock()
    prepared = true
    frameLock.unlock()
  }

  private func updateSourceRect(_ sourceRect: CGRect?) {
    guard let sourceRect, sourceRect.width > 0, sourceRect.height > 0,
      let sourceView
    else { return }
    sourceView.frame = sourceRect
    displayLayer.frame = sourceView.bounds
    sourceView.layoutIfNeeded()
  }

  private func resetSourceView() {
    guard let sourceView, let window = sourceView.window else { return }
    sourceView.frame = CGRect(
      x: window.bounds.maxX - 2,
      y: 0,
      width: 2,
      height: 2
    )
    displayLayer.frame = sourceView.bounds
  }

  func dispose() {
    let action = {
      self.controller?.delegate = nil
      self.controller?.stopPictureInPicture()
      self.controller = nil
      self.displayLayer.flushAndRemoveImage()
      self.sourceView?.removeFromSuperview()
      self.sourceView = nil
      self.prepared = false
    }
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  private func finishStart(_ started: Bool, _ error: String?) {
    if !started {
      setPictureInPictureActive(false)
      resetSourceView()
    }
    let completion = startCompletion
    startCompletion = nil
    completion?(started, error)
  }

  private func setPictureInPictureActive(_ active: Bool) {
    frameLock.lock()
    pictureInPictureActive = active
    frameLock.unlock()
  }

  private func activeWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)
    }
    return UIApplication.shared.keyWindow
  }

  private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &format
      ) == noErr, let format
    else { return nil }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      ) == noErr, let sampleBuffer
    else { return nil }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ) as? [NSMutableDictionary] {
      attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    return sampleBuffer
  }

  private func makeBlackPixelBuffer() -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        9,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
      ) == kCVReturnSuccess, let pixelBuffer
    else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
      let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
      memset(baseAddress, 0, dataSize)
      let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
      for alphaOffset in stride(from: 3, to: dataSize, by: 4) {
        bytes[alphaOffset] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
  }

  private func doubleProperty(_ name: String) -> Double {
    guard let playerHandle else { return 0 }
    var value = 0.0
    mpv_get_property(playerHandle, name, MPV_FORMAT_DOUBLE, &value)
    return value.isFinite ? value : 0
  }

  private func boolProperty(_ name: String) -> Bool {
    guard let playerHandle else { return true }
    var value: Int32 = 0
    mpv_get_property(playerHandle, name, MPV_FORMAT_FLAG, &value)
    return value != 0
  }

  private func setBoolProperty(_ name: String, _ value: Bool) {
    guard let playerHandle else { return }
    var flag: Int32 = value ? 1 : 0
    mpv_set_property(playerHandle, name, MPV_FORMAT_FLAG, &flag)
  }

  private func setDoubleProperty(_ name: String, _ value: Double) {
    guard let playerHandle else { return }
    var value = value
    mpv_set_property_async(playerHandle, 0, name, MPV_FORMAT_DOUBLE, &value)
  }
}

@available(iOS 15.0, *)
extension MediaKitPictureInPictureImplementation:
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    // Apply immediately for AVKit, then notify Dart so PlayerState stays in sync.
    setBoolProperty("pause", !playing)
    playbackChanged?(playing)
    pictureInPictureController.invalidatePlaybackState()
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    boolProperty("pause")
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    let duration = doubleProperty("duration")
    guard duration > 0 else {
      return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let position = doubleProperty("time-pos")
    let duration = doubleProperty("duration")
    var target = max(0, position + skipInterval.seconds)
    if duration > 0 { target = min(target, duration) }
    setDoubleProperty("time-pos", target)
    completionHandler()
  }
}

@available(iOS 15.0, *)
extension MediaKitPictureInPictureImplementation: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    setPictureInPictureActive(true)
    activeChanged?(true)
    finishStart(true, nil)
    if !stopCompletions.isEmpty {
      pictureInPictureController.stopPictureInPicture()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    activeChanged?(false)
    finishStart(false, error.localizedDescription)
    finishStop()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    setPictureInPictureActive(false)
    activeChanged?(false)
    resetSourceView()
    finishStop()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
