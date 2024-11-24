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
    var plugin: SwiftAudioWaveformsPlugin
    var playerKey: String
    var flutterChannel: FlutterMethodChannel
    private var tempFileURL: URL? // To store converted file reference
    
    init(plugin: SwiftAudioWaveformsPlugin, playerKey: String, channel: FlutterMethodChannel) {
        self.plugin = plugin
        self.playerKey = playerKey
        flutterChannel = channel
    }
    
    private func convertMP3ToM4A(inputURL: URL) throws -> URL {
        // Create a temporary file URL for the output
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        // Create asset and export session
        let asset = AVAsset(url: inputURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(domain: "AudioPlayer", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Could not create export session"])
        }
        
        // Configure export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.audioTimePitchAlgorithm = .varispeed
        
        // Convert synchronously (since we need the file before continuing)
        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        
        if let error = exportSession.error {
            throw error
        }
        
        return outputURL
    }
    
    private func cleanupTempFiles() {
        if let tempURL = tempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            tempFileURL = nil
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
        
        // Clean up any previous temp files
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
                              message: "Failed to initialize URL from provided audio file", 
                              details: "Invalid path format"))
            return
        }
        
        do {
            // Configure audio session
            if overrideAudioSession {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
            }
            
            // Check if file exists for local files
            if audioUrl.isFileURL && !FileManager.default.fileExists(atPath: audioUrl.path) {
                result(FlutterError(code: Constants.audioWaveforms, 
                                  message: "Audio file not found", 
                                  details: "File does not exist at path: \(audioUrl.path)"))
                return
            }
            
            var finalURL = audioUrl
            // If it's an MP3 file, convert it to M4A
            if audioUrl.pathExtension.lowercased() == "mp3" {
                print("Converting MP3 to M4A for better iOS compatibility...")
                finalURL = try convertMP3ToM4A(inputURL: audioUrl)
                tempFileURL = finalURL // Store reference for cleanup
            }
            
            // Create audio player
            player = try AVAudioPlayer(contentsOf: finalURL)
            player?.enableRate = true
            player?.rate = 1.0
            player?.prepareToPlay()
            player?.volume = Float(volume ?? 1.0)
            
            result(true)
            
        } catch {
            print("Player initialization error: \(error.localizedDescription)")
            cleanupTempFiles()
            result(FlutterError(code: Constants.audioWaveforms, 
                              message: "Failed to prepare player", 
                              details: error.localizedDescription))
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
