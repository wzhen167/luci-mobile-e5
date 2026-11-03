import 'package:dio/dio.dart';

import 'package:luci_mobile/models/openclash.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/state/router_session.dart';
import 'package:luci_mobile/utils/uci_values.dart';

/// The calls the app makes against a Clash core's external controller.
///
/// A tiny interface rather than a concrete Dio client: reviewer mode has no
/// router to talk to, and tests want a stub without a socket. Everything the
/// screen does — status, node switching, mode switching — goes through here,
/// so a different core that spells a route differently (or a test double that
/// needs to fail one call) is one implementation away.
abstract class ClashApi {
  Future<Map<String, dynamic>> get(String path);

  /// `PUT` or `PATCH`, with a JSON body.
  Future<void> send(String method, String path, Map<String, dynamic> body);
}

/// Builds one client for the address and credentials of the active router.
typedef ClashApiFactory =
    ClashApi Function({
      required String host,
      required int port,
      String? secret,
    });

/// Anything that stopped a request from producing JSON.
class ClashApiException implements Exception {
  const ClashApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The dashboard rejected the password.
///
/// Separate from the rest because the fix is different: every other failure is
/// "the core is not reachable or not answering", this one is "the password in
/// the UCI config is not the one the YAML was generated with".
class ClashAuthException extends ClashApiException {
  const ClashAuthException() : super('unauthorized');
}

/// The controller answered nothing at all.
class ClashUnreachableException extends ClashApiException {
  const ClashUnreachableException(super.message);
}

/// Talks to the external controller over `http://host:port`.
///
/// Plain HTTP on the LAN, deliberately: OpenClash's controller has no TLS, and
/// the router is reached through the same network. The password is the UCI
/// `dashboard_password`, which OpenClash writes into the generated YAML as the
/// API `secret`.
class HttpClashApi implements ClashApi {
  HttpClashApi({
    required String host,
    required int port,
    String? secret,
    Dio? dio,
    Duration timeout = const Duration(seconds: 6),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: 'http://$host:$port',
               connectTimeout: timeout,
               receiveTimeout: timeout,
               sendTimeout: timeout,
               responseType: ResponseType.json,
               // 401 is answered, not thrown: it is the one status the screen
               // needs to explain rather than report as "unreachable".
               validateStatus: (status) => status != null && status < 500,
               headers: {
                 if (secret != null && secret.isNotEmpty)
                   'Authorization': 'Bearer $secret',
               },
             ),
           );

  final Dio _dio;

  @override
  Future<Map<String, dynamic>> get(String path) async {
    final response = await _request(() => _dio.get<dynamic>(path));
    _checkStatus(response);
    final data = response.data;
    if (data is! Map) {
      throw const ClashUnreachableException('unexpected response');
    }
    return Map<String, dynamic>.from(data);
  }

  @override
  Future<void> send(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _request(
      () => _dio.request<dynamic>(
        path,
        data: body,
        options: Options(method: method),
      ),
    );
    _checkStatus(response);
  }

  Future<Response<dynamic>> _request(
    Future<Response<dynamic>> Function() send,
  ) async {
    try {
      return await send();
    } on DioException catch (e) {
      throw ClashUnreachableException(
        e.type == DioExceptionType.connectionTimeout ||
                e.type == DioExceptionType.receiveTimeout
            ? 'timed out'
            : e.message ?? e.type.name,
      );
    }
  }

  void _checkStatus(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) throw const ClashAuthException();
    if (status >= 400) {
      throw ClashUnreachableException('HTTP $status');
    }
  }
}

/// Reads the OpenClash service and its running core.
///
/// Three sources, each optional on its own:
///
/// * the `openclash` UCI config — always readable, and the only thing that
///   exists on a router where the service is installed but stopped;
/// * `rc.list` — whether the init script is running and enabled;
/// * the Clash controller — version, mode, traffic and proxy groups.
///
/// A stopped core has no controller, so "not running" is a complete answer and
/// the screen says so instead of showing a timeout as an error.
class OpenClashService {
  OpenClashService(this._api, {ClashApiFactory? clients})
    : _clients = clients ?? _httpClient;

