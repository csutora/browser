import Foundation

/// Performs background DNS resolution for single-word inputs.
/// This enables navigation to intranet hosts, MagicDNS names (Tailscale), and other local network resources.
class DNSResolver {

    /// Resolves a hostname in the background and calls the completion handler with the result.
    /// - Parameters:
    ///   - hostname: The hostname to resolve (e.g., "myserver", "foo")
    ///   - timeout: Maximum time to wait for resolution (default 2 seconds)
    ///   - completion: Called on main thread with (resolved: Bool, hostname: String?)
    static func resolveInBackground(
        _ hostname: String,
        timeout: TimeInterval = 2.0,
        completion: @escaping (Bool, String?) -> Void
    ) {
        // Track whether completion was already called (prevents double-callback race)
        final class State { var didComplete = false }
        let state = State()

        let workItem = DispatchWorkItem {
            let resolved = performDNSLookup(hostname)
            DispatchQueue.main.async {
                guard !state.didComplete else { return }
                state.didComplete = true
                completion(resolved, resolved ? hostname : nil)
            }
        }

        // Run on a background queue
        DispatchQueue.global(qos: .utility).async(execute: workItem)

        // Set up timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            workItem.cancel()
            DispatchQueue.main.async {
                guard !state.didComplete else { return }
                state.didComplete = true
                completion(false, nil)
            }
        }
    }

    /// Performs a synchronous DNS lookup using CFHost.
    /// Returns true if the hostname resolves to at least one IP address.
    private static func performDNSLookup(_ hostname: String) -> Bool {
        let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()

        // Start resolution
        var error = CFStreamError()
        let started = CFHostStartInfoResolution(host, .addresses, &error)

        guard started else {
            return false
        }

        // Get results
        var resolved = DarwinBoolean(false)
        guard let addressesData = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data] else {
            return false
        }

        // Check if we got any valid addresses
        return resolved.boolValue && !addressesData.isEmpty
    }

    /// Async/await version of DNS resolution
    @available(macOS 10.15, *)
    static func resolve(_ hostname: String, timeout: TimeInterval = 2.0) async -> Bool {
        await withCheckedContinuation { continuation in
            resolveInBackground(hostname, timeout: timeout) { resolved, _ in
                continuation.resume(returning: resolved)
            }
        }
    }
}
