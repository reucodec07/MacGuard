import Foundation

extension String {
    /// Escapes a string for safe use in single-quoted bash command arguments.
    /// It replaces every single quote `'` with `'\''`.
    var esc: String { 
        replacingOccurrences(of: "'", with: "'\\''") 
    }
}
