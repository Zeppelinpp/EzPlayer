import Cocoa
import SwiftUI
import AVFoundation
import Accelerate

// MARK: - Monokai Pro Colors
struct MonokaiPro {
    static let background = Color(hex: "2D2A2E")
    static let backgroundLight = Color(hex: "403E41")
    static let foreground = Color(hex: "FCFCFA")
    static let gray = Color(hex: "727072")
    static let red = Color(hex: "FF6188")
    static let orange = Color(hex: "FC9867")
    static let yellow = Color(hex: "FFD866")
    static let green = Color(hex: "A9DC76")
    static let blue = Color(hex: "78DCE8")
    static let purple = Color(hex: "AB9DF2")
}

// MARK: - Audio Engine Manager
class AudioEngineManager: ObservableObject {
    private var audioEngine: AVAudioEngine!
    private var playerNode: AVAudioPlayerNode!
    private var timePitchNode: AVAudioUnitTimePitch!
    private var mixerNode: AVAudioMixerNode!
    private var audioFile: AVAudioFile?
    
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var waveformSamples: [Float] = []
    @Published var playbackRate: Float = 1.0
    @Published var volume: Float = 0.8
    @Published var fileName: String = ""
    @Published var errorMessage: String = ""
    
    // Loop markers (Start/End)
    @Published var loopPointStart: Double? = nil
    @Published var loopPointEnd: Double? = nil
    @Published var isLooping: Bool = false
    @Published var clickedTime: Double? = nil  // Last clicked position on waveform
    
    private var seekOffset: AVAudioFramePosition = 0
    private var audioLengthSamples: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var loopTimer: Timer?
    
    init() {
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        timePitchNode = AVAudioUnitTimePitch()
        mixerNode = AVAudioMixerNode()
        
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitchNode)
        audioEngine.attach(mixerNode)
        
