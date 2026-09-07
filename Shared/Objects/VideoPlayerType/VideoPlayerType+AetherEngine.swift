//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension VideoPlayerType {

    // MARK: - Direct Play

    /// Everything the bundled FFmpeg demuxes and VideoToolbox or
    /// libavcodec decodes. Mirrors the engine author's own Jellyfin
    /// client profile; ASF/WMV containers are absent on purpose.
    @ArrayBuilder<DirectPlayProfile>
    static var _aetherDirectPlayProfiles: [DirectPlayProfile] {
        DirectPlayProfile(type: .video) {
            AudioCodec.aac
            AudioCodec.ac3
            AudioCodec.alac
            AudioCodec.dts
            AudioCodec.dts_hd
            AudioCodec.eac3
            AudioCodec.flac
            AudioCodec.mlp
            AudioCodec.mp2
            AudioCodec.mp3
            AudioCodec.opus
            AudioCodec.pcm_bluray
            AudioCodec.pcm_s16le
            AudioCodec.pcm_s24le
            AudioCodec.truehd
            AudioCodec.vorbis
        } videoCodecs: {

            /// Without hardware AV1 the engine falls back to its dav1d software decoder
            VideoCodec.av1
            VideoCodec.h264
            VideoCodec.hevc
            VideoCodec.mpeg2video
            VideoCodec.mpeg4
            VideoCodec.msmpeg4v1
            VideoCodec.msmpeg4v2
            VideoCodec.msmpeg4v3
            VideoCodec.vc1
            VideoCodec.vp8
            VideoCodec.vp9
            VideoCodec.wmv1
            VideoCodec.wmv2
            VideoCodec.wmv3

        } containers: {
            MediaContainer.avi
            MediaContainer.flv
            MediaContainer.m4v
            MediaContainer.mkv
            MediaContainer.mov
            MediaContainer.mp4
            MediaContainer.mpegts
            MediaContainer.ts
            MediaContainer.threeG2
            MediaContainer.threeGP
            MediaContainer.webm
        }
    }

    // MARK: - Transcoding

    /// HLS transcodes skip the demuxer and play through AVPlayer directly,
    /// so this is the native profile without in-manifest subtitles: those
    /// are delivered as sidecars instead, which the engine addresses by index.
    @ArrayBuilder<TranscodingProfile>
    static var _aetherTranscodingProfiles: [TranscodingProfile] {
        TranscodingProfile(
            isBreakOnNonKeyFrames: true,
            context: .streaming,
            maxAudioChannels: "8",
            minSegments: 2,
            protocol: MediaStreamProtocol.hls,
            type: .video
        ) {
            AudioCodec.aac
            AudioCodec.ac3
            AudioCodec.alac
            AudioCodec.eac3
            AudioCodec.flac
        } videoCodecs: {

            /// - Note: Transcode Profiles prioritizes codecs by order
            if PlaybackCapabilities.supportsAV1 {
                VideoCodec.av1
            }
            if PlaybackCapabilities.supportsHEVC {
                VideoCodec.hevc
            }

            VideoCodec.h264

        } containers: {
            MediaContainer.mp4
        }
    }

    // MARK: - Subtitle

    /// Embedded text and bitmap tracks are decoded by the engine and drawn
    /// by Swiftfin; anything else is converted to a subrip sidecar or burned in.
    @ArrayBuilder<SubtitleProfile>
    static var _aetherSubtitleProfiles: [SubtitleProfile] {
        SubtitleProfile.build(method: .embed) {
            SubtitleFormat.ass
            SubtitleFormat.cc_dec
            SubtitleFormat.dvbsub
            SubtitleFormat.dvdsub
            SubtitleFormat.libzvbi_teletextdec
            SubtitleFormat.mov_text
            SubtitleFormat.pgssub
            SubtitleFormat.ssa
            SubtitleFormat.subrip
            SubtitleFormat.vtt
        }

        /// - Note: Unmatched text subtitles are converted to the first option (subrip)
        SubtitleProfile.build(method: .external) {
            SubtitleFormat.subrip
            SubtitleFormat.ass
            SubtitleFormat.ssa
            SubtitleFormat.vtt
        }
    }
}
