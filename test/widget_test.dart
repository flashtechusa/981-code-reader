// Committed so `flutter create .` (run in CI to generate the platform folders)
// does not drop in its template widget_test.dart, which references a `MyApp`
// class this project does not have. Real tests live in core_test.dart.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder - see core_test.dart', () {
    expect(true, isTrue);
  });
}
