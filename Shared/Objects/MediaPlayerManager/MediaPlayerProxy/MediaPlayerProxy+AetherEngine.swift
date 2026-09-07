//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AetherEngine
import Combine
import Defaults
import Foundation
import JellyfinAPI
import SwiftUI

// TODO: PiP / AirPlay (LoadOptions.prepareNativeSubtitles, engine.currentAVPlayer)
// TODO: ASS styling and cue placement; cues are drawn as plain centered text
// TODO: stop(resetDisplayCriteria: false) between queue items to avoid the tvOS panel bounce

/// Proxy for AetherEngine: FFmpeg demuxes, VideoToolbox and AVPlayer decode.
/// The engine emits subtitle cues instead of drawing them, so the video body
/// composites `SubtitleOverlay` above the player surface.
@MainActor
class AetherMediaPlayerProxy: VideoMediaPlayerProxy, MediaPlayerOffsetConfigurable {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let subtitleOffset: PublishedBox<Duration> = .init(initialValue: .zero)

    // ponytail: `init()` is marked throws but has no throwing path as of 6.73
    let engine: AetherEngine = try! AetherEngine()

    private var cancellables: Set<AnyCancellable> = []
    private var liveRetunes = 0
    private var loadTask: Task<Void, Never>?

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            cancellables.removeAll()
            guard let manager else { return }

            manager.$playbackItem
                .compactMap(\.self)
                .sink { [weak self] in
                    self?.liveRetunes = 0
                    self?.playNew(item: $0)
                }
                .store(in: &cancellables)

            manager.$rate
                .dropFirst()
                .sink { [weak self] in self?.setRate($0) }
                .store(in: &cancellables)

            engine.$state
                .sink { [weak self] in self?.engineStateChanged($0) }
                .store(in: &cancellables)

            // Live contract: the engine parks a dead live session and only a fresh load revives it
            engine.liveSourceReset
                .sink { [weak self] in
                    guard let self, let item = self.manager?.playbackItem else { return }

                    guard liveRetunes < 3 else {
                        self.manager?.error(ErrorMessage("AetherEngine: live source lost"))
                        return
                    }

                    liveRetunes += 1
                    self.manager?.logger.warning("AetherEngine live source reset, retuning (\(liveRetunes)/3)")
                    playNew(item: item)
                }
                .store(in: &cancellables)

            engine.$playbackPhase
                .map { phase in
                    switch phase {
                    case .loading, .rebuffering, .seeking, .stalled:
                        true
                    default:
                        false
                    }
                }
                .sink { [weak self] in self?.isBuffering.value = $0 }
                .store(in: &cancellables)

            engine.$sourceVideoWidth
                .combineLatest(engine.$sourceVideoHeight)
                .sink { [weak self] in self?.videoSize.value = CGSize(width: Int($0), height: Int($1)) }
                .store(in: &cancellables)

            engine.diagnostics.$liveTelemetry
                .sink { [weak self] in self?.droppedFrames.value = $0?.droppedFrameCount ?? 0 }
                .store(in: &cancellables)
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    func play() {
        engine.play()
        // A rate chosen while paused is applied on resume, see `setRate`
        engine.setRate(manager?.rate ?? 1)
    }

    func pause() {
        engine.pause()
    }

    func stop() {
        loadTask?.cancel()
        engine.stop()
    }

    func jumpForward(_ seconds: Duration) {
        seek(to: engine.currentTime + seconds.seconds)
    }

    func jumpBackward(_ seconds: Duration) {
        seek(to: engine.currentTime - seconds.seconds)
    }

    func setSeconds(_ seconds: Duration) {
        seek(to: seconds.seconds)
    }

    func setRate(_ rate: Float) {
        // A non-zero rate starts a paused AVPlayer, so only forward it while playing
        guard manager?.playbackRequestStatus == .playing else { return }
        engine.setRate(rate)
    }

    /// `stream.index` is already the engine track id, see `MediaTrackIndexMap.build`
    func setAudioStream(_ stream: MediaStream) {
        guard let index = stream.index, index >= 0 else { return }
        engine.selectAudioTrack(index: index)
    }

