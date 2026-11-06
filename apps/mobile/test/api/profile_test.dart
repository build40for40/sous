import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/profile.dart';

void main() {
  test('reads preferences, about and what Sou learned', () {
    final profile = Profile.fromJson({
      'id': 'user_fake01',
      'preferences': {
        'diet': 'vegetarian',
        'allergies': ['peanuts'],
      },
      'about': 'Cooks for two.',
      'learned': ['hates coriander', 'likes eggs runny'],
      'updated_at': '2026-11-06T18:00:00Z',
    });

    expect(profile.preferences['allergies'], ['peanuts']);
    expect(profile.about, 'Cooks for two.');
    expect(profile.learned, ['hates coriander', 'likes eggs runny']);
  });

  test('learned is empty when Sou has nothing yet', () {
    final profile = Profile.fromJson({
      'id': 'user_fake01',
      'preferences': {},
      'about': '',
      'learned': [],
      'updated_at': '2026-11-06T18:00:00Z',
    });

    expect(profile.learned, isEmpty);
  });
}
