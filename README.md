# BadNotes

굿노트너무비싸고  
아이패드너무구리고  
나는거지다  
그래서만들었다  
앱도 거지같다

---

- iPad용 PDF 필기 앱 (SwiftUI + PDFKit + PencilKit), iPadOS 26 이상 (Liquid Glass)
- 첫 화면은 **서재**: 노트북·PDF를 카드로 고름. [+ 신규]로 노트북 만들기 / PDF 불러오기 / 폴더
- 노트북도 PDF. 가져온 PDF는 앱 폴더로 복사하고, **필기는 그 PDF 안에 저장** → 파일 앱·미리보기·다른 PDF 앱에서도 필기가 보임
- 파일 앱 › 나의 iPad › BadNotes 에 PDF가 그대로 보임
- 오류 나면 빨간 배너 + 로그 창
- 스크롤하면 도구 막대 숨김, 아래 제목 캡슐 누르면 페이지 이동

## 필기 방식 (설정에서 고름)
- **직접 필기 (기본, `Editor/Direct/`)**: PDFView 대신 직접 만든 보기 화면
  - 페이지마다 PDF 타일 + 필기 타일(CATiledLayer). 확대 배율에 맞춰 조각마다 다시 그려서 아무리 확대해도 선명
  - 지금 긋는 획은 화면 좌표 임시 레이어에, 펜을 떼면 페이지 필기에 넣고 바뀐 영역만 다시 그림
  - 화면 필기와 PDF에 넣는 모양이 같은 렌더러(`Storage/InkRenderer.swift`) → 보이는 그대로 다른 앱에서도 보임
  - 도구: 펜(볼펜·만년필·붓펜·연필), 형광펜, 지우개(부분·획), 올가미(옮기기·복제·색 바꾸기·삭제), 실행 취소/다시 실행
  - 형광펜: 방향과 상관없이 같은 굵기, 반투명 곱하기(밑의 글자 그대로). 거의 곧게 그으면 곧게, 수평 3° 안이면 수평으로 (설정에서 끌 수 있음)
  - 펜을 뗄 때: 타일이 새로 그린 영역만큼 임시 획을 지워서 깜빡이거나 진해지지 않음
  - 손가락: 스크롤·확대 / 펜슬: 필기. 두 손가락 탭 실행 취소, 세 손가락 탭 다시 실행, 펜슬 두 번 탭 지우개
- **레이어 (옵션, `Editor/Layer/`)**: PDFView 위에 PencilKit 캔버스. Apple 기본 도구 그대로, 확대하면 흐려짐
- 두 방식 모두 같은 데이터(PKDrawing). 잉크 굵기는 PencilKit 렌더러로 직접 재서 맞춰서 어느 쪽에서 봐도 같은 굵기

## 서재와 노트북 (`Library/`, `Notebook/`)
- 서재 = Documents 폴더 (파일 앱 › 나의 iPad › BadNotes). 폴더는 진짜 폴더, 문서는 PDF
- 사이드바: 문서 · 즐겨찾기. 카드 ⌄ 메뉴: 즐겨찾기, 이름 바꾸기, 옮기기, 삭제(앱 안 보관함 `Application Support/BadNotes/Deleted`로)
- 새로운 노트북: 표지 12가지, 종이 5가지(백지·점선지·모눈·줄 좁은/넓은 간격) × 노랑·흰색·검정 × A4/iPad 세로·가로
  - 표지·종이는 전부 코드로 그림 (`PaperRenderer`). 종이 정보는 PDF 키워드 `BadNotesPaper=...`에 넣어서 파일만 있으면 따라다님
- 편집기에서 [페이지 추가]: 노트북이면 같은 종이, 그냥 PDF면 마지막 페이지 크기의 흰 종이
- 다시 열면 마지막으로 보던 페이지부터. 새 노트북은 표지 다음 장부터

## 테마 (`Theme/`)
- 바탕: 내 사진(기본 레이어) / 단색 / 그라데이션 → 그 위에 Liquid Glass 한 겹(켜기·재질·색)
- 강조색, 문서 카드(책/유리, 크기), 편집기 배경, 라이트/다크, 기울이면 바탕이 따라 움직임
- 프리셋: 기본, 다크, 종이, 바다, 숲 + 내 테마 저장. 바꾸면 미리보기와 앱 전체에 바로 반영

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

## 디버그 빌드 점검용 실행 인자
- `-BNSelfTest`: 저장 엔진·필기 엔진·PencilKit 굵기 맞춤 자체 점검 (`xcrun simctl launch --console-pty booted com.geonu9xpy.BadNotes -BNSelfTest`)
- `-BNInkDemo`: 직접 필기 모드에서 펜·형광펜·지우개·실행 취소·올가미·확대를 차례로 시연
- `-BNFingerDraw`: 손가락(시뮬레이터 마우스)으로 필기
- `-BNPreset <번호>`, `-BNShowTheme`, `-BNShowSettings`: 테마 프리셋 적용, 테마·설정 화면 바로 열기
- `-BNShowNewNotebook`: 새로운 노트북 화면 바로 열기 / `-BNMakeNotebook`: 시연 노트북을 만들어서 열기
- `-BNPhotoTest`: 점검용 바탕 사진 넣기 / `-BNOpenLast`: 마지막 문서 열기
- 실제 기기에서는 `xcrun devicectl device process launch --device <기기> com.geonu9xpy.BadNotes -- -BNSelfTest` (인자 앞에 `--`, 기기 잠금 풀려 있어야 함)

## 알려진 문제
- 다른 앱에서 보이는 필기 모양은 근사치 (연필 질감은 투명도로, 반투명 잉크는 획마다 평균 굵기로)
- 암호 걸린 PDF는 아직 못 엶
- 레이어 모드는 확대하면 필기가 흐려짐 (그래서 기본은 직접 필기)

## 빌드
Xcode로 `BadNotes.xcodeproj` 열고 Signing에서 본인 팀 골라서 실행.
