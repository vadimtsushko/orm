import 'dart:async';
import 'package:analyzer/dart/element/element.dart';
import 'package:angel_serialize/angel_serialize.dart';
import 'package:build/build.dart';
import 'package:code_builder/dart/async.dart';
import 'package:code_builder/dart/core.dart';
import 'package:code_builder/code_builder.dart';
import 'package:inflection/inflection.dart';
import 'package:path/path.dart' as p;
import 'package:recase/recase.dart';
import 'package:source_gen/src/annotation.dart';
import 'package:source_gen/src/utils.dart';
import 'package:source_gen/source_gen.dart';
import '../../annotations.dart';
import '../../migration.dart';
import 'package:angel_serialize/src/find_annotation.dart';
import 'build_context.dart';
import 'postgres_build_context.dart';

// TODO: HasOne, HasMany, BelongsTo
class PostgresORMGenerator extends GeneratorForAnnotation<ORM> {
  /// If "true" (default), then field names will automatically be (de)serialized as snake_case.
  final bool autoSnakeCaseNames;

  /// If "true" (default), then
  final bool autoIdAndDateFields;

  const PostgresORMGenerator(
      {this.autoSnakeCaseNames: true, this.autoIdAndDateFields: true});

  @override
  Future<String> generateForAnnotatedElement(
      Element element, ORM annotation, BuildStep buildStep) async {
    if (element is! ClassElement)
      throw 'Only classes can be annotated with @serializable.';
    var resolver = await buildStep.resolver;
    return prettyToSource(
        generateOrmLibrary(element.library, resolver, buildStep).buildAst());
  }

  LibraryBuilder generateOrmLibrary(
      LibraryElement libraryElement, Resolver resolver, BuildStep buildStep) {
    var lib = new LibraryBuilder();
    lib.addDirective(new ImportBuilder('dart:async'));
    lib.addDirective(new ImportBuilder('package:angel_orm/angel_orm.dart'));
    lib.addDirective(new ImportBuilder('package:postgres/postgres.dart'));
    lib.addDirective(new ImportBuilder(p.basename(buildStep.inputId.path)));
    var elements = getElementsFromLibraryElement(libraryElement)
        .where((el) => el is ClassElement);
    Map<ClassElement, PostgresBuildContext> contexts = {};
    List<String> done = [];
    List<String> imported = [];

    for (var element in elements) {
      if (!done.contains(element.name)) {
        var ann = element.metadata
            .firstWhere((a) => matchAnnotation(ORM, a), orElse: () => null);
        if (ann != null) {
          var ctx = contexts[element] = buildContext(
              element,
              instantiateAnnotation(ann),
              buildStep,
              resolver,
              autoSnakeCaseNames != false,
              autoIdAndDateFields != false);
          ctx.relationships.forEach((name, relationship) {
            var field = ctx.resolveRelationshipField(name);
            var uri = field.type.element.source.uri;
            var pathName = p
                .basenameWithoutExtension(p.basenameWithoutExtension(uri.path));
            var source =
                '$pathName.orm.g.dart'; //uri.resolve('$pathName.orm.g.dart').toString();
            // TODO: Find good way to source url...
            source = new ReCase(field.type.name).snakeCase + '.orm.g.dart';

            if (!imported.contains(source)) {
              lib.addDirective(new ImportBuilder(source));
              imported.add(source);
            }
          });
        }
      }
    }

    done.clear();
    for (var element in contexts.keys) {
      if (!done.contains(element.name)) {
        var ctx = contexts[element];
        lib.addMember(buildQueryClass(ctx));
        lib.addMember(buildWhereClass(ctx));
        done.add(element.name);
      }
    }
    return lib;
  }

