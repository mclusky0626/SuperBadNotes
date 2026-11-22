# BadNotes

굿노트너무비싸고  
아이패드너무구리고  
나는거지다  
그래서만들었다  
앱도 거지같다

---

- iPad용 PDF 필기 앱 (SwiftUI + PDFKit + PencilKit), iPadOS 17 이상
- 가져온 PDF는 앱 폴더로 복사하고, **필기는 그 PDF 안에 저장** → 파일 앱·미리보기·다른 PDF 앱에서도 필기가 보임
- 파일 앱 › 나의 iPad › BadNotes 에 PDF가 그대로 보임
- 오류 나면 빨간 배너 + 로그 창
- 스크롤하면 상단 바 숨김, 제목 누르면 페이지 이동

## 저장 방식 (`BadNotes/Storage/`)
- 페이지마다 Stamp 주석 하나에 필기를 넣음
  - 보이는 모양: 벡터 appearance stream (PDFKit이 저장할 때 `InkAnnotation.draw`로 기록) → 다른 앱용
  - 편집용 원본: `/BNInk`(PKDrawing, LZFSE + base64), `/BNMeta`(형식 버전 + 저장 당시 페이지 좌표계)
  - 다른 앱이 페이지를 돌리거나 잘라도 `/BNMeta`로 필기 위치를 맞춰 줌
- 획이 바뀌면 0.4초 뒤 복구 기록(`Application Support/BadNotes/Journal`), 몇 초 모아서 PDF 저장(백그라운드)
  - PDF 저장: 임시 파일에 쓰고 → 다시 열어 검증 → 원본과 원자적으로 교체. 실패하면 원본 그대로, 복구 기록 유지, 재시도
  - 앱이 죽어도 다음에 열 때 복구 기록에서 되살림
- 문서를 연 뒤 첫 저장 전에 백업(`Application Support/BadNotes/Backups`, 문서당 최근 5개)
- 옛 방식(`<파일이름>.notes/pageN.drawing`)은 앱 시작할 때 PDF 안으로 자동으로 옮김. 옮기기 전 PDF는 영구 백업, 옛 폴더는 `Migrated/`로 보관
- 디버그 빌드 자체 점검: `xcrun simctl launch --console-pty booted com.geonu9xpy.BadNotes -BNSelfTest`

## 알려진 문제
- 마지막 페이지 끝까지 스크롤하면 상단 바가 숨었다 나왔다 하면서 버벅이다 멈춤
- 다른 앱에서 보이는 필기 모양은 근사치 (연필 질감은 투명도로, 반투명 잉크는 획마다 평균 굵기로)
- 암호 걸린 PDF는 아직 못 엶

## 빌드
Xcode로 `BadNotes.xcodeproj` 열고 Signing에서 본인 팀 골라서 실행.
