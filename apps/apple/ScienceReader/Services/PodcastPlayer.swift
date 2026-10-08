import AVFoundation
import MediaPlayer
import Observation
import ScienceReaderCore

/// One verified local audio file at a time (docs/architecture/PAPER_PODCASTS.md, "Storage, bounded delivery and offline
/// sync"): AVPlayer over a file the center has already checked byte for byte; never a remote URL or a Range request.
/// Background audio, Now Playing, the lock screen / headphone / Control Center commands, interruptions (a call, Siri,
/// another app) and route changes (headphones unplugged) are handled here; positions are reported to the center.
@MainActor @Observable
final class PodcastPlayer {
    enum SaveReason { case periodic, paused, chapter, seek, finished, stopped }
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static let skipSeconds = 15

    private(set) var episode: PodcastEpisode?
    private(set) var isPlaying = false
    private(set) var currentMS = 0
    private(set) var durationMS = 0
    private(set) var chapterID: String?
    /// "Paused for a call" and similar, shown once in the player.
    private(set) var notice: String?
    var rate: Float = 1 {
        didSet {
            guard rate != oldValue else { return }
            player?.defaultRate = rate
            if isPlaying { player?.rate = rate }
            updateNowPlaying()
        }
    }
    /// Called with the playing episode's position whenever it should be saved (center: device-local history).
    @ObservationIgnored var onSave: ((PodcastEpisode, Int, Int, Bool, SaveReason) -> Void)?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var lastPeriodicSave = Date.distantPast

    var progress: Double { durationMS > 0 ? min(1, Double(currentMS) / Double(durationMS)) : 0 }
    var chapter: PodcastChapter? { episode?.chapters?.first { $0.id == chapterID } }

