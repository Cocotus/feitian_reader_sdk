import Foundation

// MARK: - SDK Log Capture Utility
/// Captures stdout/stderr output from FEITIAN SDK native code (NSLog, printf, etc.)
/// and forwards it to the Swift logging system for visibility in Flutter layer
class SDKLogCapture {
    private static var logCallback: ((String) -> Void)?
    
    // Pipe für stderr/stdout Umleitung
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
        // Erstelle Pipe für stdout/stderr
        if pipe(&logPipe) == 0 {
            originalStderr = dup(STDERR_FILENO)
            originalStdout = dup(STDOUT_FILENO)
            
            // Umleitung
            dup2(logPipe[1], STDERR_FILENO)
            dup2(logPipe[1], STDOUT_FILENO)
            
            // Dispatch Source für kontinuierliches Lesen
            logDispatchSource = DispatchSource.makeReadSource(fileDescriptor: logPipe[0], queue: .global())
            logDispatchSource?.setEventHandler {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                
                let bytes = read(logPipe[0], buffer, 4096)
                if bytes > 0 {
                    let data = Data(bytes: buffer, count: bytes)
                    if let message = String(data: data, encoding: .utf8) {
                        logCallback?(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            logDispatchSource?.resume()
        }
    }
    
    /// Simulates the "start-----readerStatusThread" message that SDK produces internally
    private static func simulateReaderStatusThreadMessage() {
        // Explizites Logging der readerStatusThread Meldung
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        let timeString = formatter.string(from: timestamp)
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
