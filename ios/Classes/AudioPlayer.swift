import Foundation
import AVKit
import AVFoundation

class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var seekToStart = true
    private var stopWhenCompleted = false
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var finishMode: FinishMode = FinishMode.stop
    private var updateFrequency = 200
    private var tempFileURL: URL?
    var plugin: SwiftAudioWaveformsPlugin
    var playerKey: String
    var flutterChannel: FlutterMethodChannel
    
    init(plugin: SwiftAudioWaveformsPlugin, playerKey: String, channel: FlutterMethodChannel) {
        self.plugin = plugin
        self.playerKey = playerKey
        flutterChannel = channel
    }
    
    private func validateAudioFile(at url: URL) throws {
        // Check if file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "AudioPlayer",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Audio file not found at path: \(url.path)"])
        }
        
        // Check if file is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw NSError(domain: "AudioPlayer",
                         code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Audio file is not readable"])
        }
        
        // Check file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? UInt64, fileSize > 0 else {
            throw NSError(domain: "AudioPlayer",
                         code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Audio file appears to be empty"])
        }
    }
    
    private func convertMP3ToM4A(inputURL: URL) throws -> URL {
        // Create a temporary file URL for the output with a unique name
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("converted_\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        
        // Validate input file
        try validateAudioFile(at: inputURL)
        
        // Create asset and validate
        let asset = AVAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else {
            throw NSError(domain: "AudioPlayer",
                         code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid audio file duration"])
        }
        
        // Create export session with error handling
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(domain: "AudioPlayer",
                         code: -5,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        
        // Configure export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.audioTimePitchAlgorithm = .varispeed
        
        // Remove any existing file at the output URL
        try? FileManager.default.removeItem(at: outputURL)
        
        // Convert synchronously with timeout
        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            semaphore.signal()
        }
        
        // Wait with timeout
        let timeout = DispatchTime.now() + .seconds(30)
        if semaphore.wait(timeout: timeout) == .timedOut {
            throw NSError(domain: "AudioPlayer",
                         code: -6,
                         userInfo: [NSLocalizedDescriptionKey: "Conversion timed out"])
        }
        
        // Check export status
        switch exportSession.status {
        case .completed:
            // Validate output file
            try validateAudioFile(at: outputURL)
            return outputURL
        case .failed:
            throw exportSession.error ?? NSError(domain: "AudioPlayer",
                                               code: -7,
                                               userInfo: [NSLocalizedDescriptionKey: "Export failed"])
        case .cancelled:
            throw NSError(domain: "AudioPlayer",
                         code: -8,
                         userInfo: [NSLocalizedDescriptionKey: "Export cancelled"])
        default:
            throw NSError(domain: "AudioPlayer",
                         code: -9,
                         userInfo: [NSLocalizedDescriptionKey: "Unexpected export status: \(exportSession.status.rawValue)"])
        }
    }
    
    func preparePlayer(path: String?, volume: Double?, updateFrequency: Int?, result: @escaping FlutterResult, overrideAudioSession: Bool) {
        guard let path = path, !path.isEmpty else {
            result(FlutterError(code: Constants.audioWaveforms,
                              message: "Audio file path can't be empty or null",
                              details: nil))
            return
        }
        
        self.updateFrequency = updateFrequency ?? 200
        
        // Clean up previous resources
        cleanupTempFiles()
        
        // Create URL based on path type
        let audioUrl: URL?
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            audioUrl = URL(string: path)
        } else {
            var cleanPath = path
            if cleanPath.hasPrefix("file://") {
                cleanPath = String(cleanPath.dropFirst(7))
            }
            audioUrl = URL(fileURLWithPath: cleanPath)
        }
        
        guard let audioUrl = audioUrl else {
            result(FlutterError(code: Constants.audioWaveforms,
                              message: "Invalid audio file URL",
                              details: "Could not create URL from path: \(path)"))
            return
        }
        
        Task {
            do {
                // Configure audio session
                if overrideAudioSession {
                    try AVAudioSession.sharedInstance().setCategory(.playback,
                                                                  mode: .default,
                                                                  options: [])
                    try AVAudioSession.sharedInstance().setActive(true)
                }
                
                var finalURL = audioUrl
                
                // Validate input file for local files
                if audioUrl.isFileURL {
                    try validateAudioFile(at: audioUrl)
                }
                
                // Convert MP3 if necessary
                if audioUrl.pathExtension.lowercased() == "mp3" {
                    print("Converting MP3 to M4A...")
                    finalURL = try await convertMP3ToM4A(inputURL: audioUrl)
                    tempFileURL = finalURL
                }
                
                // Create and configure audio player
                player = try AVAudioPlayer(contentsOf: finalURL)
                guard let player = player else {
                    throw NSError(domain: "AudioPlayer",
                                code: -10,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AVAudioPlayer"])
                }
                
                player.delegate = self
                player.enableRate = true
                player.rate = 1.0
                
                // Prepare player
                guard player.prepareToPlay() else {
                    throw NSError(domain: "AudioPlayer",
                                code: -11,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare audio player"])
                }
                
                player.volume = Float(volume ?? 1.0)
                
                // Final validation
                guard player.duration > 0 else {
                    throw NSError(domain: "AudioPlayer",
                                code: -12,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid audio duration after preparation"])
                }
                
                result(true)
                
            } catch {
                print("Player initialization error: \(error.localizedDescription)")
                cleanupTempFiles()
                result(FlutterError(code: Constants.audioWaveforms,
                                  message: "Failed to prepare player",
                                  details: error.localizedDescription))
            }
        }
    }
    
    private func cleanupTempFiles() {
        if let tempURL = tempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            tempFileURL = nil
        }
    }
    // Add cleanup to existing methods
    func stopPlayer(result: @escaping FlutterResult) {
        stopListening()
        player?.stop()
        timer = nil
        cleanupTempFiles()
        result(true)
    }
    
    func release(result: @escaping FlutterResult) {
        player = nil
        cleanupTempFiles()
        result(true)
    }

    func getDuration(_ type: DurationType, _ result: @escaping FlutterResult) throws {
        if type == .Current {
            let ms = (player?.currentTime ?? 0) * 1000
            result(Int(ms))
        } else {
            let ms = (player?.duration ?? 0) * 1000
            result(Int(ms))
        }
    }
    
    func setVolume(_ volume: Double?, _ result: @escaping FlutterResult) {
        player?.volume = Float(volume ?? 1.0)
        result(true)
    }
    
    func setRate(_ rate: Double?, _ result: @escaping FlutterResult) {
        player?.rate = Float(rate ?? 1.0);
        result(true)
    }
    
    func seekTo(_ time: Int?, _ result: @escaping FlutterResult) {
        if(time != nil) {
            player?.currentTime = Double(time! / 1000)
            sendCurrentDuration()
            result(true)
        } else {
            result(false)
        }
    }
    
    func startListening() {
        if #available(iOS 10.0, *) {
            timer = Timer.scheduledTimer(withTimeInterval: (Double(updateFrequency) / 1000), repeats: true, block: { _ in
                self.sendCurrentDuration()
            })
        } else {
            // Fallback on earlier versions
        }
    }
    
    func stopListening() {
        timer?.invalidate()
        timer = nil
        sendCurrentDuration()
    }

    func sendCurrentDuration() {
        let ms = (player?.currentTime ?? 0) * 1000
        flutterChannel.invokeMethod(Constants.onCurrentDuration, arguments: [Constants.current: Int(ms), Constants.playerKey: playerKey])
    }
}
