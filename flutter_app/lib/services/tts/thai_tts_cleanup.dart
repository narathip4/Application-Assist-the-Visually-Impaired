String cleanThaiTtsText(String text) {
  var out = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (out.isEmpty) return out;

  out = out.replaceAll(RegExp(r'สิ่งที่ดูเหมือน(?:จะ)?เป็น'), 'ที่น่าจะเป็น');
  out = out.replaceAll(RegExp(r'ดูเหมือน(?:จะ)?เป็น'), 'น่าจะเป็น');
  out = out.replaceAll(RegExp(r'ซึ่งบ่งชี้ว่า'), 'และน่าจะ');
  out = out.replaceAll(RegExp(r'ซึ่งบ่งบอกว่า'), 'และน่าจะ');
  out = out.replaceAll(RegExp(r'บ่งชี้ว่า'), 'น่าจะ');
  out = out.replaceAll(RegExp(r'บ่งบอกว่า'), 'น่าจะ');
  out = out.replaceAll(RegExp(r'รวมถึง'), 'มี');
  out = out.replaceAll(RegExp(r'โดยมี'), 'มี');
  out = out.replaceAll(RegExp(r'อยู่ในพื้นหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'อยู่ที่พื้นหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'ในพื้นหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'ที่พื้นหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'ในฉากหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'ที่ฉากหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'เป็นฉากหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'อยู่เบื้องหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'อยู่ในเบื้องหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'ในเบื้องหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'ที่เบื้องหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'เป็นเบื้องหลัง'), 'อยู่ถัดออกไป');
  out = out.replaceAll(RegExp(r'อยู่ทั้งสองข้าง'), 'อยู่สองข้าง');
  out = out.replaceAll(RegExp(r'เรียงรายอยู่สองข้าง'), 'เรียงรายสองข้าง');

  if (out.length > 90) {
    for (final marker in const <String>[
      ' และน่าจะ',
      ' ซึ่งน่าจะ',
      ' โดยมี',
      ' รวมถึง',
      ' ซึ่ง',
    ]) {
      final idx = out.indexOf(marker);
      if (idx > 30) {
        out = out.substring(0, idx).trim();
        break;
      }
    }
  }

  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}