        timePitchNode.pitch = 0
        timePitchNode.rate = playbackRate
    }
    
    func loadFile(url: URL) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        playerNode.stop()
        audioEngine.reset()
        setupAudioEngine()
        
        do {
            audioFile = try AVAudioFile(forReading: url)
            guard let file = audioFile else { 
                errorMessage = "Cannot open file"
                return 
            }
            
            fileName = url.lastPathComponent
            audioLengthSamples = file.length
            sampleRate = file.processingFormat.sampleRate
            duration = Double(audioLengthSamples) / sampleRate
            
            let processingFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: file.processingFormat.channelCount)!
            
            audioEngine.connect(playerNode, to: timePitchNode, format: processingFormat)
            audioEngine.connect(timePitchNode, to: mixerNode, format: processingFormat)
            audioEngine.connect(mixerNode, to: audioEngine.mainMixerNode, format: processingFormat)
            
            mixerNode.outputVolume = volume
            
            try audioEngine.start()
            playerNode.scheduleFile(file, at: nil)
            generateWaveform(from: url)
            errorMessage = ""
            
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }
    
    private func generateWaveform(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                let file = try AVAudioFile(forReading: url)
                let format = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)!
                
                let frameCount = AVAudioFrameCount(file.length)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
                guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return }
                
                let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
                try file.read(into: inputBuffer)
                
                buffer.frameLength = frameCount
                
                var error: NSError?
                converter.convert(to: buffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                
                guard let channelData = buffer.floatChannelData?[0] else { return }
                
                let totalFrames = Int(buffer.frameLength)
                let samplesPerPixel = max(1, totalFrames / 500)
                var samples: [Float] = []
                
                for i in stride(from: 0, to: totalFrames, by: samplesPerPixel) {
                    let end = min(i + samplesPerPixel, totalFrames)
                    var maxVal: Float = 0
                    for j in i..<end {
                        let absVal = abs(channelData[j])
                        if absVal > maxVal { maxVal = absVal }
                    }
                    samples.append(maxVal)
                }
                
                DispatchQueue.main.async {
                    self.waveformSamples = samples
                }
            } catch {}
        }
    }
    
    func play() {
        guard audioFile != nil else { return }
        if !isPlaying {
            playerNode.play()
            isPlaying = true
            startTimeUpdates()
        }
    }
    
    func pause() {
        playerNode.pause()
        isPlaying = false
    }
    
    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }
    
    func seek(to time: Double) {
        guard let file = audioFile else { return }
        
        let wasPlaying = isPlaying
        playerNode.stop()
        
        let startFrame = AVAudioFramePosition(time * sampleRate)
        let frameCount = AVAudioFrameCount(audioLengthSamples - startFrame)
        
        if frameCount > 0 && startFrame < audioLengthSamples {
            seekOffset = startFrame
            playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
            if wasPlaying {
                playerNode.play()
                isPlaying = true
            }
        }
        currentTime = time
    }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        timePitchNode.rate = rate
    }
    
    func setVolume(_ vol: Float) {
        volume = vol
        mixerNode.outputVolume = vol
    }
    
    // Set clicked position on waveform
    func setClickedTime(_ time: Double) {
        clickedTime = max(0, min(duration, time))
    }
    
    // Set Start point (loop start)
    func setLoopPointStart() {
        guard let clicked = clickedTime else { return }
        loopPointStart = clicked
        
        // If End exists and Start > End, clear End
        if let end = loopPointEnd, clicked >= end {
            loopPointEnd = nil
        }
        
        updateLoopState()
    }
    
    // Set End point (loop end)
    func setLoopPointEnd() {
        guard let clicked = clickedTime else { return }
        
        // If Start exists and End < Start, clear all and set End as new Start
        if let start = loopPointStart, clicked <= start {
            loopPointStart = clicked
            loopPointEnd = nil
            isLooping = false
            return
        }
        
        loopPointEnd = clicked
        updateLoopState()
    }
    
    // Clear all loop markers
    func clearLoopMarkers() {
        loopPointStart = nil
        loopPointEnd = nil
        isLooping = false
    }
    
    private func updateLoopState() {
        isLooping = loopPointStart != nil && loopPointEnd != nil
    }
    
    // Jump to start point or beginning
    func jumpToStart() {
        if let start = loopPointStart {
            seek(to: start)
        } else {
            seek(to: 0)
        }
    }
    
    private func startTimeUpdates() {
        loopTimer?.invalidate()
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if !self.isPlaying { timer.invalidate(); return }
            
            if let nodeTime = self.playerNode.lastRenderTime,
               let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
                let framePosition = playerTime.sampleTime + self.seekOffset
                self.currentTime = Double(framePosition) / self.sampleRate
                
                // Loop check
                if self.isLooping, let start = self.loopPointStart, let end = self.loopPointEnd {
                    if self.currentTime >= end {
                        self.seek(to: start)
                        return
                    }
                }
                
                if self.currentTime >= self.duration {
                    self.currentTime = 0
                    self.seekOffset = 0
                    self.isPlaying = false
                }
            }
        }
    }
    
    func cleanup() {
        playerNode.stop()
        audioEngine.stop()
    }
}

