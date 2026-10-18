import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Modelo del dispositivo SIN plugins (`meta.device.model`).
///
/// - Simulador de iOS: `SIMULATOR_MODEL_IDENTIFIER` (`iPhone17,1`) si el
///   proceso lo heredó; con `flutter run` no, así que se lee el nombre del
///   tipo de dispositivo del `device.plist` del simulador (el binario vive
///   bajo `CoreSimulator/Devices/<udid>/`): `iPhone 16 Pro`.
/// - iPhone/iPad/Mac reales: `sysctlbyname("hw.machine")` por FFI
///   (`iPhone17,1`).
/// - Android y el resto: `null` (exige un canal de plataforma; la app lo
///   pasa con `Thor.run(deviceInfo: {'model': …})`).
///
/// Corre UNA vez al arrancar, nunca lanza y nunca por frame.
class DeviceModel {
  DeviceModel._();

  /// El modelo de este dispositivo, o `null` si no se pudo saber.
  static String? detect({
    Map<String, String>? environment,
    String? executable,
    bool? isIos,
    bool? isMacOs,
  }) {
    try {
      final env = environment ?? Platform.environment;
      final ios = isIos ?? Platform.isIOS;
      final mac = isMacOs ?? Platform.isMacOS;
      if (!ios && !mac) return null;
      final exe = executable ?? Platform.resolvedExecutable;
      if (ios && exe.contains('/CoreSimulator/Devices/')) {
        final id = env['SIMULATOR_MODEL_IDENTIFIER'];
        if (id != null && id.isNotEmpty) return id;
        return _simulatorFromPlist(exe);
      }
      // iOS: `iPhone17,1`. En Mac `hw.machine` es solo `arm64`: `hw.model`.
      return ios ? _sysctlString('hw.machine') : _sysctlString('hw.model');
    } on Object {
      return null;
    }
  }

  /// Nombre legible (`iPhone 16 Pro`) del `device.plist` del simulador.
  static String? _simulatorFromPlist(String executable) {
    final i = executable.indexOf('/CoreSimulator/Devices/');
    final rest = executable.substring(i + '/CoreSimulator/Devices/'.length);
    final udid = rest.split('/').first;
    if (udid.isEmpty) return null;
    final file = File(
      '${executable.substring(0, i)}/CoreSimulator/Devices/$udid/device.plist',
    );
    if (!file.existsSync()) return null;
    return modelFromDevicePlist(file.readAsStringSync());
  }

  /// Extrae el modelo de un `device.plist` XML de simulador:
  /// `…SimDeviceType.iPhone-16-Pro` → `iPhone 16 Pro`. Visible para tests.
  @visibleForTesting
  static String? modelFromDevicePlist(String xml) {
    final match = RegExp(
      r'<key>deviceType</key>\s*<string>([^<]+)</string>',
    ).firstMatch(xml);
    final type = match?.group(1);
    if (type == null) return null;
    final name = type.split('.').last.replaceAll('-', ' ').trim();
    return name.isEmpty ? null : name;
  }

  /// `sysctlbyname(name)` como texto, por FFI sobre libc (sin paquetes).
  static String? _sysctlString(String name) {
    final lib = DynamicLibrary.process();
    final malloc = lib.lookupFunction<Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)>('malloc');
    final free = lib.lookupFunction<Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)>('free');
    final sysctl = lib.lookupFunction<
        Int32 Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<IntPtr>,
          Pointer<Uint8>,
          IntPtr,
        ),
        int Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<IntPtr>,
          Pointer<Uint8>,
          int,
        )>('sysctlbyname');
    const capacity = 128;
    final nameBytes = name.codeUnits;
    final namePtr = malloc(nameBytes.length + 1);
    final out = malloc(capacity);
    final len = malloc(sizeOf<IntPtr>()).cast<IntPtr>();
    try {
      for (var i = 0; i < nameBytes.length; i++) {
        namePtr[i] = nameBytes[i];
      }
      namePtr[nameBytes.length] = 0;
      len.value = capacity;
      final rc = sysctl(namePtr, out, len, nullptr.cast<Uint8>(), 0);
      if (rc != 0) return null;
      final n = len.value;
      final bytes = [
        for (var i = 0; i < n && i < capacity; i++)
          if (out[i] != 0) out[i],
      ];
      final text = String.fromCharCodes(bytes).trim();
      return text.isEmpty ? null : text;
    } finally {
      free(namePtr);
      free(out);
      free(len.cast<Uint8>());
    }
  }
}
