import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  test('loading dialog controller closes safely before route attachment', () {
    final controller = LoadingDialogController();

    expect(controller.close, returnsNormally);
    expect(controller.closed, isTrue);
    expect(controller.close, returnsNormally);
  });
}
