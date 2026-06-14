import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

enum DiscoverySource { mdns, udp, manual }

class DiscoveredService {
  final String name;
  final String host;
  final int port;
  final DiscoverySource source;
  final DateTime lastSeen;

  DiscoveredService({
    required this.name,
    required this.host,
    required this.port,
    required this.source,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  String get key => '$host:$port';

  DiscoveredService refreshed() => DiscoveredService(
        name: name,
        host: host,
        port: port,
        source: source,
        lastSeen: DateTime.now(),
      );
}

/// Aggregates mDNS + UDP-beacon discovery into one deduplicated stream.
///
///  * mDNS runs through `multicast_dns`, looking up `_voiceinput._tcp.local.`.
///  * UDP listens on port 53117 for the desktop's broadcast packets, which is
///    the fallback used when the AP isolates multicast or mDNS is unsupported.
///  * `addManual` lets the UI inject a hand-entered host:port as if it were
///    discovered, so downstream code treats all entries uniformly.
class Discovery {
  static const String mdnsServiceType = '_voiceinput._tcp';
  static const int udpBeaconPort = 53117;

  final _ctrl = StreamController<List<DiscoveredService>>.broadcast();
  final Map<String, DiscoveredService> _services = {};

  MDnsClient? _mdns;
  RawDatagramSocket? _udp;
  Timer? _sweepTimer;
  bool _running = false;

  Stream<List<DiscoveredService>> get services => _ctrl.stream;
  List<DiscoveredService> get current => _services.values.toList(growable: false);

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _startUdp(); // start UDP before mDNS so we catch the next 2s tick fast
    await _startMdns();
    // Prune entries we haven't heard from in ~10s; mDNS records can otherwise
    // linger after the desktop quits.
    _sweepTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sweep());
  }

  Future<void> stop() async {
    _running = false;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _mdns?.stop();
    _mdns = null;
    _udp?.close();
    _udp = null;
  }

  void addManual(String host, int port) {
    _upsert(DiscoveredService(
      name: host,
      host: host,
      port: port,
      source: DiscoverySource.manual,
    ));
  }

  Future<void> _startMdns() async {
    try {
      final client = MDnsClient(rawDatagramSocketFactory:
          (dynamic host, int port, {bool? reuseAddress, bool? reusePort, int? ttl}) {
        // multicast_dns API quirk: pass through to default impl.
        return RawDatagramSocket.bind(
          host,
          port,
          reuseAddress: reuseAddress ?? true,
          reusePort: false, // Android disallows SO_REUSEPORT in many cases
          ttl: ttl ?? 255,
        );
      });
      await client.start();
      _mdns = client;

      // Resolve service name → SRV → IP, all asynchronously.
      unawaited(_mdnsScanLoop(client));
    } catch (_) {
      // mDNS optional; UDP fallback still applies.
    }
  }

  Future<void> _mdnsScanLoop(MDnsClient client) async {
    while (_running) {
      try {
        await for (final ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('$mdnsServiceType.local'),
        )) {
          await for (final srv in client.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName),
          )) {
            await for (final ip in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
            )) {
              final name = ptr.domainName.split('.').first;
              _upsert(DiscoveredService(
                name: name,
                host: ip.address.address,
                port: srv.port,
                source: DiscoverySource.mdns,
              ));
            }
          }
        }
      } catch (_) {
        // Swallow transient errors and re-scan after a brief pause.
      }
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  void _startUdp() {
    RawDatagramSocket.bind(InternetAddress.anyIPv4, udpBeaconPort,
            reuseAddress: true, reusePort: false)
        .then((socket) {
      socket.broadcastEnabled = true;
      _udp = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        try {
          final m = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (m['type'] != 'voiceinput.beacon') return;
          _upsert(DiscoveredService(
            name: (m['name'] as String?) ?? dg.address.address,
            host: dg.address.address,
            port: (m['port'] as num).toInt(),
            source: DiscoverySource.udp,
          ));
        } catch (_) {
          // Drop malformed packets silently.
        }
      });
    }).catchError((_) {
      // UDP optional; mDNS may still work.
    });
  }

  void _upsert(DiscoveredService s) {
    final key = s.key;
    final existing = _services[key];
    // Prefer mDNS source over UDP over manual when both arrive, since mDNS
    // reports the host's claimed name rather than just an IP.
    if (existing != null && _priority(existing.source) > _priority(s.source)) {
      _services[key] = existing.refreshed();
    } else {
      _services[key] = s;
    }
    _emit();
  }

  int _priority(DiscoverySource s) {
    switch (s) {
      case DiscoverySource.mdns:
        return 3;
      case DiscoverySource.udp:
        return 2;
      case DiscoverySource.manual:
        return 1;
    }
  }

  void _sweep() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 10));
    final removed = <String>[];
    _services.removeWhere((k, v) {
      if (v.source == DiscoverySource.manual) return false; // never expire manual
      if (v.lastSeen.isBefore(cutoff)) {
        removed.add(k);
        return true;
      }
      return false;
    });
    if (removed.isNotEmpty) _emit();
  }

  void _emit() {
    _ctrl.add(_services.values.toList(growable: false));
  }

  void dispose() {
    stop();
    _ctrl.close();
  }
}
