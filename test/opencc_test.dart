import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/opencc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(OpenCC.init);

  test('detects arbitrary simplified Chinese search terms', () {
    expect(OpenCC.hasChineseSimplified('漫画'), isTrue);
    expect(OpenCC.simplifiedToTraditional('漫画'), '漫畫');
  });

  test('detects and converts traditional Chinese search terms', () {
    expect(OpenCC.hasChineseTraditional('漫畫'), isTrue);
    expect(OpenCC.traditionalToSimplified('漫畫'), '漫画');
  });

  test('does not report text without convertible characters', () {
    expect(OpenCC.hasChineseSimplified('manga 123'), isFalse);
    expect(OpenCC.hasChineseTraditional('manga 123'), isFalse);
  });
}
