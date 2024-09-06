import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' show UnsignedChar, calloc;
import 'package:libusb/libusb.dart';

final DynamicLibrary Function() loadLibrary = () {
  if (Platform.isWindows) {
    return DynamicLibrary.open(
        '${Directory.current.path}/libusb-1.0/libusb-1.0.dll');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open(
        '${Directory.current.path}/libusb-1.0/libusb-1.0.dylib');
  } else if (Platform.isLinux) {
    return DynamicLibrary.open(
        '${Directory.current.path}/libusb-1.0/libusb-1.0.so');
  }
  throw 'libusb dynamic library not found';
};

final _libusb = Libusb(loadLibrary());

void main() {
  var deviceProductInfo = QuickUsb().getDeviceProductInfo();
  print('deviceProductInfo [${deviceProductInfo.entries.join(', ')}]');
}

class QuickUsb {
  Map<String, String> getDeviceProductInfo() {
    var init = _libusb.libusb_init(nullptr);
    if (init != libusb_error.LIBUSB_SUCCESS) {
      throw StateError('init error: ${_libusb.describeError(init)}');
    }

    var deviceListPtr = calloc<Pointer<Pointer<libusb_device>>>();
    try {
      var count = _libusb.libusb_get_device_list(nullptr, deviceListPtr);
      if (count < 0) {
        return {};
      }
      try {
        return Map.fromEntries(_iterateDeviceProduct(deviceListPtr.value));
      } finally {
        _libusb.libusb_free_device_list(deviceListPtr.value, 1);
      }
    } finally {
      calloc.free(deviceListPtr);
      _libusb.libusb_exit(nullptr);
    }
  }

  Iterable<MapEntry<String, String>> _iterateDeviceProduct(
      Pointer<Pointer<libusb_device>> deviceList) sync* {
    var descPtr = calloc<libusb_device_descriptor>();
    var devHandlePtr = calloc<Pointer<libusb_device_handle>>();
    final strDescLength = 42;
    var strDescPtr = calloc<UnsignedChar>(strDescLength);

    for (var i = 0; deviceList[i] != nullptr; i++) {
      var deviceProduct = _getDeviceProduct(
          deviceList[i], descPtr, devHandlePtr, strDescPtr, strDescLength);
      if (deviceProduct != null) yield deviceProduct;
    }

    calloc.free(descPtr);
    calloc.free(devHandlePtr);
    calloc.free(strDescPtr);
  }

  MapEntry<String, String>? _getDeviceProduct(
    Pointer<libusb_device> dev,
    Pointer<libusb_device_descriptor> descPtr,
    Pointer<Pointer<libusb_device_handle>> devHandlePtr,
    Pointer<UnsignedChar> strDescPtr,
    int strDescLength,
  ) {
    var devDesc = _libusb.libusb_get_device_descriptor(dev, descPtr);
    if (devDesc != libusb_error.LIBUSB_SUCCESS) {
      print('devDesc error: ${_libusb.describeError(devDesc)}');
      return null;
    }
    var idVendor = descPtr.ref.idVendor.toRadixString(16).padLeft(4, '0');
    var idProduct = descPtr.ref.idProduct.toRadixString(16).padLeft(4, '0');
    var idDevice = '$idVendor:$idProduct';

    if (descPtr.ref.iProduct == 0) {
      print('$idDevice iProduct empty');
      return MapEntry(idDevice, '');
    }

    var open = _libusb.libusb_open(dev, devHandlePtr);
    if (open != libusb_error.LIBUSB_SUCCESS) {
      print('$idDevice open error: ${_libusb.describeError(open)}');
      return MapEntry(idDevice, '');
    }
    var devHandle = devHandlePtr.value;

    try {
      var langDesc = _libusb.inline_libusb_get_string_descriptor(
          devHandle, 0, 0, strDescPtr, strDescLength);
      if (langDesc < 0) {
        print('$idDevice langDesc error: ${_libusb.describeError(langDesc)}');
        return MapEntry(idDevice, '');
      }
      var langId = strDescPtr[2] << 8 | strDescPtr[3];

      var prodDesc = _libusb.inline_libusb_get_string_descriptor(
          devHandle, descPtr.ref.iProduct, langId, strDescPtr, strDescLength);
      if (prodDesc < 0) {
        print('$idDevice prodDesc error: ${_libusb.describeError(prodDesc)}');
        return MapEntry(idDevice, '');
      }
      return MapEntry(idDevice, utf8.decode(strDescPtr.cast<Uint8>().asTypedList(prodDesc)));
    } finally {
      _libusb.libusb_close(devHandle);
    }
  }
}

const int _kMaxSmi64 = (1 << 62) - 1;
const int _kMaxSmi32 = (1 << 30) - 1;
final int _maxSize = sizeOf<IntPtr>() == 8 ? _kMaxSmi64 : _kMaxSmi32;

extension LibusbExtension on Libusb {
  String describeError(int error) {
    var array = _libusb.libusb_error_name(error);
    // FIXME array is Pointer<Char>, not Pointer<Uint8>
    var nativeString = array.cast<Uint8>().asTypedList(_maxSize);
    var strlen = nativeString.indexWhere((char) => char == 0);
    return utf8.decode(array.cast<Uint8>().asTypedList(strlen));
  }
}

extension LibusbInline on Libusb {
  /// [libusb_get_string_descriptor]
  int inline_libusb_get_string_descriptor(
    Pointer<libusb_device_handle> dev_handle,
    int desc_index,
    int langid,
    Pointer<UnsignedChar> data,
    int length,
  ) {
    return libusb_control_transfer(
      dev_handle,
      libusb_endpoint_direction.LIBUSB_ENDPOINT_IN.value,
      libusb_standard_request.LIBUSB_REQUEST_GET_DESCRIPTOR.value,
      libusb_descriptor_type.LIBUSB_DT_STRING.value << 8 | desc_index,
      langid,
      data,
      length,
      1000,
    );
  }
}
