import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Raised when the adapter cannot be reached or the link drops.
class TransportException implements Exception {
  TransportException(this.message);
  final String message;
  @override
  String toString() => 'TransportException: $message';
}

/// Byte-stream link to an ELM327 adapter.
///
/// `connect()` must be awaited before `write()`; `readStream` is a broadcast
/// stream of raw chunks. `close()` is idempotent.
abstract class Transport {
  Future<void> connect();
  Future<void> write(Uint8List data);
  Stream<Uint8List> get readStream;
  bool get isOpen;
  Future<void> close();
}

/// Wi-Fi ELM327 clones expose a raw TCP socket (commonly 192.168.0.10:35000).
class TcpTransport implements Transport {
  TcpTransport(this.host, this.port,
      {this.connectTimeout = const Duration(seconds: 5)});

  final String host;
  final int port;
  final Duration connectTimeout;

  Socket? _socket;
  final StreamController<Uint8List> _rx =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  @override
  bool get isOpen => _socket != null;

  @override
  Stream<Uint8List> get readStream => _rx.stream;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    try {
      final s = await Socket.connect(host, port, timeout: connectTimeout);
      s.setOption(SocketOption.tcpNoDelay, true);
      _socket = s;
      _sub = s.listen(
        (data) => _rx.add(Uint8List.fromList(data)),
        onError: (Object e) {
          if (!_rx.isClosed) _rx.addError(TransportException('$e'));
        },
        onDone: () {
          _socket = null;
        },
        cancelOnError: false,
      );
    } on SocketException catch (e) {
      final detail = e.message.isNotEmpty ? e.message : (e.osError?.message ?? 'timeout');
      throw TransportException('could not reach $host:$port ($detail)');
    } on TimeoutException {
      throw TransportException('timed out connecting to $host:$port');
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    final s = _socket;
    if (s == null) throw TransportException('not connected');
    try {
      s.add(data);
      await s.flush();
    } on SocketException catch (e) {
      throw TransportException('write failed: ${e.message}');
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    final s = _socket;
    _socket = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
      s.destroy();
    }
    if (!_rx.isClosed) await _rx.close();
  }
}

/// Maps a request line (after stripping the trailing CR) to the text the
/// adapter should answer with. The response text should include the '>'.
typedef MockResponder = String Function(String command);

/// Replays scripted responses. Used by tests and by `--dart-define=MOCK=true`.
class MockTransport implements Transport {
  MockTransport(this.responder,
      {this.latency = const Duration(milliseconds: 2)});

  final MockResponder responder;
  final Duration latency;
  final StreamController<Uint8List> _rx =
      StreamController<Uint8List>.broadcast();
  bool _open = false;
  String _pending = '';

  /// Every command line written by the driver, in order (for assertions).
  final List<String> sent = <String>[];

  @override
  bool get isOpen => _open;

  @override
  Stream<Uint8List> get readStream => _rx.stream;

  @override
  Future<void> connect() async {
    _open = true;
  }

  @override
  Future<void> write(Uint8List data) async {
    if (!_open) throw TransportException('not connected');
    _pending += String.fromCharCodes(data);
    while (true) {
      final i = _pending.indexOf('\r');
      if (i < 0) break;
      final line = _pending.substring(0, i);
      _pending = _pending.substring(i + 1);
      sent.add(line);
      final reply = responder(line);
      Future<void>.delayed(latency, () {
        if (_open && !_rx.isClosed) {
          _rx.add(Uint8List.fromList(reply.codeUnits));
        }
      });
    }
  }

  @override
  Future<void> close() async {
    _open = false;
    if (!_rx.isClosed) await _rx.close();
  }
}
