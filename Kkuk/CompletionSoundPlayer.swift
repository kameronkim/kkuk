import AppKit

@MainActor
final class CompletionSoundPlayer: NSObject, NSSoundDelegate {
    private var sound: NSSound?
    private var completion: (() -> Void)?

    func play() {
        sound?.stop()
        sound = nil
        completion = nil
        // Each playback owns its delegate; the system's named sound can be shared.
        guard let next = NSSound(named: NSSound.Name("Glass"))?.copy() as? NSSound else { return }
        sound = next
        next.delegate = self
        if !next.play() { sound = nil }
    }

    func whenFinished(_ action: @escaping () -> Void) {
        guard sound?.isPlaying == true else { action(); return }
        completion = action
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying successfully: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sound === sound else { return }
            self.sound = nil
            let action = self.completion
            self.completion = nil
            action?()
        }
    }
}
