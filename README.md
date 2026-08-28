# Solv

메뉴바 앱. 화면에 보이는 **객관식(N지선다, 2~9)** 을 풀고, 답을 **Caps Lock 불** 또는 **마우스**로 알려줍니다.

## 사용법

1. Xcode에서 `Solv.xcodeproj` 열고 Run, 또는:
   ```bash
   xcodebuild -project Solv.xcodeproj -scheme Solv -configuration Debug -derivedDataPath build build
   open build/Build/Products/Debug/Solv.app
   ```
2. 메뉴바 👁 → **API 키 설정**에 OpenAI API 키 입력
3. **화면 녹화** + **손쉬운 사용** 권한 허용 (메뉴의 “권한 확인”)
4. 문제 화면에서 **⌘ + ⌥** 동시 입력

| 결과 | Caps Lock |
|------|-----------|
| 답 1~5 | 불이 그 횟수만큼 깜빡임 |
| 객관식 아님 / 불확실 | 짧게 3번 |

## 동작

1. 메인 디스플레이 캡처  
2. Vision 모델이 N지선다(2~9)를 판별·풀이  
3. `IOHIDSetModifierLockState`로 Caps Lock LED 제어 후 원래 상태 복구
