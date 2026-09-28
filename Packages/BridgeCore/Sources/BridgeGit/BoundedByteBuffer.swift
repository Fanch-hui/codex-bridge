import Foundation

struct BoundedByteBuffer {
  let limit: Int
  private(set) var data = Data()
  private(set) var isTruncated = false

  mutating func append(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    let remaining = limit - data.count
    guard remaining > 0 else {
      isTruncated = true
      return
    }
    data.append(chunk.prefix(remaining))
    isTruncated = isTruncated || chunk.count > remaining
  }
}
