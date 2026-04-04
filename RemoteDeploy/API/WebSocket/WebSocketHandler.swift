// Handles WebSocket connections for live build log streaming and status updates.
// Clients connect to /api/v1/ws and subscribe to channels: "buildlog", "buildstatus", "install".
// Messages are JSON-encoded WSMessage structs from RemoteDeployShared.
import Foundation
import NIO
import NIOWebSocket
import RemoteDeployShared

/// Manages active WebSocket connections and broadcasts events to subscribers.
final class WebSocketManager: @unchecked Sendable {

    /// A connected WebSocket client with its subscribed channels.
    private struct Client {
        let channel: Channel
        var subscriptions: Set<String>
    }

    /// Lock protecting the clients dictionary.
    private let lock = NSLock()

    /// Active clients keyed by a unique connection ID.
    private var clients: [ObjectIdentifier: Client] = [:]

    /// Registers a new WebSocket connection.
    ///
    /// - Parameter channel: The NIO channel for this WebSocket connection.
    func addClient(_ channel: Channel) {
        let key = ObjectIdentifier(channel)
        lock.lock()
        clients[key] = Client(channel: channel, subscriptions: [])
        lock.unlock()
    }

    /// Removes a WebSocket connection when it closes.
    ///
    /// - Parameter channel: The NIO channel that disconnected.
    func removeClient(_ channel: Channel) {
        let key = ObjectIdentifier(channel)
        lock.lock()
        clients.removeValue(forKey: key)
        lock.unlock()
    }

    /// Subscribes a client to a channel (e.g., "buildlog", "buildstatus").
    ///
    /// - Parameter channel: The NIO channel to subscribe.
    /// - Parameter subscription: The channel name to subscribe to.
    func subscribe(_ channel: Channel, to subscription: String) {
        let key = ObjectIdentifier(channel)
        lock.lock()
        clients[key]?.subscriptions.insert(subscription)
        lock.unlock()
    }

    /// Broadcasts a message to all clients subscribed to the given channel.
    ///
    /// - Parameter type: The message type (matches subscription channel name).
    /// - Parameter payload: The message payload string.
    func broadcast(type: String, payload: String) {
        let message = WSMessage(type: type, payload: payload)
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        let subscribers = clients.values.filter { $0.subscriptions.contains(type) }
        lock.unlock()

        for client in subscribers {
            var buffer = client.channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            client.channel.writeAndFlush(frame, promise: nil)
        }
    }

    /// Returns the number of active connections.
    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }
}

/// NIO channel handler for individual WebSocket connections.
/// Receives subscribe/unsubscribe commands and handles ping/pong.
final class WebSocketChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let manager: WebSocketManager

    init(manager: WebSocketManager) {
        self.manager = manager
    }

    func channelActive(context: ChannelHandlerContext) {
        manager.addClient(context.channel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        manager.removeClient(context.channel)
    }

    /// Processes incoming WebSocket frames.
    ///
    /// Text frames are parsed as JSON WSMessage commands (subscribe/unsubscribe).
    /// Ping frames get a pong reply. Close frames close the connection.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            var frameData = frame.data
            guard let text = frameData.readString(length: frameData.readableBytes),
                  let msgData = text.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(WSMessage.self, from: msgData) else {
                return
            }

            if msg.type == "subscribe" {
                manager.subscribe(context.channel, to: msg.payload)
            }

        case .ping:
            var pongData = context.channel.allocator.buffer(capacity: frame.data.readableBytes)
            pongData.writeImmutableBuffer(frame.data)
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .connectionClose:
            context.close(promise: nil)

        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