  ClassBuilder buildQueryClass(PostgresBuildContext ctx) {
    var clazz = new ClassBuilder(ctx.queryClassName);

    // Add constructor + field
    var PostgreSQLConnection = new TypeBuilder('PostgreSQLConnection');
    var connection = reference('connection');

    // Add or + not
    for (var relation in ['and', 'or', 'not']) {
      clazz.addField(varFinal('_$relation',
          type: new TypeBuilder('List', genericTypes: [lib$core.String]),
          value: list([])));
      var relationMethod =
          new MethodBuilder(relation, returnType: lib$core.$void);
      relationMethod.addPositional(
          parameter('other', [new TypeBuilder(ctx.queryClassName)]));
      var otherWhere = reference('other').property('where');
      var compiled = reference('compiled');
      relationMethod.addStatement(
          varField('compiled', value: otherWhere.invoke('toWhereClause', [])));
      relationMethod.addStatement(ifThen(compiled.notEquals(literal(null)), [
        reference('_$relation').invoke('add', [compiled])
      ]));
      clazz.addMethod(relationMethod);
    }

    // Add _buildSelectQuery()

    // Add where...
    clazz.addField(varFinal('where',
        type: new TypeBuilder(ctx.whereClassName),
        value: new TypeBuilder(ctx.whereClassName).newInstance([])));

    // Add toSql()...
    clazz.addMethod(buildToSqlMethod(ctx));

    // Add parseRow()...
    clazz.addMethod(buildParseRowMethod(ctx), asStatic: true);

    // Add get()...
    clazz.addMethod(buildGetMethod(ctx));

    // Add getOne()...
    clazz.addMethod(buildGetOneMethod(ctx), asStatic: true);

    // Add update()...
    clazz.addMethod(buildUpdateMethod(ctx));

    // Add remove()...
    clazz.addMethod(buildDeleteMethod(ctx));

    // Add insert()...
    clazz.addMethod(buildInsertMethod(ctx), asStatic: true);

    // Add getAll() => new TodoQuery().get();
    clazz.addMethod(
        new MethodBuilder('getAll',
            returnType: new TypeBuilder('Stream',
                genericTypes: [new TypeBuilder(ctx.modelClassName)]),
            returns: new TypeBuilder(ctx.queryClassName)
                .newInstance([]).invoke('get', [connection]))
          ..addPositional(parameter('connection', [PostgreSQLConnection])),
        asStatic: true);

    return clazz;
  }

  MethodBuilder buildToSqlMethod(PostgresBuildContext ctx) {
    // TODO: Bake relations into SQL queries
    var meth = new MethodBuilder('toSql', returnType: lib$core.String);
    meth.addStatement(varField('buf',
        value: lib$core.StringBuffer
            .newInstance([literal('SELECT * FROM "${ctx.tableName}"')])));
    meth.addStatement(varField('whereClause',
        value: reference('where').invoke('toWhereClause', [])));
    var buf = reference('buf');
    var whereClause = reference('whereClause');

    meth.addStatement(ifThen(whereClause.notEquals(literal(null)), [
      buf.invoke('write', [literal(' ') + whereClause])
    ]));

    meth.addStatement(buf.invoke('write', [literal(';')]));
    meth.addStatement(buf.invoke('toString', []).asReturn());

    return meth;
  }

  MethodBuilder buildParseRowMethod(PostgresBuildContext ctx) {
    var meth = new MethodBuilder('parseRow',
        returnType: new TypeBuilder(ctx.modelClassName));
    meth.addPositional(parameter('row', [lib$core.List]));
    //meth.addStatement(lib$core.print.call(
    //    [literal('ROW MAP: ') + reference('row').invoke('toString', [])]));
    var row = reference('row');
    var DATE_YMD_HMS = reference('DATE_YMD_HMS');

    // We want to create a Map using the SQL row.
    Map<String, ExpressionBuilder> data = {};

    int i = 0;

    ctx.fields.forEach((field) {
      var name = ctx.resolveFieldName(field.name);
      var rowKey = row[literal(i++)];

      if (field.type.isAssignableTo(ctx.dateTimeType)) {
        // TODO: Handle DATE and not just DATETIME
        data[name] = DATE_YMD_HMS.invoke('parse', [rowKey]);
      } else if (field.name == 'id' && ctx.shimmed.containsKey('id')) {
        data[name] = rowKey.invoke('toString', []);
      } else if (field.type.isAssignableTo(ctx.typeProvider.boolType)) {
        data[name] = rowKey.equals(literal(1));
      } else
        data[name] = rowKey;
    });

    ctx.relationships.forEach((name, relationship) {
      var field = ctx.resolveRelationshipField(name);
      var alias = ctx.resolveFieldName(name);
      var idx = i++;
      var rowKey = row[literal(idx)];
      data[alias] = (row.property('length') < literal(idx + 1)).ternary(
          literal(null),
          new TypeBuilder(new ReCase(field.type.name).pascalCase + 'Query')
              .invoke('parseRow', [rowKey]));
    });

    // Then, call a .fromJson() constructor
    meth.addStatement(new TypeBuilder(ctx.modelClassName)
        .newInstance([map(data)], constructor: 'fromJson').asReturn());

    return meth;
  }

