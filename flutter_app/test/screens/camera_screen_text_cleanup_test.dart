import 'package:app/services/tts/thai_tts_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('softens Thai filler phrases without forcing a template', () {
    expect(
      cleanThaiTtsText(
        'ฉากที่มีคน 2 คนเดินผ่านสิ่งที่ดูเหมือนเป็นพื้นที่ในอาคาร อาจเป็นร้านค้าหรือตลาด',
      ),
      'ฉากที่มีคน 2 คนเดินผ่านที่น่าจะเป็นพื้นที่ในอาคาร อาจเป็นร้านค้าหรือตลาด',
    );
  });

  test('trims long Thai explanatory tails for TTS', () {
    expect(
      cleanThaiTtsText(
        'หน้าจอคอมพิวเตอร์ที่แสดงซอฟต์แวร์แก้ไขรูปภาพที่เปิดอยู่โดยมีแถบเมนูมองเห็นได้ ซึ่งบ่งชี้ว่ามีการใช้เพื่อแก้ไขหรือปรับแต่งรูปภาพ',
      ),
      'หน้าจอคอมพิวเตอร์ที่แสดงซอฟต์แวร์แก้ไขรูปภาพที่เปิดอยู่มีแถบเมนูมองเห็นได้',
    );
  });

  test('keeps shorter natural Thai descriptions intact', () {
    expect(
      cleanThaiTtsText('ทางข้างหน้าโล่ง'),
      'ทางข้างหน้าโล่ง',
    );
  });

  test('softens background wording into walking context', () {
    expect(
      cleanThaiTtsText('มีจักรยานจอดอยู่ในพื้นหลัง'),
      'มีจักรยานจอดอยู่ถัดออกไป',
    );
  });

  test('softens behind wording into walking context', () {
    expect(
      cleanThaiTtsText('คนขี่จักรยานบนเส้นทางเปิดโล่ง มีต้นไม้และคนอื่นๆ อยู่เบื้องหลัง'),
      'คนขี่จักรยานบนเส้นทางเปิดโล่ง มีต้นไม้และคนอื่นๆ อยู่ถัดออกไป',
    );
  });
}
