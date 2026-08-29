import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';

enum McpTransportType { streamableHttp, legacySse }

enum McpConnectionStatus {
  disabled,
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

enum McpToolPermission { askEveryTime, alwaysAllow, denied }

enum McpApprovalDecision { allowOnce, alwaysAllow, deny, cancel }

enum McpActivityKind {
  configured,
  connected,
  disconnected,
  discovery,
  permission,
  error,
  cancelled,
}

final class McpException implements Exception {
  const McpException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MCP error [$code]: $message';
}

final class McpServerConfig {
  McpServerConfig({
    required String id,
    required String name,
    required Uri endpoint,
    this.transport = McpTransportType.streamableHttp,
    this.enabled = false,
    this.allowInsecureHttp = false,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration requestTimeout = const Duration(seconds: 30),
  })  : id = _validateId(id),
        name = _validateName(name),
        endpoint = _validateEndpoint(endpoint, allowInsecureHttp),
        connectTimeout = _validateDuration(connectTimeout, 'connect'),
        requestTimeout = _validateDuration(requestTimeout, 'request');

  final String id;
  final String name;
  final Uri endpoint;
  final McpTransportType transport;
  final bool enabled;
  final bool allowInsecureHttp;
  final Duration connectTimeout;
  final Duration requestTimeout;

  String get displayEndpoint => endpoint.hasQuery
      ? '${endpoint.origin}${endpoint.path}'
      : endpoint.toString();

  McpServerConfig copyWith({
    String? name,
    Uri? endpoint,
    McpTransportType? transport,
    bool? enabled,
    bool? allowInsecureHttp,
    Duration? connectTimeout,
    Duration? requestTimeout,
  }) {
    return McpServerConfig(
      id: id,
      name: name ?? this.name,
      endpoint: endpoint ?? this.endpoint,
      transport: transport ?? this.transport,
      enabled: enabled ?? this.enabled,
      allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      requestTimeout: requestTimeout ?? this.requestTimeout,
    );
  }

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    return McpServerConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      endpoint: Uri.parse(json['endpoint'] as String),
      transport: McpTransportType.values.firstWhere(
        (candidate) => candidate.name == json['transport'],
      ),
      enabled: json['enabled'] as bool? ?? false,
      allowInsecureHttp: json['allowInsecureHttp'] as bool? ?? false,
      connectTimeout: Duration(
        milliseconds: json['connectTimeoutMs'] as int? ?? 15000,
      ),
      requestTimeout: Duration(
        milliseconds: json['requestTimeoutMs'] as int? ?? 30000,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'endpoint': endpoint.toString(),
        'transport': transport.name,
        'enabled': enabled,
        'allowInsecureHttp': allowInsecureHttp,
        'connectTimeoutMs': connectTimeout.inMilliseconds,
        'requestTimeoutMs': requestTimeout.inMilliseconds,
      };

  static String _validateId(String source) {
    final value = source.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value)) {
      throw const McpException(
        'invalid_server_id',
        'Server IDs may only contain letters, numbers, dashes, and underscores.',
      );
    }
    return value;
  }

  static String _validateName(String source) {
    final value = source.trim();
    if (value.isEmpty || value.length > 80) {
      throw const McpException(
        'invalid_server_name',
        'Server names must contain 1-80 characters.',
      );
    }
    return value;
  }

  static Uri _validateEndpoint(Uri source, bool allowInsecureHttp) {
    final scheme = source.scheme.toLowerCase();
    if (!source.isAbsolute ||
        !source.hasAuthority ||
        (scheme != 'http' && scheme != 'https') ||
        source.userInfo.isNotEmpty ||
        source.fragment.isNotEmpty) {
      throw const McpException(
        'invalid_endpoint',
        'Use an absolute HTTP(S) URL without credentials or a fragment.',
      );
    }
    if (source.queryParameters.keys.any(_looksSensitive)) {
      throw const McpException(
        'credential_in_url',
        'Put credentials in the token field, not in the server URL.',
      );
    }
    if (scheme == 'http' && !_isLoopback(source.host) && !allowInsecureHttp) {
      throw const McpException(
        'insecure_endpoint',
        'Non-loopback HTTP requires explicit insecure transport approval.',
      );
    }
    return source;
  }

  static Duration _validateDuration(Duration value, String kind) {
    if (value <= Duration.zero) {
      throw McpException(
        'invalid_${kind}_timeout',
        'The $kind timeout must be greater than zero.',
      );
    }
    return value;
  }
}

final class McpToolDescriptor {
  McpToolDescriptor({
    required this.serverId,
    required this.name,
    required this.title,
    required this.description,
    required Map<String, dynamic> inputSchema,
    required this.accessLevel,
    required this.destructiveHint,
    required this.openWorldHint,
  }) : inputSchema = copyToolJsonObject(inputSchema);

  final String serverId;
  final String name;
  final String title;
  final String description;
  final Map<String, dynamic> inputSchema;
  final ToolAccessLevel accessLevel;
  final bool destructiveHint;
  final bool openWorldHint;

