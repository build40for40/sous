import 'package:flutter_test/flutter_test.dart';
import 'package:sous/voice/sentences.dart';

void main() {
  test('gives back sentences as soon as they finish', () {
    final splitter = SentenceSplitter();
    expect(splitter.add('Right, heat the'), isEmpty);
    expect(splitter.add(' pan. Add 2.5 g of'), ['Right, heat the pan.']);
    expect(splitter.add(' salt! Then stir'), ['Add 2.5 g of salt!']);
    expect(splitter.flush(), 'Then stir');
    expect(splitter.flush(), isNull);
  });

  test('cuts a run-on sentence at a comma', () {
    final splitter = SentenceSplitter(maxLength: 30);
    expect(splitter.add('Chop the onions, the garlic and the ginger'), [
      'Chop the onions,',
    ]);
    expect(splitter.flush(), 'the garlic and the ginger');
  });

  test('clear drops what is pending', () {
    final splitter = SentenceSplitter()..add('Half a sente');
    splitter.clear();
    expect(splitter.flush(), isNull);
  });
}
