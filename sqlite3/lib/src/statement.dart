import 'package:meta/meta.dart';

import 'exception.dart';
import 'result_set.dart';

/// A prepared statement.
abstract class CommonPreparedStatement {
  /// The SQL statement backing this prepared statement.
  String get sql;

  /// Returns the amount of parameters in this prepared statement.
  int get parameterCount;

  /// {@template pkg_sqlite3_stmt_execute}
  /// Executes this statement, ignoring result rows if there are any.
  ///
  /// If the [parameters] list does not match the amount of parameters in the
  /// original SQL statement ([parameterCount]), an [ArgumentError] will be
  /// thrown.
  /// If sqlite3 reports an error while running this statement, a
  /// [SqliteException] will be thrown.
  /// {@endtemplate}
  void executeWith(StatementParameters parameters);

  /// {@template pkg_sqlite3_stmt_select}
  /// Selects all rows into a [ResultSet].
  ///
  /// If the [parameters] list does not match the amount of parameters in the
  /// original SQL statement ([parameterCount]), an [ArgumentError] will be
  /// thrown.
  /// If sqlite3 reports an error while running this statement, a
  /// [SqliteException] will be thrown.
  /// {@endtemplate}
  ResultSet selectWith(StatementParameters parameters);

  /// {@template pkg_sqlite3_stmt_iterate}
  /// Starts selecting rows by running this prepared statement with the given
  /// [parameters].
  ///
  /// If the [parameters] list does not match the amount of parameters in the
  /// original SQL statement ([parameterCount]), an [ArgumentError] will be
  /// thrown.
  ///
  /// If sqlite3 reports an error while running this statement, it will be
  /// thrown by a call to [Iterator.moveNext].
  ///
  /// The iterator returned here will become invalid with the next call to a
  /// method that runs this statement ([execute], [executeWith], [select],
  /// [selectWith], [selectCursor], [iterateWith]).
  /// {@endtemplate}
  IteratingCursor iterateWith(StatementParameters parameters);

  /// {@macro pkg_sqlite3_stmt_execute}
  void execute([List<Object?> parameters = const <Object>[]]) {
    return executeWith(StatementParameters(parameters));
  }

  /// {@macro pkg_sqlite3_stmt_execute}
  ///
  /// Unlike [execute], which binds parameters by their index, [executeMap]
  /// binds parameters by their name.
  /// For instance, a SQL query `SELECT :foo, @bar;` has two named parameters
  /// (`:foo` and `@bar`) that can occur as keys in [parameters].
  @Deprecated('Use executeWith(StatementParameters.named) instead')
  void executeMap(Map<String, Object?> parameters) {
    return executeWith(StatementParameters.named(parameters));
  }

  /// {@macro pkg_sqlite3_stmt_select}
  ResultSet select([List<Object?> parameters = const <Object>[]]) {
    return selectWith(StatementParameters(parameters));
  }

  /// {@macro pkg_sqlite3_stmt_select}
  ///
  /// Similar to [executeMap], parameters are bound by their name instead of
  /// their index.
  @Deprecated('Use selectWith(StatementParameters.named) instead')
  ResultSet selectMap(Map<String, Object?> parameters) {
    return selectWith(StatementParameters.named(parameters));
  }

  /// {@macro pkg_sqlite3_stmt_iterate}
  IteratingCursor selectCursor([List<Object?> parameters = const <Object>[]]) {
    return iterateWith(StatementParameters(parameters));
  }

  /// Disposes this statement and releases associated memory.
  void dispose();
}

/// A set of values that can be used to bind [parameters] in a SQL query.
///
/// Parameters are placeholder values in SQL that can safely be bound to values
/// later without a risk of SQL injection attacks.
/// Depending on the syntax used to declare a parameter, it may make sense to
/// pass parameters by their index or by name. The different constructors of
/// this class can be used to control how parameters are passed.
///
/// [parameters]: https://www.sqlite.org/lang_expr.html#varparam
sealed class StatementParameters {
  /// Convenience factory to use when no parameters should be passed.
  const factory StatementParameters.empty() = IndexedParameters.empty;

  /// Passes parameters by their variable number.
  const factory StatementParameters(List<Object?> parameters) =
      IndexedParameters;

  /// Passes variables by their name.
  ///
  /// For instance, the statement `SELECT * FROM users WHERE id = :id` could be
  /// bound with `StatementParameters.named({':a': 42})`.
  const factory StatementParameters.named(Map<String, Object?> parameters) =
      NamedParameters;

  /// Passes variables by invoking a callback responsible for using a native
  /// statement handle to bind parameters.
  ///
  /// Other constructors validate parameters, making them harder to misuse. In
  /// special cases where that doesn't work, this constructor can be used to
  /// indicate that you are fully responsible for binding parameters and don't
  /// need any validation checks.
  const factory StatementParameters.bindCustom(
      void Function(CommonPreparedStatement stmt) bind) = CustomParameters;
}

@internal
class IndexedParameters implements StatementParameters {
  final List<Object?> parameters;

  const IndexedParameters(this.parameters);

  const IndexedParameters.empty() : parameters = const [];
}

@internal
class NamedParameters implements StatementParameters {
  final Map<String, Object?> parameters;

  const NamedParameters(this.parameters);
}

@internal
class CustomParameters implements StatementParameters {
  final void Function(CommonPreparedStatement) bind;

  const CustomParameters(this.bind);
}
