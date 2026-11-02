import Foundation
import Darwin

typealias NativeInstallFetch = @Sendable (URL) async throws -> Data

enum NativeInstallLaunchError: Error {
    case log
    case pipe
    case spawn(Int32)
}

/// Live child process. Only descriptors 0 to 2 and the event pipe (fd 3)
/// reach the child. Events are read from the pipe only; stdout and stderr go
/// to the log file.
final class NativeInstallerProcess: @unchecked Sendable {
    let pid: pid_t
    let events: AsyncStream<Data>

    private let lock = NSLock()
    private var exited = false
    private var signalled = false
    private var exitStatus: Int32?
    private var waitStarted = false
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    private init(pid: pid_t, events: AsyncStream<Data>) {
        self.pid = pid
        self.events = events
    }

    static func launch(arguments: [String], workingDirectory: URL, logURL: URL) throws -> NativeInstallerProcess {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard logFD >= 0 else { throw NativeInstallLaunchError.log }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            close(logFD)
            throw NativeInstallLaunchError.pipe
        }
        // Move both ends above 9 so neither can collide with the fds the
        // child receives (0 to 3).
        let readFD = fcntl(fds[0], F_DUPFD_CLOEXEC, 10)
        let writeFD = fcntl(fds[1], F_DUPFD_CLOEXEC, 10)
        close(fds[0])
        close(fds[1])
        guard readFD >= 0, writeFD >= 0 else {
            if readFD >= 0 { close(readFD) }
            if writeFD >= 0 { close(writeFD) }
            close(logFD)
            throw NativeInstallLaunchError.pipe
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        posix_spawn_file_actions_adddup2(&actions, writeFD, NativeInstallPin.eventsFD)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attrs, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attrs, &noSignals)
        posix_spawnattr_setflags(
            &attrs,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, arguments[0], &actions, &attrs, argv, envp)

        // The parent keeps only the read end. Close the write and log ends on
        // every path so EOF arrives when the child exits.
        close(writeFD)
        close(logFD)
        guard rc == 0 else {
            close(readFD)
            throw NativeInstallLaunchError.spawn(rc)
        }

        var streamContinuation: AsyncStream<Data>.Continuation?
        let events = AsyncStream<Data> { streamContinuation = $0 }
        guard let continuation = streamContinuation else {
            close(readFD)
            throw NativeInstallLaunchError.pipe
        }
        // A blocking read gets its own thread, not the cooperative pool.
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, 4096) }
                if count > 0 {
                    continuation.yield(Data(buffer[0..<count]))
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(readFD)
            continuation.finish()
        }
        reader.start()

        return NativeInstallerProcess(pid: pid, events: events)
    }

    /// Sends SIGTERM once. A no-op after the child has exited.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !exited, !signalled else { return }
        signalled = true
        kill(pid, SIGTERM)
    }

    /// Returns the raw wait status. Exit status never decides success.
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
                return
            }
            waiters.append(continuation)
            let startWaiter = !waitStarted
            waitStarted = true
            lock.unlock()
            guard startWaiter else { return }

            let waiter = Thread { [self] in
                var status: Int32 = 0
                var result: pid_t
                repeat {
                    result = waitpid(pid, &status, 0)
                } while result == -1 && errno == EINTR
                lock.lock()
                exited = true
                exitStatus = status
                let pending = waiters
                waiters.removeAll()
                lock.unlock()
                for pendingWaiter in pending {
                    pendingWaiter.resume(returning: status)
                }
            }
            waiter.start()
        }
    }
}

/// Downloads the pinned installer, verifies it, and runs it with an event
/// pipe on fd 3. The UI reads `state` only.
@MainActor
final class NativeInstaller: ObservableObject {
    @Published private(set) var state: NativeInstallState = .idle

    nonisolated static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Ciaobot/native-install.log")

    nonisolated static let liveFetch: NativeInstallFetch = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private let pin: NativeInstallPin
    private let fetch: NativeInstallFetch
    private let makeRunID: () -> UUID
    private let temporaryRoot: URL
    private let logURL: URL

    private var generation = 0
    private var task: Task<Void, Never>?
    private var process: NativeInstallerProcess?
    private var cancelRequested = false

