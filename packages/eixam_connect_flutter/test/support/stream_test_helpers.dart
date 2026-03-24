import 'package:async/async.dart';

Future<T> takeNextFromStream<T>(Stream<T> stream) async {
  final queue = StreamQueue<T>(stream);
  try {
    return await queue.next;
  } finally {
    await queue.cancel();
  }
}