  MethodBuilder buildGetMethod(PostgresBuildContext ctx) {
    var meth = new MethodBuilder('get',
        returnType: new TypeBuilder('Stream',
            genericTypes: [new TypeBuilder(ctx.modelClassName)]));
    meth.addPositional(
        parameter('connection', [new TypeBuilder('PostgreSQLConnection')]));
    var streamController = new TypeBuilder('StreamController',
        genericTypes: [new TypeBuilder(ctx.modelClassName)]);
    var ctrl = reference('ctrl'), connection = reference('connection');
    meth.addStatement(varField('ctrl',
        type: streamController, value: streamController.newInstance([])));

    // Invoke query...
    var future = connection.invoke('query', [reference('toSql').call([])]);
    var catchError = ctrl.property('addError');
    var then = new MethodBuilder.closure()..addPositional(parameter('rows'));
    then.addStatement(reference('rows')
        .invoke('map', [reference('parseRow')]).invoke(
            'forEach', [ctrl.property('add')]));
    then.addStatement(ctrl.invoke('close', []));
    meth.addStatement(
        future.invoke('then', [then]).invoke('catchError', [catchError]));
    meth.addStatement(ctrl.property('stream').asReturn());
    return meth;
  }

  MethodBuilder buildGetOneMethod(PostgresBuildContext ctx) {
    var meth = new MethodBuilder('getOne',
        returnType: new TypeBuilder('Future',
            genericTypes: [new TypeBuilder(ctx.modelClassName)]));
    meth.addPositional(parameter('id', [lib$core.int]));
    meth.addPositional(
        parameter('connection', [new TypeBuilder('PostgreSQLConnection')]));
    meth.addStatement(reference('connection').invoke('query', [
      literal('SELECT * FROM "${ctx.tableName}" WHERE "id" = @id;')
    ], namedArguments: {
      'substitutionValues': map({'id': reference('id')})
    }).invoke('then', [
      new MethodBuilder.closure(
          returns:
              reference('parseRow').call([reference('rows').property('first')]))
        ..addPositional(parameter('rows'))
    ]).asReturn());
    return meth;
  }

  void _addAllNamed(MethodBuilder meth, PostgresBuildContext ctx) {
    // Add all named params
    ctx.fields.forEach((field) {
      if (field.name != 'id') {
        var p = new ParameterBuilder(field.name,
            type: new TypeBuilder(field.type.name));
        var column = ctx.columnInfo[field.name];
        if (column?.defaultValue != null)
          p = p.asOptional(literal(column.defaultValue));
        meth.addNamed(p);
      }
    });
  }

  void _addReturning(StringBuffer buf, PostgresBuildContext ctx) {
    buf.write(' RETURNING (');
    int i = 0;
    ctx.fields.forEach((field) {
      if (i++ > 0) buf.write(', ');
      var name = ctx.resolveFieldName(field.name);
      buf.write('"$name"');
    });

    buf.write(');');
  }

  void _ensureDates(MethodBuilder meth, PostgresBuildContext ctx) {
    if (ctx.fields.any((f) => f.name == 'createdAt' || f.name == 'updatedAt')) {
      meth.addStatement(varField('__ormNow__',
          value: lib$core.DateTime.newInstance([], constructor: 'now')));
    }
  }

