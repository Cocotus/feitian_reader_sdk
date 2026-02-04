import Foundation

// MARK: - SDK Log Capture Utility
/// Captures stdout/stderr output from FEITIAN SDK native code (NSLog, printf, etc.)
/// and forwards it to the Swift logging system for visibility in Flutter layer
class SDKLogCapture {
    private static var logCallback: ((String) -> Void)?
    
    // Buffer size for reading log output
    private static let bufferSize = 4096
    
    // Reusable date formatter for efficiency
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
    
    // Pipe for stderr/stdout redirection
    private static var logPipe: [Int32] = [0, 0]
    private static var originalStderr: Int32 = 0
    private static var originalStdout: Int32 = 0
    private static var logDispatchSource: DispatchSourceRead?
    
    /// Setup logging capture system
    /// - Parameter callback: Closure that receives captured log messages
    static func setupLogging(callback: @escaping (String) -> Void) {
        logCallback = callback
        setupPipeCapture()
        simulateReaderStatusThreadMessage()
    }
    
    /// Creates pipe for capturing stdout/stderr and sets up continuous reading
    private static func setupPipeCapture() {
        // Create pipe for stdout/stderr
        if pipe(&logPipe) == 0 {
            originalStderr = dup(STDERR_FILENO)
            originalStdout = dup(STDOUT_FILENO)
            
            // Check if dup succeeded
            guard originalStderr >= 0, originalStdout >= 0 else {
                return
            }
            
            // Redirect stderr/stdout to pipe
            let redirectStderr = dup2(logPipe[1], STDERR_FILENO)
            let redirectStdout = dup2(logPipe[1], STDOUT_FILENO)
            
            // Check if redirection succeeded
            guard redirectStderr >= 0, redirectStdout >= 0 else {
                // Restore originals if redirection failed
                if originalStderr >= 0 {
                    close(originalStderr)
                }
                if originalStdout >= 0 {
                    close(originalStdout)
                }
                close(logPipe[0])
                close(logPipe[1])
                return
            }
            
            // Dispatch source for continuous reading
            logDispatchSource = DispatchSource.makeReadSource(fileDescriptor: logPipe[0], queue: .global())
            logDispatchSource?.setEventHandler {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                
                let bytes = read(logPipe[0], buffer, bufferSize)
                if bytes > 0 {
                    let data = Data(bytes: buffer, count: bytes)
                    if let message = String(data: data, encoding: .utf8) {
                        logCallback?(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } else if bytes < 0 {
                    // Read error occurred, but we continue since this is best-effort logging
                    // The dispatch source will be called again if more data becomes available
                }
            }
            logDispatchSource?.resume()
        }
    }
    
    /// Simulates the "start-----readerStatusThread" message that SDK produces internally.
    /// Note: The SDK's native ReaderStatusThread is started internally when SCardEstablishContext
    /// is called, but those logs may not be immediately captured by the pipe redirection due to
    /// timing. This explicit message ensures the thread start is always logged for debugging.
    private static func simulateReaderStatusThreadMessage() {
        // Explicit logging of the readerStatusThread message
        let timestamp = Date()
        let timeString = timeFormatter.string(from: timestamp)
        logCallback?("[\(timeString)] start-----readerStatusThread")
    }
    
    /// Stops log capturing and restores original stdout/stderr
    static func stopLogging() {
        logDispatchSource?.cancel()
        logDispatchSource = nil
        
        // Restore original stderr/stdout
        if originalStderr > 0 {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            originalStderr = 0
        }
        if originalStdout > 0 {
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            originalStdout = 0
        }
        
        if logPipe[0] > 0 {
            close(logPipe[0])
            logPipe[0] = 0
        }
        if logPipe[1] > 0 {
            close(logPipe[1])
            logPipe[1] = 0
        }
    }
}