// MARK: - Waveform View
struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let duration: Double
    let loopStart: Double?
    let loopEnd: Double?
    let isLooping: Bool
    let onSeek: (Double) -> Void
    let onClick: (Double) -> Void
    
    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let displayProgress = isDragging ? dragProgress : progress
            
            // Calculate loop positions
            let startPos = duration > 0 && loopStart != nil ? (loopStart! / duration) : nil
            let endPos = duration > 0 && loopEnd != nil ? (loopEnd! / duration) : nil
            
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(MonokaiPro.backgroundLight.opacity(0.5))
                
                // Loop highlight region
                if let sPos = startPos, let ePos = endPos, isLooping {
                    Rectangle()
                        .fill(MonokaiPro.purple.opacity(0.25))
                        .frame(width: (ePos - sPos) * width)
                        .position(x: (sPos + ePos) / 2 * width, y: height / 2)
                }
                
                // Waveform
                Canvas { context, size in
                    let barCount = min(samples.count, Int(size.width / 2.5))
                    let barWidth: CGFloat = 1.5
                    let gap: CGFloat = 1
                    let centerY = size.height / 2
                    
                    for i in 0..<barCount {
                        let x = CGFloat(i) * (barWidth + gap) + gap
                        let normalizedIndex = Double(i) / Double(max(1, barCount - 1))
                        let sampleIndex = Int(normalizedIndex * Double(samples.count - 1))
                        let sample = samples.isEmpty ? 0 : samples[min(sampleIndex, samples.count - 1)]
                        let barHeight = CGFloat(sample) * (size.height * 0.42)
                        
                        // Determine color based on position
                        var color: Color
                        let isPlayed = normalizedIndex <= displayProgress
                        
                        // Check if in loop region
                        let inLoopRegion = startPos != nil && endPos != nil && 
                            normalizedIndex >= startPos! && normalizedIndex <= endPos!
                        
                        if inLoopRegion && isLooping {
                            color = isPlayed ? MonokaiPro.yellow : MonokaiPro.orange.opacity(0.7)
                        } else {
                            color = isPlayed ? MonokaiPro.green : MonokaiPro.gray.opacity(0.6)
                        }
                        
                        // Top bar
                        let topRect = CGRect(x: x, y: centerY - barHeight, width: barWidth, height: barHeight)
                        context.fill(Path(roundedRect: topRect, cornerRadius: 0.5), with: .color(color))
                        
                        // Bottom bar
                        let bottomRect = CGRect(x: x, y: centerY, width: barWidth, height: barHeight)
                        context.fill(Path(roundedRect: bottomRect, cornerRadius: 0.5), with: .color(color.opacity(0.5)))
                    }
                }
                .padding(.horizontal, 6)
                
                // Center line
                Rectangle()
                    .fill(MonokaiPro.gray.opacity(0.3))
                    .frame(height: 1)
                
                // Start marker (S)
                if let sPos = startPos {
                    ZStack {
                        Rectangle()
                            .fill(MonokaiPro.red)
                            .frame(width: 2)
                        
                        // S label
                        Text("S")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(MonokaiPro.background)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(MonokaiPro.red)
                            .cornerRadius(3)
                            .offset(y: -height / 2 + 12)
                    }
                    .position(x: sPos * width, y: height / 2)
                }
                
                // End marker (E)
                if let ePos = endPos {
                    ZStack {
                        Rectangle()
                            .fill(MonokaiPro.blue)
                            .frame(width: 2)
                        
                        // E label
                        Text("E")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(MonokaiPro.background)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(MonokaiPro.blue)
                            .cornerRadius(3)
                            .offset(y: -height / 2 + 12)
                    }
                    .position(x: ePos * width, y: height / 2)
                }
                
                // Playhead
                Rectangle()
                    .fill(MonokaiPro.green)
                    .frame(width: 2)
                    .position(x: max(1, displayProgress * width), y: height / 2)
                    .shadow(color: MonokaiPro.green.opacity(0.6), radius: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragProgress = max(0, min(1, value.location.x / width))
                        onClick(dragProgress * duration)
                    }
                    .onEnded { _ in
                        onSeek(dragProgress * duration)
                        isDragging = false
                    }
            )
        }
    }
}