  Map<String, ExpressionBuilder> _buildSubstitutionValues(
      PostgresBuildContext ctx) {
    Map<String, ExpressionBuilder> substitutionValues = {};
    ctx.fields.forEach((field) {
      if (field.name == 'id')
        return;
      else if (field.name == 'createdAt' || field.name == 'updatedAt') {
        var ref = reference(field.name);
        substitutionValues[field.name] =
            ref.notEquals(literal(null)).ternary(ref, reference('__ormNow__'));
      } else
        substitutionValues[field.name] = reference(field.name);
    });
    return substitutionValues;
  }

  void _executeQuery(StringBuffer buf, MethodBuilder meth,
      Map<String, ExpressionBuilder> substitutionValues) {
    var connection = reference('connection');
    var query = literal(buf.toString());
    var result = reference('result');
    meth.addStatement(varField('result',
        value: connection.invoke('query', [
          query
        ], namedArguments: {
          'substitutionValues': map(substitutionValues)
        }).asAwait()));
    meth.addStatement(reference('parseRow').call([result]).asReturn());
  }

  MethodBuilder buildUpdateMethod(PostgresBuildContext ctx) {
    var meth = new MethodBuilder('update',
        modifier: MethodModifier.asAsync,
        returnType: new TypeBuilder('Future',
            genericTypes: [new TypeBuilder(ctx.modelClassName)]));
    meth.addPositional(parameter('id', [lib$core.int]));
    meth.addPositional(
        parameter('connection', [new TypeBuilder('PostgreSQLConnection')]));
    _addAllNamed(meth, ctx);

    var buf = new StringBuffer('UPDATE "${ctx.tableName}" SET (');
    int i = 0;
    ctx.fields.forEach((field) {
      if (field.name == 'id')
        return;
      else {
        if (i++ > 0) buf.write(', ');
        var key = ctx.resolveFieldName(field.name);
        buf.write('"$key"');
      }
    });
    buf.write(') = (');
    i = 0;
    ctx.fields.forEach((field) {
      if (field.name == 'id')
        return;
      else {
        if (i++ > 0) buf.write(', ');
        buf.write('@${field.name}');
      }
    });
    buf.write(') WHERE "id" = @id');

    _addReturning(buf, ctx);
    _ensureDates(meth, ctx);
    var substitutionValues = _buildSubstitutionValues(ctx);
    substitutionValues.putIfAbsent('id', () => reference('id'));
    _executeQuery(buf, meth, substitutionValues);
    return meth;
  }

  MethodBuilder buildDeleteMethod(PostgresBuildContext ctx) {
    var meth = new MethodBuilder('delete',
        modifier: MethodModifier.asAsync,
        returnType: new TypeBuilder('Future',
            genericTypes: [new TypeBuilder(ctx.modelClassName)]))
      ..addPositional(parameter('id', [lib$core.int]))
      ..addPositional(
          parameter('connection', [new TypeBuilder('PostgreSQLConnection')]));

    var id = reference('id');
    var connection = reference('connection');
    var beforeDelete = reference('__ormBeforeDelete__');
    var result = reference('result');

    // var __ormBeforeDelete__ = await XQuery.getOne(id, connection);
    meth.addStatement(varField('__ormBeforeDelete__',
        value: new TypeBuilder(ctx.queryClassName)
            .invoke('getOne', [id, connection]).asAwait()));

    // await connection.execute('...');
    meth.addStatement(varField('result',
        value: connection.invoke('execute', [
          literal('DELETE FROM "${ctx.tableName}" WHERE id = @id LIMIT 1;')
        ], namedArguments: {
          'substitutionValues': map({'id': id})
        }).asAwait()));

    meth.addStatement(ifThen(result.notEquals(literal(1)), [
      lib$core.StateError.newInstance([
        literal('DELETE query deleted ') +
            result +
            literal(' row(s), instead of exactly 1 row.')
      ])
    ]));

    // return __ormBeforeDelete__
    meth.addStatement(beforeDelete.asReturn());
    return meth;
  }

