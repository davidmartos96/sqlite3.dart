import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:sqlite3/common.dart';
import 'package:web/web.dart'
    hide Response, Request, FileSystem, Notification, Lock;

import 'api.dart';
import 'channel.dart';
import 'protocol.dart';
import 'shared.dart';

final class RemoteDatabase implements Database {
  final WorkerConnection connection;
  final int databaseId;

  StreamSubscription<Notification>? _notificationSubscription;
  final StreamController<SqliteUpdate> _updates = StreamController.broadcast();

  RemoteDatabase({required this.connection, required this.databaseId}) {
    _updates
      ..onListen = (() {
        _notificationSubscription ??=
            connection.notifications.stream.listen((notification) {
          if (notification case UpdateNotification()) {
            if (notification.databaseId == databaseId) {
              _updates.add(notification.update);
            }
          }
        });

        _requestUpdates(true);
      })
      ..onCancel = (() {
        _notificationSubscription?.cancel();
        _notificationSubscription = null;

        _requestUpdates(false);
      });
  }

  void _requestUpdates(bool sendUpdates) {
    connection.sendRequest(
      UpdateStreamRequest(
          action: sendUpdates, requestId: 0, databaseId: databaseId),
      MessageType.simpleSuccessResponse,
    );
  }

  @override
  Future<void> dispose() async {
    _updates.close();
    await connection.sendRequest(
        CloseDatabase(requestId: 0, databaseId: databaseId),
        MessageType.simpleSuccessResponse);
  }

  @override
  Future<void> execute(String sql,
      [List<Object?> parameters = const []]) async {
    await connection.sendRequest(
      RunQuery(
        requestId: 0,
        databaseId: databaseId,
        sql: sql,
        parameters: parameters,
        returnRows: false,
      ),
      MessageType.simpleSuccessResponse,
    );
  }

  @override
  FileSystem get fileSystem => throw UnimplementedError();

  @override
  Future<int> get lastInsertRowId async {
    final result = await select('select last_insert_rowid();');
    return result.single[0] as int;
  }

  @override
  Future<ResultSet> select(String sql,
      [List<Object?> parameters = const []]) async {
    final response = await connection.sendRequest(
      RunQuery(
        requestId: 0,
        databaseId: databaseId,
        sql: sql,
        parameters: parameters,
        returnRows: true,
      ),
      MessageType.rowsResponse,
    );

    return response.resultSet;
  }

  @override
  Future<void> setUserVersion(int version) async {
    await execute('pragma user_version = ?', [version]);
  }

  @override
  Stream<SqliteUpdate> get updates => _updates.stream;

  @override
  Future<int> get userVersion async {
    final result = await select('pragma user_version;');
    return result.single[0] as int;
  }
}

final class WorkerConnection extends ProtocolChannel {
  final StreamController<Notification> notifications =
      StreamController.broadcast();

  WorkerConnection(super.channel) {
    closed.whenComplete(notifications.close);
  }

  @override
  Future<Response> handleRequest(Request request) {
    // TODO: implement handleRequest
    throw UnimplementedError();
  }

  @override
  void handleNotification(Notification notification) {
    notifications.add(notification);
  }
}

final class DatabaseClient implements WebSqlite {
  final Uri workerUri;
  final Uri wasmUri;

  final Lock _startWorkersLock = Lock();
  bool _startedWorkers = false;
  WorkerConnection? _connectionToDedicated;
  WorkerConnection? _connectionToShared;
  final Set<MissingBrowserFeature> _missingFeatures = {};

  DatabaseClient(this.workerUri, this.wasmUri);

  Future<void> startWorkers() {
    return _startWorkersLock.synchronized(() async {
      if (_startedWorkers) {
        return;
      }
      _startedWorkers = true;

      if (globalContext.has('Worker')) {
        final dedicated = Worker(
          workerUri.toString(),
          WorkerOptions(name: 'sqlite3_worker'),
        );

        final (endpoint, channel) = await createChannel();
        endpoint.postToWorker(dedicated);

        _connectionToDedicated =
            WorkerConnection(channel.injectErrorsFrom(dedicated));
      } else {
        _missingFeatures.add(MissingBrowserFeature.dedicatedWorkers);
      }

      if (globalContext.has('SharedWorker')) {
        final shared = SharedWorker(workerUri.toString());
        shared.port.start();

        final (endpoint, channel) = await createChannel();
        endpoint.postToPort(shared.port);

        _connectionToShared =
            WorkerConnection(channel.injectErrorsFrom(shared));
      } else {
        _missingFeatures.add(MissingBrowserFeature.sharedWorkers);
      }
    });
  }

  @override
  Future<FeatureDetectionResult> runFeatureDetection(
      {String? databaseName}) async {
    await startWorkers();

    final existing = <ExistingDatabase>{};

    if (_connectionToDedicated case final connection?) {
      final response = await connection.sendRequest(
        CompatibilityCheck(
          requestId: 0,
          type: MessageType.dedicatedCompatibilityCheck,
          databaseName: databaseName,
        ),
        MessageType.simpleSuccessResponse,
      );
      final result = CompatibilityResult.fromJS(response.response as JSObject);
      existing.addAll(result.existingDatabases);

      if (!result.canUseIndexedDb) {
        _missingFeatures.add(MissingBrowserFeature.indexedDb);
      }
      if (!result.canUseOpfs) {
        _missingFeatures.add(MissingBrowserFeature.fileSystemAccess);
      }
      if (!result.supportsSharedArrayBuffers) {
        _missingFeatures.add(MissingBrowserFeature.sharedArrayBuffers);
      }
    }

    if (_connectionToShared case final connection?) {
      final response = await connection.sendRequest(
        CompatibilityCheck(
          requestId: 0,
          type: MessageType.sharedCompatibilityCheck,
          databaseName: databaseName,
        ),
        MessageType.simpleSuccessResponse,
      );
      final result = CompatibilityResult.fromJS(response.response as JSObject);
      if (!result.sharedCanSpawnDedicated) {
        _missingFeatures
            .add(MissingBrowserFeature.dedicatedWorkersInSharedWorkers);
      }
      if (!result.canUseIndexedDb) {
        _missingFeatures.add(MissingBrowserFeature.indexedDb);
      }
    }

    return FeatureDetectionResult(
      missingFeatures: _missingFeatures.toList(),
      existingDatabases: existing.toList(),
    );
  }

  @override
  Future<Database> connect(
      String name, StorageMode type, AccessMode access) async {
    await startWorkers();

    await Future.delayed(Duration(milliseconds: 100));

    final connection = _connectionToDedicated!;
    final data = await connection.sendRequest(
      OpenRequest(
        requestId: 0,
        wasmUri: wasmUri,
        databaseName: name,
        storageMode: FileSystemImplementation.inMemory,
      ),
      MessageType.simpleSuccessResponse,
    );

    return RemoteDatabase(
        connection: connection,
        databaseId: (data.response as JSNumber).toDartInt);
  }
}
