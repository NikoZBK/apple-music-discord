import Foundation
import AppleMusicDiscordCore

enum DiscordRPCError: Error, CustomStringConvertible {
  case invalidClientID
  case unavailable
  case socket(String)
  case timedOut
  case protocolError(String)

  var description: String {
    switch self {
    case .invalidClientID: "APPLE_MUSIC_DISCORD_CLIENT_ID is missing or empty"
    case .unavailable: "Discord Desktop RPC is not available"
    case .socket(let message): "Discord RPC socket error: \(message)"
    case .timedOut: "Discord RPC response timed out"
    case .protocolError(let message): "Discord RPC protocol error: \(message)"
    }
  }
}

/// The local Discord IPC transport. It owns only the application activity it
/// publishes; it never uses a Discord user token or a gateway connection.
final class DiscordIPCClient {
  private let clientID: String
  private var socket: Int32 = -1

  init(clientID: String) throws {
    guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DiscordRPCError.invalidClientID
    }
    self.clientID = clientID
  }

  deinit { disconnect() }

  func disconnect() {
    if socket >= 0 {
      Darwin.close(socket)
      socket = -1
    }
  }

  func setActivity(_ activity: DiscordPresenceActivity?, pid: Int32) throws {
    try connectIfNeeded()
    let command = DiscordSetActivityCommand(
      nonce: UUID().uuidString, pid: pid, activity: activity
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      try sendFrame(opcode: 1, payload: encoder.encode(command))
      let response = try readFrame()
      try validateResponse(response)
    } catch {
      disconnect()
      throw error
    }
  }

  private func connectIfNeeded() throws {
    guard socket < 0 else { return }
    let handshake = try JSONSerialization.data(withJSONObject: [
      "v": 1,
      "client_id": clientID,
    ], options: [.sortedKeys])

    var lastError: Error?
    for directory in Self.socketDirectories() {
      for index in 0..<10 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
          lastError = DiscordRPCError.socket(Self.systemError())
          continue
        }
        do {
          try Self.connect(descriptor, path: "\(directory)/discord-ipc-\(index)")
          socket = descriptor
          try sendFrame(opcode: 0, payload: handshake)
          let ready = try readFrame()
          guard ready.opcode == 1 else {
            throw DiscordRPCError.protocolError("Discord did not send READY")
          }
          return
        } catch {
          Darwin.close(descriptor)
          socket = -1
          lastError = error
        }
      }
    }
    if let lastError { throw lastError }
    throw DiscordRPCError.unavailable
  }

  private static func connect(_ descriptor: Int32, path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else {
      throw DiscordRPCError.socket("IPC path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      for (index, byte) in bytes.enumerated() { raw[index] = byte }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw DiscordRPCError.socket(Self.systemError()) }
  }

  private static func socketDirectories() -> [String] {
    let environment = ProcessInfo.processInfo.environment
    var directories: [String] = []
    for value in [
      environment["XDG_RUNTIME_DIR"],
      environment["TMPDIR"],
      environment["TMP"],
      environment["TEMP"],
      FileManager.default.temporaryDirectory.path,
      "/tmp",
    ].compactMap({ $0 }) {
      let directory = value.hasSuffix("/") ? String(value.dropLast()) : value
      if !directory.isEmpty, !directories.contains(directory) {
        directories.append(directory)
      }
    }
    return directories
  }

  private func sendFrame(opcode: Int32, payload: Data) throws {
    guard socket >= 0 else { throw DiscordRPCError.unavailable }
    var frame = Data()
    var littleOpcode = opcode.littleEndian
    var littleLength = Int32(payload.count).littleEndian
    withUnsafeBytes(of: &littleOpcode) { frame.append(contentsOf: $0) }
    withUnsafeBytes(of: &littleLength) { frame.append(contentsOf: $0) }
    frame.append(payload)

    try frame.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(socket, baseAddress.advanced(by: offset), buffer.count - offset)
        guard written > 0 else { throw DiscordRPCError.socket(Self.systemError()) }
        offset += written
      }
    }
  }

  private func readFrame() throws -> (opcode: Int32, payload: Data) {
    let header = try readExactly(8)
    let opcode = Self.int32(from: header, at: 0)
    let length = Self.int32(from: header, at: 4)
    guard length >= 0, length <= 1_048_576 else {
      throw DiscordRPCError.protocolError("invalid frame length \(length)")
    }
    return (opcode, Data(try readExactly(Int(length))))
  }

  private func readExactly(_ count: Int) throws -> [UInt8] {
    guard count >= 0 else { throw DiscordRPCError.protocolError("negative read length") }
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, 1_000)
      if ready == 0 { throw DiscordRPCError.timedOut }
      if ready < 0 {
        if errno == EINTR { continue }
        throw DiscordRPCError.socket(Self.systemError())
      }
      let readCount = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(socket, buffer.baseAddress!.advanced(by: offset), count - offset)
      }
      if readCount == 0 { throw DiscordRPCError.unavailable }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw DiscordRPCError.socket(Self.systemError())
      }
      offset += readCount
    }
    return bytes
  }

  private func validateResponse(_ response: (opcode: Int32, payload: Data)) throws {
    guard response.opcode == 1 else {
      throw DiscordRPCError.protocolError("unexpected response opcode \(response.opcode)")
    }
    guard let object = try JSONSerialization.jsonObject(with: response.payload) as? [String: Any] else {
      throw DiscordRPCError.protocolError("response was not JSON")
    }
    if let event = object["evt"] as? String, event == "ERROR" {
      let data = object["data"] as? [String: Any]
      throw DiscordRPCError.protocolError(data?["message"] as? String ?? "Discord rejected activity")
    }
  }

  private static func int32(from bytes: [UInt8], at offset: Int) -> Int32 {
    let value = UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
    return Int32(bitPattern: value)
  }

  private static func systemError() -> String {
    String(cString: strerror(errno))
  }
}

/// Reconnects lazily so Discord being closed never stops Apple Music
/// observation. The publisher has no server or account transport dependency.
final class DiscordRichPresencePublisher {
  private let clientID: String
  private let largeImage: String?
  private let pid: Int32
  private var client: DiscordIPCClient?
  private(set) var active = false

  init(clientID: String, largeImage: String? = nil, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
    guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DiscordRPCError.invalidClientID
    }
    self.clientID = clientID
    self.largeImage = largeImage
    self.pid = pid
  }

  func publish(snapshot: AppleMusicSnapshot) throws {
    let activity = snapshot.state == .playing
      ? DiscordPresenceActivity(snapshot: snapshot, largeImage: largeImage)
      : nil
    try send(activity)
    active = activity != nil
  }

  func clear() throws {
    guard active else { return }
    try send(nil)
    active = false
  }

  func disconnect() {
    client?.disconnect()
    client = nil
  }

  private func send(_ activity: DiscordPresenceActivity?) throws {
    if client == nil { client = try DiscordIPCClient(clientID: clientID) }
    do {
      try client?.setActivity(activity, pid: pid)
    } catch {
      disconnect()
      throw error
    }
  }
}
