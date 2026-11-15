#if canImport(CoreNFC)
    import CoreNFC
    import Foundation

    /// Reads a Sibionics applicator tag and dumps everything on it. Diagnostic
    /// tooling, not part of the pairing path.
    ///
    /// **Why a tag session and not an NDEF session.** The official app uses
    /// `NFCNDEFReaderSession`, which needs the `NDEF` value in
    /// `com.apple.developer.nfc.readersession.formats`. Trio's entitlements
    /// already carry `TAG` (Libre's `NFCTagReaderSession`), and `TAG` lets a tag
    /// session read the same NDEF payloads, so this needs no build-config
    /// change. If `NDEF` is ever added to the entitlements this could be
    /// simplified to an NDEF session.
    ///
    /// The tag itself is plain NDEF — that is what the official app's use of an
    /// NDEF session tells us — so the payload contents are not protected; only
    /// the format is unknown, which is exactly what the dump reveals.
    public final class SibionicsNFCReader: NSObject, @unchecked Sendable {
        public enum ReaderError: Error, CustomStringConvertible {
            case unavailable
            case cancelled
            case noTag
            case connectFailed(String)
            case unsupportedTag(String)
            case ndefUnreadable(String)
            case timedOut

            public var description: String {
                switch self {
                case .unavailable:
                    return "NFC reading is not available on this device."
                case .cancelled:
                    return "NFC scan was cancelled."
                case .noTag:
                    return "No tag was presented."
                case let .connectFailed(detail):
                    return "Could not connect to the tag: \(detail)"
                case let .unsupportedTag(kind):
                    return "This tag (\(kind)) can't be read here."
                case let .ndefUnreadable(detail):
                    return "The tag was read but its NDEF data was not: \(detail)"
                case .timedOut:
                    return "NFC scan timed out."
                }
            }
        }

        /// `NFCTagReaderSession.readingAvailable` — false in the simulator and on
        /// hardware without NFC.
        public static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

        private let lock = NSLock()
        private var session: NFCTagReaderSession?
        private var continuation: CheckedContinuation<SibionicsNFCDump, Error>?
        private var finished = false
        private var timeoutTask: Task<Void, Never>?
        /// `NFCTagReaderSession.delegate` is weak, so the reader has to keep
        /// itself alive for the duration of the sheet or a caller that does not
        /// hold on to it would be released mid-scan.
        private var selfRetain: SibionicsNFCReader?

        override public init() { super.init() }

        /// Presents the system NFC sheet and resolves with whatever the tag
        /// contained. Cancelling the surrounding task invalidates the session.
        public func read(
            message: String = "Hold the top of your iPhone near the sensor's tag.",
            timeout: TimeInterval = 90
        ) async throws -> SibionicsNFCDump {
            guard Self.isAvailable else { throw ReaderError.unavailable }

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SibionicsNFCDump, Error>) in
                    // `readingAvailable` was checked, but the initialiser is
                    // still imported as failable, so treat nil as unavailable.
                    // `.iso18092` (FeliCa) is deliberately not polled: it needs
                    // its own entitlement and no NB sensor uses it.
                    guard let session = NFCTagReaderSession(
                        pollingOption: [.iso14443, .iso15693],
                        delegate: self,
                        queue: nil
                    ) else {
                        continuation.resume(throwing: ReaderError.unavailable)
                        return
                    }
                    session.alertMessage = message
                    lock.lock()
                    self.continuation = continuation
                    self.session = session
                    self.selfRetain = self
                    lock.unlock()
                    session.begin()

                    let task = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(ReaderError.timedOut))
                    }
                    lock.lock()
                    timeoutTask = task
                    lock.unlock()
                }
            } onCancel: { [weak self] in
                self?.finish(.failure(ReaderError.cancelled))
            }
        }

        // MARK: - Completion

        private func finish(_ result: Result<SibionicsNFCDump, Error>) {
            var selfKeepAlive: SibionicsNFCReader?
            let (continuation, session, timeout): (
                CheckedContinuation<SibionicsNFCDump, Error>?,
                NFCTagReaderSession?,
                Task<Void, Never>?
            ) =
                lock.withLock {
                    guard !finished else { return (nil, nil, nil) }
                    finished = true
                    let values = (self.continuation, self.session, timeoutTask)
                    self.continuation = nil
                    self.session = nil
                    timeoutTask = nil
                    selfKeepAlive = self.selfRetain
                    // Dropped below, once nothing here can touch `self` any more.
                    self.selfRetain = nil
                    return values
                }
            defer { _ = selfKeepAlive }
            guard let continuation else { return }
            timeout?.cancel()
            if case let .failure(error) = result {
                session?.invalidate(errorMessage: errorText(error))
            } else {
                session?.alertMessage = "Tag read."
                session?.invalidate()
            }
            continuation.resume(with: result)
        }

        private func errorText(_ error: Error) -> String {
            if error is ReaderError { return String(describing: error) }
            return error.localizedDescription
        }
    }

    extension SibionicsNFCReader: NFCTagReaderSessionDelegate {
        public func tagReaderSessionDidBecomeActive(_: NFCTagReaderSession) {}

        public func tagReaderSession(_: NFCTagReaderSession, didInvalidateWithError error: Error) {
            let readerError = error as? NFCReaderError
            // The user dismissing the sheet is a cancellation, not a failure to
            // report as a bug.
            if readerError?.code == .readerSessionInvalidationErrorUserCanceled {
                finish(.failure(ReaderError.cancelled))
            } else {
                finish(.failure(error))
            }
        }

        public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
            guard let tag = tags.first else {
                finish(.failure(ReaderError.noTag))
                return
            }
            guard tags.count == 1 else {
                session.alertMessage = "More than one tag. Present only the sensor's tag."
                // Leave the session running; the user can retry without a rebuild.
                return
            }

            let resolved: ResolvedTag
            switch tag {
            case let .miFare(value): resolved = .miFare(value)
            case let .iso15693(value): resolved = .iso15693(value)
            case let .iso7816(value): resolved = .iso7816(value)
            case let .feliCa(value): resolved = .feliCa(value)
            @unknown default:
                finish(.failure(ReaderError.unsupportedTag("unknown tag type")))
                return
            }

            session.connect(to: tag) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(ReaderError.connectFailed(error.localizedDescription)))
                    return
                }
                resolved.ndefTag.queryNDEFStatus { status, capacity, statusError in
                    if let statusError {
                        self.finish(.failure(ReaderError.ndefUnreadable(statusError.localizedDescription)))
                        return
                    }
                    let statusText = ResolvedTag.describe(status)
                    guard status != .notSupported else {
                        // Still worth dumping: the UID and tag type are useful
                        // even when there is no NDEF container.
                        self.finish(.success(resolved.dump(status: statusText, capacity: nil, payloads: [])))
                        return
                    }
                    resolved.ndefTag.readNDEF { message, readError in
                        if let readError {
                            self.finish(.failure(ReaderError.ndefUnreadable(readError.localizedDescription)))
                            return
                        }
                        let payloads = (message?.records ?? []).map(Self.payload(from:))
                        self.finish(.success(
                            resolved.dump(status: statusText, capacity: Int(capacity), payloads: payloads)
                        ))
                    }
                }
            }
        }

        private static func payload(from record: NFCNDEFPayload) -> SibionicsNFCDump.Payload {
            SibionicsNFCDump.Payload(
                typeNameFormat: description(of: record.typeNameFormat),
                typeDescription: String(data: record.type, encoding: .utf8)
                    ?? record.type.map { String(format: "%02x", $0) }.joined(),
                identifier: record.identifier,
                payload: record.payload
            )
        }

        private static func description(of format: NFCTypeNameFormat) -> String {
            switch format {
            case .empty: return "empty"
            case .nfcWellKnown: return "well-known"
            case .media: return "media"
            case .absoluteURI: return "absolute-uri"
            case .nfcExternal: return "external"
            case .unknown: return "unknown"
            case .unchanged: return "unchanged"
            @unknown default: return "other"
            }
        }
    }

    // MARK: - Tag type erasure

    /// The four tag flavours, behind one interface. Each concrete protocol has
    /// its own `connect`/`disconnect`/`identifier`, and the NDEF operations are
    /// common.
    private enum ResolvedTag {
        case miFare(NFCMiFareTag)
        case iso15693(NFCISO15693Tag)
        case iso7816(NFCISO7816Tag)
        case feliCa(NFCFeliCaTag)

        var ndefTag: NFCNDEFTag {
            switch self {
            case let .miFare(tag): return tag
            case let .iso15693(tag): return tag
            case let .iso7816(tag): return tag
            case let .feliCa(tag): return tag
            }
        }

        var identifier: Data {
            switch self {
            case let .miFare(tag): return tag.identifier
            case let .iso15693(tag): return tag.identifier
            case let .iso7816(tag): return tag.identifier
            case let .feliCa(tag): return tag.currentIDm
            }
        }

        var label: String {
            switch self {
            case let .miFare(tag):
                let family: String
                switch tag.mifareFamily {
                case .ultralight: family = "Ultralight"
                case .plus: family = "Plus"
                case .desfire: family = "DESFire"
                case .unknown: family = "unknown family"
                @unknown default: family = "unknown family"
                }
                return "MIFARE \(family) (ISO14443)"
            case .iso15693:
                return "ISO15693"
            case .iso7816:
                return "ISO7816 / ISO-DEP"
            case .feliCa:
                return "FeliCa"
            }
        }

        func dump(status: String, capacity: Int?, payloads: [SibionicsNFCDump.Payload]) -> SibionicsNFCDump {
            SibionicsNFCDump(
                tagType: label,
                identifier: identifier,
                ndefStatus: status,
                capacity: capacity,
                payloads: payloads
            )
        }

        static func describe(_ status: NFCNDEFStatus) -> String {
            switch status {
            case .notSupported: return "not NDEF"
            case .readOnly: return "read-only"
            case .readWrite: return "read/write"
            @unknown default: return "unknown"
            }
        }
    }
#endif