  MethodBuilder buildInsertMethod(PostgresBuildContext ctx) {
    var meth = new MethodBuilder('insert',
        modifier: MethodModifier.asAsync,
        returnType: new TypeBuilder('Future',
            genericTypes: [new TypeBuilder(ctx.modelClassName)]));
    meth.addPositional(
        parameter('connection', [new TypeBuilder('PostgreSQLConnection')]));

    // Add all named params
    _addAllNamed(meth, ctx);

    var buf = new StringBuffer('INSERT INTO "${ctx.tableName}" (');
    int i = 0;
    ctx.fields.forEach((field) {
      if (field.name == 'id')
        return;
      else {
        if (i++ > 0) buf.write(', ');
        var key = ctx.resolveFieldName(field.name);
        buf.write('"$key"');
      }
    });

    buf.write(') VALUES (');
    i = 0;
    ctx.fields.forEach((field) {
      if (field.name == 'id')
        return;
      else {
        if (i++ > 0) buf.write(', ');
        buf.write('@${field.name}');
      }
    });

    buf.write(')');

    _addReturning(buf, ctx);
    // meth.addStatement(lib$core.print.call([literal(buf.toString())]));

    _ensureDates(meth, ctx);

    var substitutionValues = _buildSubstitutionValues(ctx);
    _executeQuery(buf, meth, substitutionValues);
    return meth;
  }

  ClassBuilder buildWhereClass(PostgresBuildContext ctx) {
    var clazz = new ClassBuilder(ctx.whereClassName);

    ctx.fields.forEach((field) {
      TypeBuilder queryBuilderType;
      List<ExpressionBuilder> args = [];

      switch (field.type.name) {
        case 'String':
          queryBuilderType = new TypeBuilder('StringSqlExpressionBuilder');
          break;
        case 'int':
          queryBuilderType = new TypeBuilder('NumericSqlExpressionBuilder',
              genericTypes: [lib$core.int]);
          break;
        case 'double':
          queryBuilderType = new TypeBuilder('NumericSqlExpressionBuilder',
              genericTypes: [new TypeBuilder('double')]);
          break;
        case 'num':
          queryBuilderType = new TypeBuilder('NumericSqlExpressionBuilder');
          break;
        case 'bool':
          queryBuilderType = new TypeBuilder('BooleanSqlExpressionBuilder');
          break;
        case 'DateTime':
          queryBuilderType = new TypeBuilder('DateTimeSqlExpressionBuilder');
          args.add(literal(ctx.resolveFieldName(field.name)));
          break;
      }

      if (queryBuilderType == null)
        throw 'Could not resolve query builder type for field "${field.name}" of type "${field.type.name}".';
      clazz.addField(varFinal(field.name,
          type: queryBuilderType, value: queryBuilderType.newInstance(args)));
    });

    // Create "toWhereClause()"
    var toWhereClause =
        new MethodBuilder('toWhereClause', returnType: lib$core.String);

    // List<String> expressions = [];
    toWhereClause.addStatement(varFinal('expressions',
        type: new TypeBuilder('List', genericTypes: [lib$core.String]),
        value: list([])));
    var expressions = reference('expressions');

    // Add all expressions...
    ctx.fields.forEach((field) {
      var name = ctx.resolveFieldName(field.name);
      var queryBuilder = reference(field.name);
      var toAdd = field.type.name == 'DateTime'
          ? queryBuilder.invoke('compile', [])
          : (literal('"$name" ') + queryBuilder.invoke('compile', []));

      toWhereClause.addStatement(ifThen(queryBuilder.property('hasValue'), [
        expressions.invoke('add', [toAdd])
      ]));
    });

    // return expressions.isEmpty ? null : ('WHERE ' + expressions.join(' AND '));
    toWhereClause.addStatement(expressions
        .property('isEmpty')
        .ternary(
            literal(null),
            (literal('WHERE ') + expressions.invoke('join', [literal(' AND ')]))
                .parentheses())
        .asReturn());

    clazz.addMethod(toWhereClause);

    return clazz;
  }
}