// MARK: - Transport Button (Liquid Glass Style)
struct TransportButton: View {
    let icon: String
    let size: CGFloat
    let isMain: Bool
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Liquid Glass background
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isActive ? 0.35 : 0.15),
                                Color.white.opacity(isActive ? 0.15 : 0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(
                        Circle()
                            .fill(isActive ? MonokaiPro.green.opacity(0.6) : Color.clear)
                    )
                
                // Inner glow
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.1),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                
                // Outer subtle border
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    .padding(1)
                
                // Icon
                Image(systemName: icon)
                    .font(.system(size: isMain ? 26 : 18, weight: .semibold))
                    .foregroundColor(isActive ? MonokaiPro.background : MonokaiPro.foreground)
                    .shadow(color: Color.black.opacity(0.2), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: isActive ? MonokaiPro.green.opacity(0.4) : Color.black.opacity(0.3), radius: isMain ? 8 : 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Slider
struct CompactSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accentColor: Color
    
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geometry in
            let normalizedValue = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbX = normalizedValue * (geometry.size.width - 14) + 7
            
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(MonokaiPro.backgroundLight)
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                
                // Filled track
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: max(0, normalizedValue * geometry.size.width), height: 4)
                    .frame(maxHeight: .infinity)
                
                // Thumb
                Circle()
                    .fill(isDragging ? accentColor : MonokaiPro.foreground)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(x: thumbX, y: geometry.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let normalized = Float(gesture.location.x / geometry.size.width)
                        let clamped = max(0, min(1, normalized))
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - Speed Preset Button
struct SpeedPresetButton: View {
    let speed: Double
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(speed == 1.0 ? "1×" : String(format: "%.2g×", speed))
                .font(.custom("FiraCode Nerd Font", size: 12).weight(isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? MonokaiPro.background : MonokaiPro.foreground.opacity(0.7))
                .frame(width: 46, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? MonokaiPro.yellow : MonokaiPro.backgroundLight)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cheat Sheet View
struct CheatSheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                Text("Keyboard Shortcuts")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(MonokaiPro.foreground)
                    .padding(.top, 24)
                
                Divider().background(MonokaiPro.gray)
                
                // Playback
                ShortcutSection(title: "Playback", shortcuts: [
                    ("Space", "Play / Pause"),
                    ("Space × 2", "Jump to start point"),
                    ("← / →", "Seek backward / forward 10s")
                ])
                
                // Loop Controls
                ShortcutSection(title: "Loop Controls", shortcuts: [
                    ("⌘ ⇧ S", "Set loop Start point"),
                    ("⌘ ⇧ E", "Set loop End point"),
                    ("⌘ ⇧ C", "Clear all loop markers")
                ])
                
                // Window
                ShortcutSection(title: "Window & App", shortcuts: [
                    ("⌘ W", "Close window"),
                    ("⌘ Q", "Quit application"),
                    ("⌘ /", "Show this cheat sheet"),
                    ("⌘ ⇧ ?", "Show documentation")
                ])
                
                // Tips
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tips")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(MonokaiPro.yellow)
                    
                    Text("• Click on the waveform to select a position before setting loop points")
                        .font(.system(size: 12))
                        .foregroundColor(MonokaiPro.gray)
                    
                    Text("• If you set End before Start, it will reset and use your position as the new Start")
                        .font(.system(size: 12))
                        .foregroundColor(MonokaiPro.gray)
                }
                .padding(.top, 8)
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 420, height: 480)
        .background(MonokaiPro.background)
    }
}

struct ShortcutSection: View {
    let title: String
    let shortcuts: [(String, String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(MonokaiPro.green)
            
            ForEach(shortcuts, id: \.0) { shortcut in
                HStack {
                    Text(shortcut.0)
                        .font(.custom("FiraCode Nerd Font", size: 12).weight(.medium))
                        .foregroundColor(MonokaiPro.orange)
                        .frame(width: 90, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MonokaiPro.backgroundLight)
                        .cornerRadius(4)
                    
                    Text(shortcut.1)
                        .font(.system(size: 13))
                        .foregroundColor(MonokaiPro.foreground)
                    
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Documentation View
struct DocumentationView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "waveform")
                        .font(.system(size: 28))
                        .foregroundColor(MonokaiPro.green)
                    Text("EzPlayer")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(MonokaiPro.foreground)
                }
                .padding(.top, 24)
                
                Text("A lightweight audio waveform player with loop functionality")
                    .font(.system(size: 14))
                    .foregroundColor(MonokaiPro.gray)
                
                Divider().background(MonokaiPro.gray)
                
                // Getting Started
                DocSection(title: "Getting Started", icon: "play.circle", content: """
                1. Open an audio file by dragging it onto EzPlayer or using Raycast
                2. The waveform will be displayed automatically
                3. Click anywhere on the waveform to seek to that position
                4. Press Space to play/pause
                """)
                
                // Loop Feature
                DocSection(title: "Loop Playback", icon: "repeat", content: """
                EzPlayer supports A-B loop playback:

                1. Click on the waveform to select your desired start position
                2. Press ⌘⇧S to set the Start point (marked with red "S")
                3. Click on another position (after the start)
                4. Press ⌘⇧E to set the End point (marked with blue "E")
                5. The loop region will be highlighted in yellow/orange
                6. Playback will automatically loop between Start and End

                Note: If you try to set End before Start, the markers will reset and your position becomes the new Start point.
                """)
                
                // Speed Control
                DocSection(title: "Speed Control", icon: "speedometer", content: """
                Adjust playback speed using:
                • The speed slider (0.3x to 1.5x)
                • Quick preset buttons: 0.5x, 0.75x, 1x, 1.25x, 1.5x

                Speed changes take effect immediately without stopping playback.
                """)
                
                // Navigation
                DocSection(title: "Navigation", icon: "arrow.left.arrow.right", content: """
                • Click on waveform: Seek to position
                • Double-tap Space: Jump to Start point (or beginning)
                • Transport buttons: Skip ±10 seconds
                """)
                
                // File Support
                DocSection(title: "Supported Formats", icon: "doc.badge.gearshape", content: """
                EzPlayer supports common audio formats:
                • MP3, M4A, AAC
                • WAV, AIFF
                • FLAC (if system codec available)
                """)
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 500, height: 600)
        .background(MonokaiPro.background)
    }
}

