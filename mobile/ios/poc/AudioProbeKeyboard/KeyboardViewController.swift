import AVFoundation
import UIKit

/// PoC #1 — Can a custom keyboard extension actually capture microphone audio?
///
/// Pure native, no Flutter. This is the make-or-break question for putting the
/// VoiceInput IME on iOS: the whole product feeds the mic into a streaming ASR.
/// iOS only *maybe* lets a keyboard extension record, and even with Full Access
/// it commonly hands back a SILENT stream instead of failing outright.
///
/// How to read the verdict (tap "Record 3s", speak):
///   ✅ SUCCESS  — frames flowed and peak is a real level  → iOS keyboard IME is viable
///   ⚠️ SILENT   — frames flowed but peak ≈ 0              → iOS muted us; product can't work as a keyboard
///   ❌ FAIL      — session/engine refused to start         → recording blocked outright
final class KeyboardViewController: UIInputViewController {

    private let status = UILabel()
    private var engine: AVAudioEngine?
    private var capturedFrames = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.07, alpha: 1)

        // Extensions collapse to ~0 height without an explicit constraint.
        let h = view.heightAnchor.constraint(equalToConstant: 290)
        h.priority = .required
        h.isActive = true

        status.numberOfLines = 0
        status.textColor = .white
        status.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        status.text = "PoC1 · mic in keyboard extension\n"
            + "Full Access: \(hasFullAccess ? "YES" : "NO — enable it in Settings")\n"
            + "Tap “Record 3s” and speak."

        let stack = UIStackView(arrangedSubviews: [
            status,
            makeButton("Check access / mic", #selector(checkAccess)),
            makeButton("● Record 3s", #selector(record)),
            makeButton("⌨︎ Next keyboard", #selector(nextKeyboard)),
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])
    }

    private func makeButton(_ title: String, _ sel: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = UIColor(white: 0.18, alpha: 1)
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 8
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        b.addTarget(self, action: sel, for: .touchUpInside)
        return b
    }

    @objc private func nextKeyboard() { advanceToNextInputMode() }

    @objc private func checkAccess() {
        let mic: String
        if #available(iOS 17.0, *) {
            mic = "\(AVAudioApplication.shared.recordPermission)"
        } else {
            mic = "\(AVAudioSession.sharedInstance().recordPermission)"
        }
        status.text = "Full Access: \(hasFullAccess ? "YES" : "NO")\n"
            + "Mic permission: \(mic)\n"
            + "(grant mic by opening the host app once)"
    }

    @objc private func record() {
        guard hasFullAccess else {
            status.text = "❌ Full Access is OFF.\n"
                + "Settings ▸ General ▸ Keyboard ▸ Keyboards ▸\nAudioProbe ▸ Allow Full Access"
            return
        }
        capturedFrames = 0; peak = 0; sumSquares = 0; sampleCount = 0

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            status.text = "❌ AVAudioSession activate FAILED:\n\(error.localizedDescription)\n"
                + "→ extensions are frequently denied here."
            return
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            status.text = "❌ input format invalid (sampleRate=0).\n"
                + "The extension was given NO real input route."
            try? session.setActive(false)
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            let p = ch[0]
            var localPeak = self.peak
            for i in 0..<n {
                let v = abs(p[i])
                if v > localPeak { localPeak = v }
                self.sumSquares += Double(p[i] * p[i])
            }
            self.peak = localPeak
            self.capturedFrames += n
            self.sampleCount += n
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            status.text = "❌ engine.start FAILED:\n\(error.localizedDescription)"
            input.removeTap(onBus: 0)
            try? session.setActive(false)
            return
        }

        status.text = "🎙 recording 3s… speak now (sampleRate=\(Int(format.sampleRate)))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.finish(sampleRate: format.sampleRate)
        }
    }

    private func finish(sampleRate: Double) {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        let seconds = Double(capturedFrames) / max(sampleRate, 1)
        let verdict: String
        if capturedFrames == 0 {
            verdict = "❌ FAIL: no audio frames delivered."
        } else if peak < 1e-4 {
            verdict = "⚠️ SILENT: frames flowed but peak≈0.\niOS handed back a muted stream."
        } else {
            verdict = "✅ SUCCESS: real audio captured."
        }
        status.text = """
        \(verdict)
        frames: \(capturedFrames)  (~\(String(format: "%.1f", seconds))s)
        peak: \(String(format: "%.4f", peak))   rms: \(String(format: "%.4f", rms))
        """
    }
}
