/// Retries a function until it passes without throwing an exception.
Future waitForFunctionToPass(
  Future Function() function, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  while (true) {
    try {
      await function();
      return;
    } catch (_) {
      if (stopwatch.elapsed + const Duration(milliseconds: 10) > timeout) {
        rethrow;
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }
}