    init(pin: NativeInstallPin = .current,
         fetch: @escaping NativeInstallFetch = NativeInstaller.liveFetch,
         makeRunID: @escaping () -> UUID = UUID.init,
         temporaryRoot: URL = FileManager.default.temporaryDirectory,
         logURL: URL = NativeInstaller.defaultLogURL) {
        self.pin = pin
        self.fetch = fetch
        self.makeRunID = makeRunID
        self.temporaryRoot = temporaryRoot
        self.logURL = logURL
    }

    /// No-op while a run is active.
    func start() {
        guard !state.isActive else { return }
        generation += 1
        let gen = generation
        let runID = makeRunID()
        cancelRequested = false
        state = .downloading
        task = Task { await self.run(gen, runID: runID) }
    }

    /// Before launch, the run is abandoned and the script never runs. After
    /// launch, SIGTERM is sent and the wizard origin is dropped at once.
    func cancel() {
        switch state {
        case .downloading, .verifying:
            cancelRequested = true
            task?.cancel()
            generation += 1
            state = .failed(.cancelledBeforeLaunch)
        case .running, .wizard:
            cancelRequested = true
            state = .cancelling
            process?.terminate()
        case .idle, .cancelling, .succeeded, .failed:
            return
        }
    }

    private var isTerminalState: Bool {
        switch state {
        case .succeeded, .failed: return true
        case .idle, .downloading, .verifying, .running, .wizard, .cancelling: return false
        }
    }

    private var isCancelling: Bool {
        if case .cancelling = state { return true }
        return false
    }

    private func run(_ gen: Int, runID: UUID) async {
        let data: Data
        do {
            data = try await fetch(pin.url)
        } catch {
            finish(gen, Task.isCancelled || cancelRequested ? .cancelledBeforeLaunch : .downloadFailed)
            return
        }
        // A cancel that arrived during the download bumped the generation.
        guard gen == generation else { return }

        state = .verifying
        // Nothing is written to disk and nothing runs before the digest matches.
        guard NativeInstallPin.sha256Hex(data) == pin.sha256 else {
            finish(gen, .checksumMismatch)
            return
        }

        let directory = temporaryRoot.appendingPathComponent(
            "ciaobot-native-install-\(runID.uuidString.lowercased())",
            isDirectory: true
        )
        let scriptURL = directory.appendingPathComponent("install.sh")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            finish(gen, .launchFailed)
            return
        }

        let launched: NativeInstallerProcess
        do {
            launched = try NativeInstallerProcess.launch(
                arguments: pin.arguments(scriptPath: scriptURL.path, runID: runID),
                workingDirectory: directory,
                logURL: logURL
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            finish(gen, .launchFailed)
            return
        }
        process = launched
        state = .running(nil)

        var decoder = NativeInstallEventDecoder(runID: runID.uuidString.lowercased())
        var violated = false
        for await chunk in launched.events {
            guard gen == generation else { break }
            // After a violation, keep draining so the child never blocks on a full pipe.
            if violated { continue }
            do {
                for event in try decoder.feed(chunk) {
                    apply(event, gen)
                }
            } catch {
                // The decoder throws only NativeInstallProtocolError.
                violated = true
                if !isTerminalState {
                    finish(gen, .protocolViolation(error as? NativeInstallProtocolError ?? .malformedJSON))
                }
                launched.terminate()
            }
        }

        do {
            try decoder.finish()
        } catch {
            if !isTerminalState {
                finish(gen, .protocolViolation(error as? NativeInstallProtocolError ?? .missingTerminalEvent))
            }
        }

        _ = await launched.waitForExit()
        try? FileManager.default.removeItem(at: directory)
        if process === launched {
            process = nil
        }
    }

    private func apply(_ event: NativeInstallEvent, _ gen: Int) {
        guard gen == generation, !isTerminalState else { return }
        switch event {
        case .serviceReady(let origin):
            // Still a success while cancelling: the service won the race.
            state = .succeeded(origin)
        case .failed(let code):
            state = .failed(.installer(code))
        case .wizardReady(let origin):
            guard !isCancelling else { return }
            state = .wizard(origin)
        case .phase(let phase):
            guard !isCancelling else { return }
            state = .running(phase)
        case .setupSaved:
            guard !isCancelling else { return }
            // Trust in the wizard origin ends once setup is saved.
            state = .running(.wizard)
        }
    }

    private func finish(_ gen: Int, _ failure: NativeInstallFailure) {
        guard gen == generation, !isTerminalState else { return }
        state = .failed(failure)
    }
}