  String get permissionKey => '$serverId::$name';

  String get qualifiedName {
    final server = serverId.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
    final normalizedTool = name.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
    final tool = normalizedTool.isEmpty ? 'tool' : normalizedTool;
    final readable = 'mcp_${server}_$tool';
    final digest = sha256
        .convert(utf8.encode('$serverId\u0000$name'))
        .toString()
        .substring(0, 12);
    final prefix = readable.length <= 51 ? readable : readable.substring(0, 51);
    return '${prefix}_$digest';
  }
}

final class McpToolPermissionRecord {
  const McpToolPermissionRecord({
    required this.serverId,
    required this.toolName,
    required this.permission,
  });

  final String serverId;
  final String toolName;
  final McpToolPermission permission;

  String get key => '$serverId::$toolName';

  factory McpToolPermissionRecord.fromJson(Map<String, dynamic> json) {
    return McpToolPermissionRecord(
      serverId: json['serverId'] as String,
      toolName: json['toolName'] as String,
      permission: McpToolPermission.values.firstWhere(
        (candidate) => candidate.name == json['permission'],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'toolName': toolName,
        'permission': permission.name,
      };
}

final class McpStoredSettings {
  McpStoredSettings({
    this.enabled = false,
    Iterable<McpServerConfig> servers = const [],
    Iterable<McpToolPermissionRecord> permissions = const [],
  })  : servers = List.unmodifiable(servers),
        permissions = List.unmodifiable(permissions);

  final bool enabled;
  final List<McpServerConfig> servers;
  final List<McpToolPermissionRecord> permissions;

  factory McpStoredSettings.fromJson(Map<String, dynamic> json) {
    return McpStoredSettings(
      enabled: json['enabled'] as bool? ?? false,
      servers: (json['servers'] as List<dynamic>? ?? const [])
          .map((item) => McpServerConfig.fromJson(
                Map<String, dynamic>.from(item as Map),
              )),
      permissions: (json['permissions'] as List<dynamic>? ?? const [])
          .map((item) => McpToolPermissionRecord.fromJson(
                Map<String, dynamic>.from(item as Map),
              )),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'enabled': enabled,
        'servers': servers.map((server) => server.toJson()).toList(),
        'permissions':
            permissions.map((permission) => permission.toJson()).toList(),
      };
}

final class McpServerSnapshot {
  McpServerSnapshot({
    required this.config,
    this.status = McpConnectionStatus.disconnected,
    Iterable<McpToolDescriptor> tools = const [],
    this.serverImplementation,
    this.serverVersion,
    this.protocolVersion,
    this.errorCode,
    this.errorMessage,
    this.connectedAt,
  }) : tools = List.unmodifiable(tools);

  final McpServerConfig config;
  final McpConnectionStatus status;
  final List<McpToolDescriptor> tools;
  final String? serverImplementation;
  final String? serverVersion;
  final String? protocolVersion;
  final String? errorCode;
  final String? errorMessage;
  final DateTime? connectedAt;

  bool get isConnected => status == McpConnectionStatus.connected;

  McpServerSnapshot copyWith({
    McpServerConfig? config,
    McpConnectionStatus? status,
    List<McpToolDescriptor>? tools,
    bool clearTools = false,
    String? serverImplementation,
    String? serverVersion,
    String? protocolVersion,
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
  }) {
    return McpServerSnapshot(
      config: config ?? this.config,
      status: status ?? this.status,
      tools: clearTools ? const [] : (tools ?? this.tools),
      serverImplementation: serverImplementation ?? this.serverImplementation,
      serverVersion: serverVersion ?? this.serverVersion,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      connectedAt: clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
    );
  }
}

final class McpActivityRecord {
  const McpActivityRecord({
    required this.timestamp,
    required this.serverId,
    required this.kind,
    required this.message,
    this.toolName,
    this.errorCode,
  });

  final DateTime timestamp;
  final String serverId;
  final McpActivityKind kind;
  final String message;
  final String? toolName;
  final String? errorCode;

  factory McpActivityRecord.fromJson(Map<String, dynamic> json) {
    return McpActivityRecord(
      timestamp: DateTime.parse(json['timestamp'] as String),
      serverId: json['serverId'] as String,
      kind: McpActivityKind.values.firstWhere(
        (candidate) => candidate.name == json['kind'],
      ),
      message: json['message'] as String,
      toolName: json['toolName'] as String?,
      errorCode: json['errorCode'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toUtc().toIso8601String(),
        'serverId': serverId,
        'kind': kind.name,
        'message': message,
        if (toolName != null) 'toolName': toolName,
        if (errorCode != null) 'errorCode': errorCode,
      };
}

bool _looksSensitive(String source) {
  final key = source.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return key.contains('token') ||
      key.contains('key') ||
      key.contains('secret') ||
      key.contains('password') ||
      key.contains('credential') ||
      key.contains('authorization');
}

bool _isLoopback(String source) {
  final host = source.toLowerCase();
  return host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]';
}
