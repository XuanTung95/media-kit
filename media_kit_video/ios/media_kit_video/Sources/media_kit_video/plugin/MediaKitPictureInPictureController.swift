import AVFoundation
import AVKit
import UIKit

#if SWIFT_PACKAGE
  import Mpv
#endif

/// Availability-safe wrapper because media_kit_video still supports pre-iOS 15.
final class MediaKitPictureInPictureController {
  private let handle: OpaquePointer
  private let activeChanged: (Bool) -> Void
  private let playbackChanged: (Bool) -> Void
  private let frameLock = NSLock()
  private var implementation: AnyObject?
  private var latestFrame: CVPixelBuffer?
  private var preparingImplementation = false

  init(
    handle: OpaquePointer,
    activeChanged: @escaping (Bool) -> Void,
    playbackChanged: @escaping (Bool) -> Void
  ) {
    self.handle = handle
    self.activeChanged = activeChanged
    self.playbackChanged = playbackChanged
  }

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
    playing: Bool,
    sourceRect: CGRect?,
    completion: @escaping (Bool, String?) -> Void
  ) {
    guard isSupported else {
      completion(false, "System Picture in Picture requires iOS 15 or newer.")
      return
    }

    if #available(iOS 15.0, *) {
      frameLock.lock()
      let initialFrame = latestFrame
      let existingImplementation = implementation
      frameLock.unlock()
      guard let initialFrame else {
        completion(false, "Video is not ready for Picture in Picture.")
        return
      }
      guard
        let implementation = existingImplementation
          as? MediaKitPictureInPictureImplementation
      else {
        completion(false, "Picture in Picture is not ready.")
        return
      }
      implementation.start(
        initialFrame: initialFrame,
        playing: playing,
        sourceRect: sourceRect,
        completion: completion
      )
    }
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

  func updatePlaying(_ playing: Bool) {
    frameLock.lock()
    let implementation = implementation
    frameLock.unlock()
    guard #available(iOS 15.0, *),
      let implementation = implementation as? MediaKitPictureInPictureImplementation
    else { return }
    implementation.updatePlaying(playing)
  }

  func enqueue(_ pixelBuffer: CVPixelBuffer) {
    frameLock.lock()
    latestFrame = pixelBuffer
    let implementation = implementation
    let shouldPrepare = implementation == nil && !preparingImplementation
    if shouldPrepare {
      preparingImplementation = true
    }
    frameLock.unlock()

    guard #available(iOS 15.0, *), isSupported else { return }
    if let implementation = implementation as? MediaKitPictureInPictureImplementation {
      implementation.enqueue(pixelBuffer)
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
        ?? MediaKitPictureInPictureImplementation(
          handle: self.handle,
          activeChanged: self.activeChanged,
          playbackChanged: self.playbackChanged
        )
      self.frameLock.lock()
      self.implementation = implementation
      self.preparingImplementation = false
      self.frameLock.unlock()
      implementation.prewarm(pixelBuffer)
    }
  }
}

@available(iOS 15.0, *)
private final class MediaKitPictureInPictureImplementation: NSObject {
  private let handle: OpaquePointer
  private let activeChanged: (Bool) -> Void
  private let playbackChanged: (Bool) -> Void
  private let displayLayer = AVSampleBufferDisplayLayer()
  private let frameLock = NSLock()

  private var sourceView: UIView?
  private var controller: AVPictureInPictureController?
  private var prepared = false
  private var pictureInPictureActive = false
  private var startCompletion: ((Bool, String?) -> Void)?
  private var stopCompletions: [() -> Void] = []

  init(
    handle: OpaquePointer,
    activeChanged: @escaping (Bool) -> Void,
    playbackChanged: @escaping (Bool) -> Void
  ) {
    self.handle = handle
    self.activeChanged = activeChanged
    self.playbackChanged = playbackChanged
    super.init()
  }

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
    initialFrame: CVPixelBuffer,
    playing: Bool,
    sourceRect: CGRect?,
    completion: @escaping (Bool, String?) -> Void
  ) {
    let action = {
      guard self.startCompletion == nil else {
        completion(false, "Picture in Picture is already starting.")
        return
      }
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
        self.activeChanged(true)
        completion(true, nil)
        return
      }

      self.startCompletion = completion
      guard self.enqueueSample(initialFrame), controller.isPictureInPicturePossible else {
        self.finishStart(false, "Picture in Picture is not ready.")
        return
      }
      // Freeze Flutter before system PiP starts; delegates can be delayed on reuse.
      self.activeChanged(true)
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
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &format
    ) == noErr, let format else { return nil }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else { return nil }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ) as? [NSMutableDictionary] {
      attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    return sampleBuffer
  }

  private func doubleProperty(_ name: String) -> Double {
    var value = 0.0
    mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
    return value.isFinite ? value : 0
  }

  private func boolProperty(_ name: String) -> Bool {
    var value: Int32 = 0
    mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
    return value != 0
  }

  private func setBoolProperty(_ name: String, _ value: Bool) {
    var flag: Int32 = value ? 1 : 0
    mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
  }

  private func setDoubleProperty(_ name: String, _ value: Double) {
    var value = value
    mpv_set_property_async(handle, 0, name, MPV_FORMAT_DOUBLE, &value)
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
    playbackChanged(playing)
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
    activeChanged(true)
    finishStart(true, nil)
    if !stopCompletions.isEmpty {
      pictureInPictureController.stopPictureInPicture()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    activeChanged(false)
    finishStart(false, error.localizedDescription)
    finishStop()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    setPictureInPictureActive(false)
    activeChanged(false)
    resetSourceView()
    finishStop()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
