import Flutter
import UIKit

/// PoC #2 — How much memory does a live FlutterEngine cost inside a keyboard
/// extension, and how close is that to the limit that gets the keyboard killed?
///
/// An iOS keyboard extension has a hard jetsam budget (historically ~40–60 MB,
/// device dependent). The current Android IME hosts a whole Flutter UI; the
/// question is whether that even *fits* on iOS before adding audio buffers + a
/// WebSocket + the streaming ASR client on top.
///
/// What you see:
///   • a real FlutterViewController running `pocFlutterMain`
///   • a live phys_footprint readout (top overlay)
///   • "+10 MB" piles on page-faulted ballast until iOS kills the extension —
///     the footprint at which the keyboard vanishes IS your headroom ceiling.
///
/// Read it as: base footprint + engine delta tells you the fixed Flutter cost;
/// the kill point minus that tells you how much room is left for audio/ASR/WS.
final class KeyboardViewController: UIInputViewController {

    private var engine: FlutterEngine?
    private var flutterVC: FlutterViewController?
    private let readout = UILabel()
    private var timer: Timer?
    private var ballast: [Data] = []
    private var base: Double = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)

        let h = view.heightAnchor.constraint(equalToConstant: 300)
        h.priority = .required
        h.isActive = true

        base = MemoryProbe.footprintMB()

        // Spin up Flutter and measure the jump.
        let engine = FlutterEngine(name: "poc", project: nil)
        let started = engine.run(withEntrypoint: "pocFlutterMain")
        self.engine = engine
        let afterEngine = MemoryProbe.footprintMB()

        if started {
            let fvc = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
            addChild(fvc)
            fvc.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(fvc.view)
            NSLayoutConstraint.activate([
                fvc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                fvc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                fvc.view.topAnchor.constraint(equalTo: view.topAnchor),
                fvc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            fvc.didMove(toParent: self)
            self.flutterVC = fvc
        }

        // Controls + readout layered on top of the Flutter surface.
        readout.numberOfLines = 0
        readout.textColor = .green
        readout.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        readout.backgroundColor = UIColor(white: 0, alpha: 0.6)
        readout.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(readout)

        let addBtn = overlayButton("+10 MB", #selector(addBallast))
        let nextBtn = overlayButton("⌨︎", #selector(nextKeyboard))
        view.addSubview(addBtn)
        view.addSubview(nextBtn)

        NSLayoutConstraint.activate([
            readout.topAnchor.constraint(equalTo: view.topAnchor),
            readout.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readout.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addBtn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            addBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            addBtn.heightAnchor.constraint(equalToConstant: 40),
            addBtn.widthAnchor.constraint(equalToConstant: 104),
            nextBtn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            nextBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            nextBtn.heightAnchor.constraint(equalToConstant: 40),
            nextBtn.widthAnchor.constraint(equalToConstant: 56),
        ])

        readout.text = "PoC2 · Flutter-in-keyboard\n"
            + "base: \(fmt(base)) MB\n"
            + "after engine: \(fmt(afterEngine)) MB  (Δ \(fmt(afterEngine - base)))\n"
            + (started ? "engine: running" : "engine: FAILED to start")

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func overlayButton(_ title: String, _ sel: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.backgroundColor = UIColor(white: 0.2, alpha: 0.92)
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 6
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: sel, for: .touchUpInside)
        return b
    }

    private func fmt(_ d: Double) -> String { String(format: "%.1f", d) }

    @objc private func nextKeyboard() { advanceToNextInputMode() }

    @objc private func addBallast() {
        // 10 MB of genuinely-resident memory: Data(count:) can be lazy, so write
        // every byte to force the pages in and move phys_footprint for real.
        var d = Data(count: 10 * 1024 * 1024)
        d.resetBytes(in: 0..<d.count)
        ballast.append(d)
    }

    private func refresh() {
        let now = MemoryProbe.footprintMB()
        readout.text = "PoC2 · Flutter-in-keyboard\n"
            + "footprint: \(fmt(now)) MB\n"
            + "ballast added: \(ballast.count * 10) MB  (Δ from base \(fmt(now - base)))\n"
            + "⚠️ tap +10MB until the keyboard dies = jetsam ceiling"
    }

    deinit { timer?.invalidate() }
}