struct DocSection: View {
    let title: String
    let icon: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(MonokaiPro.blue)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(MonokaiPro.yellow)
            }
            
            Text(content)
                .font(.system(size: 13))
                .foregroundColor(MonokaiPro.foreground.opacity(0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonokaiPro.backgroundLight.opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Main Content View
struct AudioPlayerView: View {
    @ObservedObject var audioManager: AudioEngineManager
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var body: some View {
        ZStack {
            // Monokai Pro background
            MonokaiPro.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Drag handle area (allows moving the window)
                Color.clear
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { _ in
                        // This area remains clickable but won't block window movement
                        // if we use a specific implementation, but for simplicity
                        // we'll rely on the fact that titlebar area is still draggable
                    })
                
                // Main content
                VStack(spacing: 12) {
                    // File info header - compact
                    HStack(spacing: 10) {
                        // App Icon
                        if let appIcon = NSApp.applicationIconImage {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                            .frame(width: 42, height: 42)
                                .cornerRadius(8)
                            .shadow(color: MonokaiPro.green.opacity(0.3), radius: 4)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(audioManager.fileName.isEmpty ? "No file loaded" : audioManager.fileName)
                                .font(.custom("FiraCode Nerd Font", size: 13).weight(.semibold))
                                .foregroundColor(MonokaiPro.foreground)
                                .lineLimit(1)
                            
                            HStack(spacing: 6) {
                                Text(formatTime(audioManager.duration))
                                Text("•")
                                Text(String(format: "%.2fx", audioManager.playbackRate))
                            }
                            .font(.custom("FiraCode Nerd Font", size: 11))
                            .foregroundColor(MonokaiPro.gray)
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    
                    // Waveform - wider with less padding
                    VStack(spacing: 6) {
                        WaveformView(
                            samples: audioManager.waveformSamples,
                            progress: audioManager.duration > 0 ? audioManager.currentTime / audioManager.duration : 0,
                            duration: audioManager.duration,
                            loopStart: audioManager.loopPointStart,
                            loopEnd: audioManager.loopPointEnd,
                            isLooping: audioManager.isLooping,
                            onSeek: { audioManager.seek(to: $0) },
                            onClick: { audioManager.setClickedTime($0) }
                        )
                        .frame(height: 220)
                        
                        // Time display with loop status
                        HStack {
                            Text(formatTime(audioManager.currentTime))
                                .foregroundColor(MonokaiPro.orange)
                            
                            Spacer()
                            
                            // Loop indicator
                            if audioManager.isLooping {
                                HStack(spacing: 4) {
                                    Image(systemName: "repeat")
                                        .font(.system(size: 9))
                                    Text("S-E")
                                }
                                .foregroundColor(MonokaiPro.yellow)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MonokaiPro.yellow.opacity(0.2))
                                .cornerRadius(4)
                            } else if audioManager.loopPointStart != nil {
                                Text("S: \(formatTime(audioManager.loopPointStart!))")
                                    .foregroundColor(MonokaiPro.red)
                            }
                            
                            Spacer()
                            
                            Text("-" + formatTime(max(0, audioManager.duration - audioManager.currentTime)))
                                .foregroundColor(MonokaiPro.gray)
                        }
                        .font(.custom("FiraCode Nerd Font", size: 10))
                    }
                    .padding(.horizontal, 12)
                    
                    // Transport controls
                    HStack(spacing: 24) {
                        TransportButton(icon: "gobackward.10", size: 48, isMain: false, isActive: false) {
                            audioManager.seek(to: max(0, audioManager.currentTime - 10))
                        }
                        
                        TransportButton(icon: audioManager.isPlaying ? "pause.fill" : "play.fill",
                                       size: 64, isMain: true, isActive: audioManager.isPlaying) {
                            audioManager.togglePlayPause()
                        }
                        
                        TransportButton(icon: "goforward.10", size: 48, isMain: false, isActive: false) {
                            audioManager.seek(to: min(audioManager.duration, audioManager.currentTime + 10))
                        }
                    }
                    .padding(.vertical, 6)
                    
                    // Controls section
                    VStack(spacing: 12) {
                        // Speed control
                        HStack(spacing: 10) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 13))
                                .foregroundColor(MonokaiPro.gray)
                                .frame(width: 18)
                            
                            CompactSlider(
                                value: Binding(
                                    get: { audioManager.playbackRate },
                                    set: { audioManager.setPlaybackRate($0) }
                                ),
                                range: 0.3...1.5,
                                accentColor: MonokaiPro.green
                            )
                            
                            Text(String(format: "%.2fx", audioManager.playbackRate))
                                .font(.custom("FiraCode Nerd Font", size: 11).weight(.semibold))
                                .foregroundColor(MonokaiPro.foreground)
                                .frame(width: 44, alignment: .trailing)
                        }
                        
                        // Volume control
                        HStack(spacing: 10) {
                            Image(systemName: audioManager.volume > 0.5 ? "speaker.wave.2.fill" :
                                  audioManager.volume > 0 ? "speaker.wave.1.fill" : "speaker.slash.fill")
                                .font(.system(size: 13))
                                .foregroundColor(MonokaiPro.gray)
                                .frame(width: 18)
                            
                            CompactSlider(
                                value: Binding(
                                    get: { audioManager.volume },
                                    set: { audioManager.setVolume($0) }
                                ),
                                range: 0...1,
                                accentColor: MonokaiPro.blue
                            )
                            
                            Text(String(format: "%.0f%%", audioManager.volume * 100))
                                .font(.custom("FiraCode Nerd Font", size: 11).weight(.semibold))
                                .foregroundColor(MonokaiPro.foreground)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Speed presets
                    HStack(spacing: 6) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5], id: \.self) { speed in
                            SpeedPresetButton(
                                speed: speed,
                                isSelected: abs(Double(audioManager.playbackRate) - speed) < 0.01
                            ) {
                                audioManager.setPlaybackRate(Float(speed))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(width: 360, height: 530)
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Custom Hosting View for Keyboard Events
class KeyboardHostingView<Content: View>: NSHostingView<Content> {
    var onSpacePressed: (() -> Void)?
    var onDoubleSpacePressed: (() -> Void)?
    var onSetLoopStart: (() -> Void)?
    var onSetLoopEnd: (() -> Void)?
    var onClearLoop: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?
    
    private var lastSpaceTime: Date?
    private let doubleSpaceInterval: TimeInterval = 0.3
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        if event.keyCode == 49 { // Space bar
            let now = Date()
            if let lastTime = lastSpaceTime, now.timeIntervalSince(lastTime) < doubleSpaceInterval {
                // Double space detected
                onDoubleSpacePressed?()
                lastSpaceTime = nil
            } else {
                lastSpaceTime = now
                onSpacePressed?()
            }
        } else if event.keyCode == 123 { // Left arrow
            onSeekBackward?()
        } else if event.keyCode == 124 { // Right arrow
            onSeekForward?()
        } else if flags == [.command, .shift] {
            // Command + Shift + S (Start)
            if event.charactersIgnoringModifiers?.lowercased() == "s" {
                onSetLoopStart?()
            }
            // Command + Shift + E (End)
            else if event.charactersIgnoringModifiers?.lowercased() == "e" {
                onSetLoopEnd?()
            }
            // Command + Shift + C (clear markers)
            else if event.charactersIgnoringModifiers?.lowercased() == "c" {
                onClearLoop?()
            } else {
                super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var audioManager: AudioEngineManager!
    var pendingFileURL: URL?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        audioManager = AudioEngineManager()
        setupWindow()
        
        let args = CommandLine.arguments
        if args.count > 1 {
            let url = URL(fileURLWithPath: args[1])
            audioManager.loadFile(url: url)
        } else if let pendingURL = pendingFileURL {
            audioManager.loadFile(url: pendingURL)
            pendingFileURL = nil
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func setupWindow() {
        let contentView = AudioPlayerView(audioManager: audioManager)
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 530),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false // 禁用背景移动以修复滑条冲突
        
        // Monokai Pro background: #2D2A2E
        window.backgroundColor = NSColor(red: 0.176, green: 0.165, blue: 0.180, alpha: 1.0)
        window.center()
        window.setFrameAutosaveName("EzPlayer")
        let hostingView = KeyboardHostingView(rootView: contentView)
        hostingView.onSpacePressed = { [weak self] in
            self?.audioManager.togglePlayPause()
        }
        hostingView.onDoubleSpacePressed = { [weak self] in
            self?.audioManager.jumpToStart()
        }
        hostingView.onSetLoopStart = { [weak self] in
            self?.audioManager.setLoopPointStart()
        }
        hostingView.onSetLoopEnd = { [weak self] in
            self?.audioManager.setLoopPointEnd()
        }
        hostingView.onClearLoop = { [weak self] in
            self?.audioManager.clearLoopMarkers()
        }
        hostingView.onSeekBackward = { [weak self] in
            guard let self = self else { return }
            self.audioManager.seek(to: max(0, self.audioManager.currentTime - 2))
        }
        hostingView.onSeekForward = { [weak self] in
            guard let self = self else { return }
            self.audioManager.seek(to: min(self.audioManager.duration, self.audioManager.currentTime + 2))
        }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostingView)
        
        setupMenu() // 添加菜单以支持快捷键
    }
    
    private func setupMenu() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        
        appMenu.addItem(withTitle: "About EzPlayer", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit EzPlayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        
        // Help Menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        
        let cheatSheetItem = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showCheatSheet), keyEquivalent: "/")
        cheatSheetItem.keyEquivalentModifierMask = [.command]
        helpMenu.addItem(cheatSheetItem)
        
        let docItem = NSMenuItem(title: "Documentation", action: #selector(showDocumentation), keyEquivalent: "?")
        docItem.keyEquivalentModifierMask = [.command, .shift]
        helpMenu.addItem(docItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    private var cheatSheetWindow: NSWindow?
    private var documentationWindow: NSWindow?
    
    @objc private func showCheatSheet() {
        if cheatSheetWindow == nil {
            let contentView = CheatSheetView()
            cheatSheetWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            cheatSheetWindow?.titlebarAppearsTransparent = true
            cheatSheetWindow?.title = "Keyboard Shortcuts"
            cheatSheetWindow?.backgroundColor = NSColor(red: 0.176, green: 0.165, blue: 0.180, alpha: 1.0)
            cheatSheetWindow?.contentView = NSHostingView(rootView: contentView)
            cheatSheetWindow?.center()
        }
        cheatSheetWindow?.makeKeyAndOrderFront(nil)
    }
    
    @objc private func showDocumentation() {
        if documentationWindow == nil {
            let contentView = DocumentationView()
            documentationWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            documentationWindow?.titlebarAppearsTransparent = true
            documentationWindow?.title = "Documentation"
            documentationWindow?.backgroundColor = NSColor(red: 0.176, green: 0.165, blue: 0.180, alpha: 1.0)
            documentationWindow?.contentView = NSHostingView(rootView: contentView)
            documentationWindow?.center()
        }
        documentationWindow?.makeKeyAndOrderFront(nil)
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            if audioManager != nil {
                audioManager.loadFile(url: url)
            } else {
                pendingFileURL = url
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        audioManager.cleanup()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
