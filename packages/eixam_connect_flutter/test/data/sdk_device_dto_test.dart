import 'package:eixam_connect_flutter/src/data/dtos/sdk_device_dto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses snake_case registry payloads', () {
    final dto = SdkDeviceDto.fromJson(<String, dynamic>{
      'id': 'device-1',
      'hardware_id': ' 305419896 ',
      'firmware_version': '2.7.37',
      'hardware_model': 'EIXAM R1',
      'paired_at': '2026-01-01T00:00:00Z',
    });

    expect(dto.hardwareId, '305419896');
    expect(dto.firmwareVersion, '2.7.37');
  });

  test('parses camelCase registry payloads', () {
    final dto = SdkDeviceDto.fromJson(<String, dynamic>{
      'id': 'device-1',
      'hardwareId': '305419896',
      'firmwareVersion': '2.7.37',
      'hardwareModel': 'EIXAM R1',
      'pairedAt': '2026-01-01T00:00:00Z',
    });

    expect(dto.id, 'device-1');
    expect(dto.hardwareId, '305419896');
    expect(dto.pairedAt, '2026-01-01T00:00:00Z');
  });

  test('accepts numeric hardware ids', () {
    final dto = SdkDeviceDto.fromJson(<String, dynamic>{
      'id': 12,
      'hardware_id': 305419896,
    });

    expect(dto.id, '12');
    expect(dto.hardwareId, '305419896');
  });

  test('accepts hardware id without firmware metadata', () {
    final dto = SdkDeviceDto.fromJson(<String, dynamic>{
      'hardware_id': '305419896',
    });

    expect(dto.id, '305419896');
    expect(dto.hardwareId, '305419896');
    expect(dto.firmwareVersion, 'unknown');
    expect(dto.hardwareModel, 'EIXAM R1');
  });
}
