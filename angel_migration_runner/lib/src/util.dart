import 'dart:async';
import 'dart:isolate';
import 'dart:mirrors';

Future<String> absoluteSourcePath(Type type) async {
  var mirror = reflectType(type);
  var uri = mirror.location.sourceUri;

  if (uri.scheme == 'package') {
    uri = await Isolate.resolvePackageUri(uri);
  }
  if (uri == null) {
    return type.toString();
  }      
  return uri.toFilePath() + '#' + MirrorSystem.getName(mirror.simpleName);
}