    func setSubtitleStream(_ stream: MediaStream) {
        guard let index = stream.index, index >= 0 else {
            engine.clearSubtitle()
            return
        }

        engine.selectSubtitleTrack(index: index)
    }

    func setAspectFill(_ aspectFill: Bool) {
        engine.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
    }

    func setAudioOffset(_ seconds: Duration) {
        engine.setAudioDelay(seconds.seconds)
    }

    func setSubtitleOffset(_ seconds: Duration) {
        subtitleOffset.value = seconds
    }

    private func seek(to seconds: Double) {
        let target = max(0, seconds)
        Task { await engine.seek(to: target) }
    }

    @ViewBuilder
    var videoPlayerBody: some View {
        AetherPlayerView()
            .environmentObject(self)
    }
}

extension AetherMediaPlayerProxy {

    private func engineStateChanged(_ state: PlaybackState) {
        switch state {
        case .playing:
            manager?.setPlaybackRequestStatus(status: .playing)
        case .paused:
            manager?.setPlaybackRequestStatus(status: .paused)
        case .ended:
            manager?.ended()
        case let .error(message):
            manager?.error(ErrorMessage("AetherEngine: \(message)"))
        case .idle, .loading, .seeking:
            ()
        }
    }

    private func playNew(item: MediaPlayerItem) {
        let baseItem = item.baseItem
        let isTranscoding = item.mediaSource.transcodingURL != nil

        var options = LoadOptions()
        options.isLive = baseItem.isLiveStream
        options.nativeRemoteHLS = baseItem.isLiveStream && item.url.pathExtension == "m3u8"
        options.externalSubtitles = item.subtitleStreams.sidecarSubtitles
            .compactMap(\.asAetherExternalSubtitle)

        let startPosition: Double? = baseItem.isLiveStream
            ? nil
            : max(.zero, (baseItem.startSeconds ?? .zero) - .seconds(Defaults[.VideoPlayer.resumeOffset])).seconds

        // Direct play only: an HLS transcode carries the single audio track the server already picked
        let audioSourceStreamIndex: Int32? = isTranscoding
            ? nil
            : item.indexMap.playerIndex(for: item.selectedAudioStreamIndex).flatMap { $0 >= 0 ? Int32($0) : nil }

        // Only tracks the engine can address: embedded on direct play, sidecars anywhere.
        // Resolved after the load so a change made while loading is not overridden.
        let currentSubtitleIndex: () -> Int? = {
            item.subtitleStreams
                .first { $0.index == item.selectedSubtitleStreamIndex && ($0.deliveryMethod == .embed || $0.deliveryMethod == .external) }
                .flatMap { item.indexMap.playerIndex(for: $0.index) }
        }

        manager?.logger.info(
            "AetherEngine loading item",
            metadata: [
                "isLive": .stringConvertible(options.isLive),
                "nativeRemoteHLS": .stringConvertible(options.nativeRemoteHLS),
                "sidecarSubtitles": .stringConvertible(options.externalSubtitles.count),
                "audioSourceStreamIndex": .stringConvertible(audioSourceStreamIndex ?? -1),
                "subtitleIndex": .stringConvertible(currentSubtitleIndex() ?? -1),
            ]
        )

        loadTask?.cancel()
        loadTask = Task { @MainActor [engine] in
            do {
                try await engine.load(
                    url: item.url,
                    startPosition: startPosition,
                    options: options,
                    audioSourceStreamIndex: audioSourceStreamIndex
                )
            } catch is CancellationError {
                return
            } catch {
                // The engine publishes `.error` before throwing and the `$state` sink already reported that
                if case .error = engine.state { return }
                await manager?.error(ErrorMessage("AetherEngine: \(error.localizedDescription)"))
                return
            }

            guard !Task.isCancelled else { return }

            setRate(manager?.rate ?? 1)

            if let subtitleIndex = currentSubtitleIndex(), subtitleIndex >= 0 {
                engine.selectSubtitleTrack(index: subtitleIndex)
            }
        }
    }
}

// MARK: - AetherPlayerView

extension AetherMediaPlayerProxy {

    struct AetherPlayerView: View {

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager
        @EnvironmentObject
        private var proxy: AetherMediaPlayerProxy

