import 'dart:async';
import 'dart:io';

import 'package:yaml/yaml.dart' as yaml;
import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/ast/standard_ast_factory.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:build/build.dart';
import 'package:code_health/src/code_transfer/code_node.dart';
import 'package:build_resolvers/src/resolver.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/ast/utilities.dart' show NodeReplacer;
import 'package:dart_style/dart_style.dart';

abstract class Action{
  int get priority;
  Future execute(Project project, AssetId assetId);

  @override
  String toString() {
    return '${this.runtimeType}';
  }
}

class _ChangeExportImportAction extends Action {
  static final dartFormatter = new DartFormatter();
  final int priority = 1;
  final Map<AssetId,AssetId> _replaceTo = <AssetId,AssetId>{};
  void replace(AssetId source, AssetId dest){
    _replaceTo[source] = dest;
  }
  _ChangeExportImportAction();
  @override
  Future execute(Project project, AssetId assetId) async{
    var fileNode = project.getOrCreatePackage(assetId.package).files[assetId];
    var compilationUnit = AstCloner.clone(fileNode.compilationUnit);
    (compilationUnit as CompilationUnit).directives.forEach((directive){
      if (directive is NamespaceDirective){
        var source = directive.uriSource;
        if (source is AssetBasedSource) {
          AssetId replaceAssetId = _replaceTo[source.assetId];
          if (replaceAssetId != null) {
            var importStr = '\'${replaceAssetId.uri.toString()}\'';
            var newUri = astFactory.simpleStringLiteral(
                new StringToken(TokenType.STRING, importStr, 0), importStr);
            directive.accept(new NodeReplacer(directive.uri, newUri));
          }
        }
      }
    });
    fileNode.compilationUnit = compilationUnit;
    var f = new File(path.join(project.packageGraph.allPackages[fileNode.assetId.package].path,fileNode.assetId.path));
    var source = fileNode.compilationUnit.toSource();
    await f.writeAsString(dartFormatter.format(source));
  }

}

class ChangeImportAction extends _ChangeExportImportAction{
  ChangeImportAction();
}

class ChangeExportAction extends _ChangeExportImportAction{
  ChangeExportAction();
}

class MoveFileAction extends Action{
  final int priority = 10;
  final AssetId source;
  final AssetId dest;
  MoveFileAction(this.source, this.dest);

  @override
  Future execute(Project project, AssetId assetId) async{
    var sourceFile = new File(path.join(project.packageGraph.allPackages[assetId.package].path,assetId.path));
    String destFilePath;
    if (project.packageGraph.allPackages[assetId.package] != null){
      destFilePath = path.join(project.packageGraph.allPackages[assetId.package].path,assetId.path);
    } else {
      destFilePath = path.join(project.outputPackagesPath, assetId.package, assetId.path);
    }
    var destFile = new File(destFilePath);
    var destDir = new Directory(path.dirname(destFilePath));
    if (!destDir.existsSync()){
      destDir.createSync();
    }
    await destFile.writeAsBytes(await sourceFile.readAsBytes());
    await sourceFile.delete();
  }
}

class ChangePubspec extends Action{
  final Set<String> newDependencies = new Set<String>();

  void addDependence(String package){
    newDependencies.add(package);
  }

  @override
  Future execute(Project project, AssetId assetId) async{
    var f = new File(path.join(project.packageGraph.allPackages[assetId.package].path,assetId.path));
    var content = await f.readAsString();
    yaml.YamlMap yamlMap = yaml.loadYaml(content);
    var dependencies = yamlMap.nodes['dependencies'] as yaml.YamlMap;
    newDependencies.removeWhere((package)=> dependencies.containsKey(package));
    if (newDependencies.isNotEmpty) {
      StringBuffer sb = new StringBuffer(content.substring(0, dependencies.span.end.offset));
      sb.writeln();
      var column = dependencies.nodes.keys.first.span.start.column;
      newDependencies.forEach((packageName) {
        var newPackagePath = path.join(project.outputPackagesPath, packageName);
        var modPackagePath = path.relative(
            newPackagePath, from: project.packageGraph.allPackages[assetId.package].path);
        sb.writeln('${''.padLeft(column)}$packageName:');
        sb.writeln('${''.padLeft(column + 3)}path: "${modPackagePath}"');
      });
      sb.writeln(content.substring(dependencies.span.end.offset));
      await f.writeAsString(sb.toString());
    }
  }

  final int priority = 9;

}