    /// Loads `episode` from a verified local file and seeks to `startMS`. Playback starts only when `autoplay`.
    func load(_ episode: PodcastEpisode, fileURL: URL, startMS: Int, autoplay: Bool) {
        if self.episode != nil { stop(reason: .stopped) }
        self.episode = episode; durationMS = episode.durationMS; notice = nil
        let item = AVPlayerItem(url: fileURL)
        // Speech at 1.5× or 2× stays natural with the time-domain algorithm.
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.defaultRate = rate
        // No silent background preloading of anything else: the file is local and complete.
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        currentMS = max(0, min(startMS, episode.durationMS)); chapterID = chapterID(at: currentMS)
        if currentMS > 0 { player.seek(to: CMTime(value: CMTimeValue(currentMS), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        })
        observeSession()
        registerCommands()
        updateNowPlaying()
        if autoplay { play() }
    }

    func play() {
        guard let player, episode != nil else { return }
        if durationMS > 0, currentMS >= durationMS - 250 { seek(toMS: 0) }
        let session = AVAudioSession.sharedInstance()
        do {
            // Long-form spoken audio: routes to AirPlay/Bluetooth like a podcast app and keeps playing in the background.
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch { notice = "Audio isn’t available right now." ; return }
        player.playImmediately(atRate: rate)
        isPlaying = true; notice = nil
        updateNowPlaying()
    }

    func pause(reason: SaveReason = .paused) {
        guard let player else { return }
        player.pause(); isPlaying = false
        save(reason)
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func skip(by seconds: Int) { seek(toMS: currentMS + seconds * 1000) }

    func seek(toMS milliseconds: Int) {
        guard let player else { return }
        let target = max(0, min(milliseconds, max(0, durationMS - 100)))
        currentMS = target
        player.seek(to: CMTime(value: CMTimeValue(target), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        let chapter = chapterID(at: target)
        chapterID = chapter
        save(.seek)
        updateNowPlaying()
    }

    /// Explicit Stop: the only way playback ends besides finishing (dismissing the sheet keeps it playing).
    func stop(reason: SaveReason = .stopped) {
        guard player != nil else { return }
        player?.pause()
        save(reason)
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        unregisterCommands()
        player?.replaceCurrentItem(with: nil); player = nil
        episode = nil; isPlaying = false; currentMS = 0; durationMS = 0; chapterID = nil; notice = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Saves the position now (the app moving to the background, an account change).
    func saveNow() { if episode != nil { save(.paused) } }

    // MARK: Internals

    private func tick(_ time: CMTime) {
        guard episode != nil, time.isNumeric else { return }
        let milliseconds = max(0, Int(time.seconds * 1000))
        // A seek in flight reports the old time for a moment; keep the requested position until playing moves past it.
        if isPlaying || abs(milliseconds - currentMS) < 1500 { currentMS = min(milliseconds, durationMS) }
        if isPlaying, player?.timeControlStatus == .paused, player?.reasonForWaitingToPlay == nil, player?.rate == 0 {
            // The system paused us (an interruption whose notification hasn't arrived, a route change).
            isPlaying = false; updateNowPlaying()
        }
        let chapter = chapterID(at: currentMS)
        if chapter != chapterID { chapterID = chapter; save(.chapter); updateNowPlaying() }
        else if isPlaying, Date().timeIntervalSince(lastPeriodicSave) >= 15 { save(.periodic) }
    }

    private func finished() {
        isPlaying = false; currentMS = durationMS
        save(.finished)
        updateNowPlaying()
    }

    private func save(_ reason: SaveReason) {
        guard let episode else { return }
        lastPeriodicSave = Date()
        onSave?(episode, currentMS, durationMS, reason == .finished || (durationMS > 0 && currentMS >= durationMS - 1000), reason)
    }

    private func chapterID(at milliseconds: Int) -> String? {
        episode?.chapters?.last { $0.startMS <= milliseconds }?.id ?? episode?.chapters?.first?.id
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    // The system has already paused output; record it and remember to resume if allowed.
                    self.resumeAfterInterruption = self.isPlaying
                    if self.isPlaying { self.player?.pause(); self.isPlaying = false; self.save(.paused); self.updateNowPlaying() }
                    if self.resumeAfterInterruption { self.notice = "Paused for an interruption." }
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
                    if self.resumeAfterInterruption, options.contains(.shouldResume) { self.play() }
                    self.resumeAfterInterruption = false
                @unknown default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones removed: pause rather than continue out loud (the platform convention).
                guard let self, let reasonValue, AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause(); self.notice = "Paused because the audio output changed."
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The player's audio objects are gone: keep the position, stop cleanly, let the reader press Play again.
                guard let self, let episode = self.episode else { return }
                self.pause(); self.notice = "Audio restarted. Press Play to continue \(episode.fixture ? "the fixture" : "listening")."
            }
        })
    }

    private func registerCommands() {
        unregisterCommands()
        let commands = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: handler)))
        }
        add(commands.playCommand) { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        add(commands.pauseCommand) { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        add(commands.togglePlayPauseCommand) { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        add(commands.skipForwardCommand) { [weak self] _ in MainActor.assumeIsolated { self?.skip(by: Self.skipSeconds) }; return .success }
        add(commands.skipBackwardCommand) { [weak self] _ in MainActor.assumeIsolated { self?.skip(by: -Self.skipSeconds) }; return .success }
        commands.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        add(commands.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent, Self.rates.contains(event.playbackRate) else { return .commandFailed }
            MainActor.assumeIsolated { self?.rate = event.playbackRate }; return .success
        }
        add(commands.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(toMS: Int(event.positionTime * 1000)) }; return .success
        }
        // Chapters aren't tracks: next/previous would skip whole episodes in other apps' convention.
        commands.nextTrackCommand.isEnabled = false; commands.previousTrackCommand.isEnabled = false
    }

    private func unregisterCommands() {
        for (command, target) in commandTargets { command.removeTarget(target); command.isEnabled = false }
        commandTargets = []
    }

    private func updateNowPlaying() {
        guard let episode else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.displayTitle,
            MPMediaItemPropertyArtist: episode.fixture ? "Gradstep · Synthetic fixture" : "Gradstep · AI audio",
            MPMediaItemPropertyPlaybackDuration: Double(durationMS) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(currentMS) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let chapter { info[MPMediaItemPropertyAlbumTitle] = chapter.title }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if targetEnvironment(macCatalyst)
        // The Mac's Now Playing reads the state explicitly; iOS derives it from the rate above.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
}
