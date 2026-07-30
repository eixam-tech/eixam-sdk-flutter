import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  final packageRoot = _packageRoot();
  final repositoryRoot = packageRoot.parent.parent;
  final privacyManifests = repositoryRoot
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where(
        (file) =>
            file.path.endsWith('PrivacyInfo.xcprivacy') &&
            !file.path.contains(
                '${Platform.pathSeparator}build${Platform.pathSeparator}') &&
            !file.path.contains(
              '${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}',
            ),
      )
      .toList();
  final pluginManifest = File(
    '${packageRoot.path}/ios/PrivacyInfo.xcprivacy',
  );

  test('every active SDK privacy manifest is a valid structured plist', () {
    expect(privacyManifests, isNotEmpty);
    for (final manifest in privacyManifests) {
      final document = XmlDocument.parse(manifest.readAsStringSync());
      expect(document.rootElement.name.local, 'plist');
      expect(document.rootElement.childElements.single.name.local, 'dict');
    }
  });

  test('packaged iOS manifest omits Contacts and preserves valid declarations',
      () {
    final root = _plistDictionary(pluginManifest);
    final collectedData = _dictionaryArray(
      root['NSPrivacyCollectedDataTypes'],
    );
    final collectedTypes = collectedData
        .map((entry) => entry['NSPrivacyCollectedDataType']?.innerText)
        .toSet();

    expect(
      collectedTypes,
      equals(<String>{
        'NSPrivacyCollectedDataTypePreciseLocation',
        'NSPrivacyCollectedDataTypeCoarseLocation',
        'NSPrivacyCollectedDataTypeUserID',
        'NSPrivacyCollectedDataTypeDeviceID',
        'NSPrivacyCollectedDataTypeOtherDiagnosticData',
      }),
    );
    expect(
      collectedTypes,
      isNot(contains('NSPrivacyCollectedDataTypeContacts')),
    );
    for (final declaration in collectedData) {
      expect(
        declaration['NSPrivacyCollectedDataTypeLinked']?.name.local,
        'true',
      );
      expect(
        declaration['NSPrivacyCollectedDataTypeTracking']?.name.local,
        'false',
      );
      expect(
        declaration['NSPrivacyCollectedDataTypePurposes']
            ?.descendantElements
            .where((element) => element.name.local == 'string')
            .map((element) => element.innerText),
        contains('NSPrivacyCollectedDataTypePurposeAppFunctionality'),
      );
    }
    expect(root['NSPrivacyTracking']?.name.local, 'false');
  });

  test('required-reason API declaration remains unchanged', () {
    final root = _plistDictionary(pluginManifest);
    final accessedApis = _dictionaryArray(root['NSPrivacyAccessedAPITypes']);

    expect(accessedApis, hasLength(1));
    expect(
      accessedApis.single['NSPrivacyAccessedAPIType']?.innerText,
      'NSPrivacyAccessedAPICategoryUserDefaults',
    );
    expect(
      accessedApis.single['NSPrivacyAccessedAPITypeReasons']?.descendantElements
          .where((element) => element.name.local == 'string')
          .map((element) => element.innerText),
      orderedEquals(<String>['CA92.1']),
    );
  });

  test('podspec packages the authoritative privacy manifest', () {
    final podspec = File(
      '${packageRoot.path}/ios/eixam_connect_flutter.podspec',
    ).readAsStringSync();

    expect(podspec, contains('s.resource_bundles'));
    expect(
      podspec,
      contains(
        "'eixam_connect_flutter_privacy' => ['PrivacyInfo.xcprivacy']",
      ),
    );
  });

  test('SDK sources, manifests, and dependencies do not access address books',
      () {
    final auditRoots = <FileSystemEntity>[
      Directory('${repositoryRoot.path}/packages/eixam_connect_core/lib'),
      File('${repositoryRoot.path}/packages/eixam_connect_core/pubspec.yaml'),
      Directory('${packageRoot.path}/lib'),
      Directory('${packageRoot.path}/ios/Classes'),
      Directory('${packageRoot.path}/android/src'),
      Directory('${packageRoot.path}/example/lib'),
      File('${packageRoot.path}/pubspec.yaml'),
      File('${packageRoot.path}/pubspec.lock'),
      Directory('${repositoryRoot.path}/packages/eixam_connect_ui/lib'),
      File('${repositoryRoot.path}/packages/eixam_connect_ui/pubspec.yaml'),
    ];
    final auditedFiles = auditRoots.expand(_sourceFiles);
    const forbidden = <String>[
      'ContactsUI',
      'CNContact',
      'CNContactStore',
      'CNContactPicker',
      'ABAddressBook',
      'NSContactsUsageDescription',
      'READ_CONTACTS',
      'WRITE_CONTACTS',
      'ContactsContract',
      'contacts_service',
      'flutter_contacts',
      'fast_contacts',
      'contact_picker',
    ];

    for (final file in auditedFiles) {
      final contents = file.readAsStringSync();
      for (final token in forbidden) {
        expect(
          contents,
          isNot(contains(token)),
          reason: '${file.path} must not introduce $token',
        );
      }
    }
  });

  test('all SDK packages remain at version 0.3.0', () {
    for (final package in const <String>[
      'eixam_connect_core',
      'eixam_connect_flutter',
      'eixam_connect_ui',
    ]) {
      final pubspec = File(
        '${repositoryRoot.path}/packages/$package/pubspec.yaml',
      ).readAsStringSync();
      expect(
        RegExp(r'^version:\s*0\.3\.0\s*$', multiLine: true).hasMatch(pubspec),
        isTrue,
        reason: '$package must remain at 0.3.0',
      );
    }
  });
}

Directory _packageRoot() {
  final current = Directory.current;
  if (current.path.endsWith('eixam_connect_flutter')) {
    return current;
  }
  return Directory('packages/eixam_connect_flutter').absolute;
}

Map<String, XmlElement> _plistDictionary(File plist) {
  final document = XmlDocument.parse(plist.readAsStringSync());
  return _dictionary(document.rootElement.childElements.single);
}

List<Map<String, XmlElement>> _dictionaryArray(XmlElement? array) {
  expect(array, isNotNull);
  expect(array!.name.local, 'array');
  return array.childElements.map(_dictionary).toList(growable: false);
}

Map<String, XmlElement> _dictionary(XmlElement element) {
  expect(element.name.local, 'dict');
  final children = element.childElements.toList(growable: false);
  expect(children.length.isEven, isTrue);
  final result = <String, XmlElement>{};
  for (var index = 0; index < children.length; index += 2) {
    expect(children[index].name.local, 'key');
    result[children[index].innerText] = children[index + 1];
  }
  return result;
}

Iterable<File> _sourceFiles(FileSystemEntity entity) sync* {
  if (entity is File) {
    yield entity;
    return;
  }
  if (entity is! Directory) {
    return;
  }
  for (final child in entity.listSync(recursive: true, followLinks: false)) {
    if (child is File) {
      yield child;
    }
  }
}