  final IApiService _api;
  final ClashApiFactory _clients;

  static ClashApi _httpClient({
    required String host,
    required int port,
    String? secret,
  }) => HttpClashApi(host: host, port: port, secret: secret);

  Future<OpenClashSnapshot> read(RouterSession session) async {
    OpenClashConfig config;
    try {
      config = OpenClashConfig.fromUci(
        await uciConfigValues(_api, session, 'openclash'),
      );
    } catch (_) {
      // `uci.get` is refused when the package is not installed; that is an
      // answer ("no OpenClash here"), not a failure to report.
      return const OpenClashSnapshot();
    }
    if (!config.installed) return const OpenClashSnapshot();

    var running = false;
    var enabled = config.enabledInConfig;
    var runningKnown = false;
    try {
      final services = await _api.rcList(
        session.ipAddress,
        session.sysauth,
        session.useHttps,
      );
      final status = services['openclash'];
      if (status != null) {
        running = status.running ?? false;
        enabled = status.enabled;
        runningKnown = true;
      }
    } catch (_) {
      // Without `rc.list` the truth is still discoverable: if the controller
      // answers, the core is running. Let the probe below decide.
    }

    if (!config.hasApi) {
      return OpenClashSnapshot(config: config, enabled: enabled);
    }

    // A stopped core has no controller, so asking would only spend the full
    // timeout to learn what init already said. Only skip the probe when init
    // actually answered — an unreadable `rc.list` must not be read as "off".
    if (runningKnown && !running) {
      return OpenClashSnapshot(config: config, enabled: enabled);
    }

    final client = _clients(
      host: clashHost(session.ipAddress),
      port: config.apiPort,
      secret: config.secret,
    );

    String? apiError;
    Map<String, dynamic>? version;
    try {
      version = await client.get('/version');
      // The controller answered, so the core is up whatever init says.
      running = true;
    } on ClashApiException catch (e) {
      apiError = e.message;
    } catch (e) {
      apiError = e.toString();
    }

    if (version == null) {
      return OpenClashSnapshot(
        config: config,
        running: running,
        enabled: enabled,
        apiError: running ? apiError : null,
      );
    }

    final configs = await _try(client, '/configs');
    final proxies = await _try(client, '/proxies');
    final connections = await _try(client, '/connections');

    final totals = connections?['connections'];
    return OpenClashSnapshot(
      config: config,
      running: true,
      enabled: enabled,
      version: _text(version['version']),
      coreName: version['meta'] == true ? 'Mihomo' : 'Clash',
      mode: _text(configs?['mode']),
      mixedPort: _int(configs?['mixed-port']),
      uploadTotal: _int(connections?['uploadTotal']) ?? 0,
      downloadTotal: _int(connections?['downloadTotal']) ?? 0,
      activeConnections: totals is List ? totals.length : 0,
      groups: OpenClashGroup.listFrom(proxies),
    );
  }

  /// One optional read. A controller that answers `/version` but fails
  /// `/proxies` is still worth showing — only the missing part is omitted.
  Future<Map<String, dynamic>?> _try(ClashApi client, String path) async {
    try {
      return await client.get(path);
    } catch (_) {
      return null;
    }
  }

  static String? _text(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('${value ?? ''}');
}

/// The host part of `session.ipAddress`, which may carry a port.
///
/// Kept here rather than reaching for `Uri.parse`: a bare IPv6 literal is not
/// a valid URI, and a router addressed as `fd00::1` must not become
/// `http://fd00::1:9090` (which parses as host `fd00` and port `::1:9090`).
String clashHost(String address) {
  var host = address.trim();
  if (host.startsWith('[')) {
    final close = host.indexOf(']');
    return close < 0 ? host : host.substring(1, close);
  }
  final parts = host.split(':');
  if (parts.length == 2 && int.tryParse(parts[1]) != null) return parts[0];
  return host;
}
