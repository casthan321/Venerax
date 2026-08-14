import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';

void main() {
  const key = 'generation_test_source';

  setUp(() {
    ComicSourceManager().remove(key);
  });

  tearDown(() {
    ComicSourceManager().remove(key);
  });

  test('a delayed callback from a replaced JS generation is rejected', () {
    final oldSource = _source(key, 'old-generation')..data['secret'] = 'old';
    ComicSourceManager().add(oldSource);

    ComicSourceManager().remove(key);
    final newSource = _source(key, 'new-generation')..data['secret'] = 'new';
    ComicSourceManager().add(newSource);

    expect(
      () => JsEngine().receiveComicSourceMessageForTesting({
        'method': 'load_data',
        'key': key,
        'generation': 'old-generation',
        'data_key': 'secret',
      }),
      throwsA(isA<ComicSourceGenerationExpiredException>()),
    );
    expect(
      () => JsEngine().receiveComicSourceMessageForTesting({
        'method': 'save_data',
        'key': key,
        'generation': 'old-generation',
        'data_key': 'secret',
        'data': 'leaked-old-value',
      }),
      throwsA(isA<ComicSourceGenerationExpiredException>()),
    );
    expect(newSource.data['secret'], 'new');
    expect(
      JsEngine().receiveComicSourceMessageForTesting({
        'method': 'load_data',
        'key': key,
        'generation': 'new-generation',
        'data_key': 'secret',
      }),
      'new',
    );
  });

  test('an old runtime callback cannot enter the replacement generation', () {
    final oldSource = _source(key, 'old-generation');
    ComicSourceManager().add(oldSource);
    var replacementInvoked = false;
    void oldCallback() {
      ComicSource.requireGeneration(key, 'old-generation');
      replacementInvoked = true;
    }

    ComicSourceManager().remove(key);
    ComicSourceManager().add(_source(key, 'new-generation'));

    expect(oldCallback, throwsA(isA<ComicSourceGenerationExpiredException>()));
    expect(replacementInvoked, isFalse);
  });

  test('runtime callbacks bind and verify the exact JS source generation', () {
    final guarded = buildComicSourceRuntimeInvocation(
      key: key,
      generation: 'old-generation',
      invocation: 'ComicSource.sources.$key.comic.sendComment("comic", null)',
    );

    expect(guarded, contains('ComicSource.sources["$key"]'));
    expect(guarded, contains('__veneraGeneration !== "old-generation"'));
    expect(guarded, contains('source.comic.sendComment("comic", null)'));
    expect(
      guarded,
      isNot(contains('ComicSource.sources.$key.comic.sendComment')),
    );
  });

  test('runtime binding does not rewrite encoded callback arguments', () {
    final guarded = buildComicSourceRuntimeInvocation(
      key: key,
      generation: 'old-generation',
      invocation: 'ComicSource.sources.$key.search("ComicSource.sources.$key")',
    );

    expect(guarded, contains('source.search("ComicSource.sources.$key")'));
  });
}

ComicSource _source(String key, String generation) {
  return ComicSource(
    'Generation test source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
    generation: generation,
  );
}