        var body: some View {
            ZStack {
                AetherPlayerSurface(engine: proxy.engine)

                SubtitleOverlay(engine: proxy.engine, offset: proxy.subtitleOffset)
            }
            .onReceive(
                proxy.engine.clock.$currentTime
                    // The engine zeroes its clock on load() and stop() after setting state
                        .filter { [engine = proxy.engine] _ in
                            switch engine.state {
                            case .idle, .loading, .error: false
                            default: true
                            }
                        }
                        .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            ) { seconds in
                let newSeconds = Duration.seconds(seconds)

                if !containerState.isScrubbing {
                    containerState.scrubbedSeconds.value = newSeconds
                }

                manager.seconds = newSeconds
            }
        }
    }

    /// Draws the engine's active cues: text bottom-centered in the
    /// user's subtitle font, bitmaps at their authored position.
    private struct SubtitleOverlay: View {

        @Default(.VideoPlayer.Subtitle.configuration)
        private var configuration

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState

        @ObservedObject
        var offset: PublishedBox<Duration>

        let engine: AetherEngine

        @State
        private var cues: [SubtitleCue] = []
        @State
        private var sourceTime: Double = 0

        init(engine: AetherEngine, offset: PublishedBox<Duration>) {
            self.engine = engine
            self.offset = offset
        }

        private var activeCues: [SubtitleCue] {
            let time = sourceTime - offset.value.seconds
            return cues.filter { $0.startTime <= time && time < $0.endTime }
        }

        /// The rect the picture occupies, from the source aspect and the container's fill mode
        private func videoRect(in size: CGSize) -> CGRect {
            let videoWidth = CGFloat(engine.sourceVideoWidth) * CGFloat(engine.sourceVideoPixelAspectRatio)
            let videoHeight = CGFloat(engine.sourceVideoHeight)

            guard videoWidth > 0, videoHeight > 0, size.width > 0, size.height > 0 else {
                return CGRect(origin: .zero, size: size)
            }

            let videoAspect = videoWidth / videoHeight
            let viewAspect = size.width / size.height
            let matchesWidth = containerState.isAspectFilled ? videoAspect < viewAspect : videoAspect > viewAspect
            let width = matchesWidth ? size.width : size.height * videoAspect
            let height = matchesWidth ? size.width / videoAspect : size.height

            return CGRect(
                x: (size.width - width) / 2,
                y: (size.height - height) / 2,
                width: width,
                height: height
            )
        }

        var body: some View {
            GeometryReader { geometry in
                let videoRect = videoRect(in: geometry.size)
                let activeCues = activeCues
                let textLines = activeCues.compactMap(\.text).filter(\.isNotEmpty)

                ZStack {
                    ForEach(activeCues) { cue in
                        if case let .image(image) = cue.body {
                            Image(decorative: image.cgImage, scale: 1)
                                .resizable()
                                .frame(
                                    width: image.position.width * videoRect.width,
                                    height: image.position.height * videoRect.height
                                )
                                .position(
                                    x: videoRect.minX + image.position.midX * videoRect.width,
                                    y: videoRect.minY + image.position.midY * videoRect.height
                                )
                        }
                    }

                    if textLines.isNotEmpty {
                        Text(textLines.joined(separator: "\n"))
                            // ponytail: size 1...20 scaled by view height; VLC's relative sizing has no point equivalent
                                .font(.custom(configuration.fontName, size: geometry.size.height * CGFloat(configuration.size) / 200))
                                .foregroundStyle(configuration.color)
                                .multilineTextAlignment(.center)
                                .shadow(color: .black, radius: 2)
                                .shadow(color: .black, radius: 1)
                                .padding(.horizontal, 24)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, geometry.size.height * 0.06)
                    }
                }
            }
            .allowsHitTesting(false)
            .onReceive(engine.$subtitleCues) { cues = $0 }
            .onReceive(engine.clock.$sourceTime) { sourceTime = $0 }
        }
    }
}

extension MediaStream {

    var asAetherExternalSubtitle: ExternalSubtitleTrack? {
        guard let url = resolvedDeliveryURL else { return nil }

        return .init(
            url: url,
            name: displayTitle,
            language: language,
            isForced: isForced == true
        )
    }
}
