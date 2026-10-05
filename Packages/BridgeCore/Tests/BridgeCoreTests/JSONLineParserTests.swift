@testable import BridgeCodexRPC
import Foundation
import Testing

@Suite("JSONLineParser chunked protocol lines")
struct JSONLineParserTests {

  @Test("complete lines decode immediately")
  func parsesCompleteLine() throws {
    var parser = JSONLineParser()
    let messages = try parser.ingest(Data("{\"id\": 1}\n".utf8))
    #expect(messages.count == 1)
    #expect(messages.first?.objectValue?["id"] == .integer(1))
  }

  @Test("lines split across chunks decode once the newline arrives")
  func parsesChunkedLines() throws {
    var parser = JSONLineParser()
    let first = try parser.ingest(Data("{\"id\": ".utf8))
    #expect(first.isEmpty)
    let second = try parser.ingest(Data("7, \"ok\": true}\n".utf8))
    #expect(second.count == 1)
    #expect(second.first?.objectValue?["id"] == .integer(7))
    #expect(second.first?.objectValue?["ok"] == .bool(true))
  }

  @Test("multiple lines in one chunk decode in order")
  func parsesMultipleLines() throws {
    var parser = JSONLineParser()
    let messages = try parser.ingest(Data("{\"n\": 1}\n{\"n\": 2}\n".utf8))
    #expect(messages.map(\.objectValue?["n"]) == [.integer(1), .integer(2)])
  }

  @Test("CRLF line endings are tolerated")
  func parsesCRLF() throws {
    var parser = JSONLineParser()
    let messages = try parser.ingest(Data("{\"id\": 1}\r\n".utf8))
    #expect(messages.count == 1)
    #expect(messages.first?.objectValue?["id"] == .integer(1))
  }

  @Test("empty and whitespace-only lines are skipped")
  func skipsBlankLines() throws {
    var parser = JSONLineParser()
    let messages = try parser.ingest(Data("\n   \r\n\t\n{\"id\": 1}\n".utf8))
    #expect(messages.count == 1)
    #expect(messages.first?.objectValue?["id"] == .integer(1))
  }

  @Test("finish flushes a buffered trailing line")
  func finishFlushesBuffer() throws {
    var parser = JSONLineParser()
    _ = try parser.ingest(Data("{\"id\": 3}".utf8))
    let messages = try parser.finish()
    #expect(messages.count == 1)
    #expect(messages.first?.objectValue?["id"] == .integer(3))
  }

  @Test("finish without a buffered line produces nothing")
  func finishOnEmptyBuffer() throws {
    var parser = JSONLineParser()
    #expect(try parser.finish().isEmpty)
  }

  @Test("finish clears the buffer afterwards")
  func finishClearsBuffer() throws {
    var parser = JSONLineParser()
    _ = try parser.ingest(Data("garbage-without-newline".utf8))
    var thrown: CodexRPCError?
    do {
      _ = try parser.finish()
    } catch let error as CodexRPCError {
      thrown = error
    } catch {
      // A non-protocol error still fails the contamination assertion below.
    }
    var contamination = false
    if case .protocolContamination? = thrown { contamination = true }
    #expect(contamination)
    #expect(try parser.finish().isEmpty)
  }

  @Test("non-UTF-8 lines are rejected")
  func rejectsInvalidUTF8() {
    var parser = JSONLineParser()
    expectError(CodexRPCError.invalidUTF8) {
      _ = try parser.ingest(Data([0xFF, 0x0A]))
    }
  }

  @Test("non-protocol text is reported as contamination")
  func rejectsContamination() {
    var parser = JSONLineParser()
    expectError(CodexRPCError.protocolContamination("hello world")) {
      _ = try parser.ingest(Data("hello world\n".utf8))
    }
  }

  @Test("malformed JSON objects are reported with the preview preserved")
  func rejectsMalformedJSON() {
    var parser = JSONLineParser()
    var thrown: CodexRPCError?
    do {
      _ = try parser.ingest(Data("{invalid}\n".utf8))
    } catch let error as CodexRPCError {
      thrown = error
    } catch {
      // A non-protocol error still fails the malformed assertion below.
    }
    var malformed = false
    if case .malformedMessage? = thrown { malformed = true }
    #expect(malformed)
  }

  @Test("oversized lines are rejected and the buffer is reset")
  func rejectsOversizedLines() throws {
    var parser = JSONLineParser(maximumLineBytes: 16)
    expectError(CodexRPCError.protocolLineTooLarge(maximumBytes: 16)) {
      _ = try parser.ingest(Data((String(repeating: "a", count: 20) + "\n").utf8))
    }
    let recovered = try parser.ingest(Data("{\"id\": 1}\n".utf8))
    #expect(recovered.count == 1)
  }

  @Test("oversized buffers without a newline are rejected")
  func rejectsOversizedBuffer() {
    var parser = JSONLineParser(maximumLineBytes: 8)
    expectError(CodexRPCError.protocolLineTooLarge(maximumBytes: 8)) {
      _ = try parser.ingest(Data(String(repeating: "a", count: 12).utf8))
    }
  }

  @Test("finish accepts a buffered line after a rejected oversized ingest")
  func finishAfterReset() throws {
    var parser = JSONLineParser(maximumLineBytes: 8)
    expectError(CodexRPCError.protocolLineTooLarge(maximumBytes: 8)) {
      _ = try parser.ingest(Data(String(repeating: "a", count: 12).utf8))
    }
    _ = try parser.ingest(Data("{\"id\":4}".utf8))
    let flushed = try parser.finish()
    #expect(flushed.first?.objectValue?["id"] == .integer(4))
  }

  @Test("JSON value kinds round-trip through the wire type")
  func decodesValueKinds() throws {
    var parser = JSONLineParser()
    let messages = try parser.ingest(
      Data(
        "{\"i\": 12, \"d\": 3.5, \"s\": \"x\", \"b\": false, \"n\": null, \"a\": [1, \"two\"], \"o\": {\"deep\": true}}\n"
          .utf8))
    let object = try #require(messages.first?.objectValue)
    #expect(object["i"] == .integer(12))
    #expect(object["d"] == .number(3.5))
    #expect(object["s"] == .string("x"))
    #expect(object["b"] == .bool(false))
    #expect(object["n"] == .null)
    #expect(object["a"] == .array([.integer(1), .string("two")]))
    #expect(object["o"] == .object(["deep": .bool(true)]))
  }
}
