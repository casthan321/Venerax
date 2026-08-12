import 'dart:typed_data';

const _gif87aSignature = <int>[0x47, 0x49, 0x46, 0x38, 0x37, 0x61];
const _gif89aSignature = <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61];

/// Whether [bytes] starts with a GIF87a or GIF89a header.
///
/// Image modification scripts currently decode and re-encode only one frame,
/// so animated GIF data must bypass that static-image pipeline.
bool isGifImage(Uint8List bytes) {
  return _hasSignature(bytes, _gif87aSignature) ||
      _hasSignature(bytes, _gif89aSignature);
}

bool _hasSignature(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) {
    return false;
  }
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) {
      return false;
    }
  }
  return true;
}
