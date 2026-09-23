import Foundation

/// Normalizes the Codex executable path a user typed or pasted.
///
/// The Windows shell's "copy as path" command produces a quoted value, and both
/// platforms can deliver trailing whitespace or a line break from a clipboard
/// round trip. Only those artifacts are removed; a path that stays unusable is
/// reported to the user unchanged so the rejection stays diagnosable.
public enum CodexExecutablePathInput {
  public static func normalized(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.count >= 2, let first = value.first, let last = value.last,
      first == last, first == "\"" || first == "'"
    {
      value = String(value.dropFirst().dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value
  }
}
