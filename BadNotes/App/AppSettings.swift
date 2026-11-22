//
//  AppSettings.swift
//  BadNotes
//
//  앱 설정 (UserDefaults에 저장).
//

import SwiftUI
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum EditMode: String, CaseIterable, Identifiable {
        /// 기본. 필기가 PDF 페이지와 같이 그려져서 확대해도 선명함 (굿노트, PDF 앱처럼)
        case direct
        /// 옵션. PDF 위에 Apple PencilKit 캔버스를 덮음 (Apple 기본 도구 그대로, 확대하면 흐려짐)
        case layer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .direct: "직접 필기"
            case .layer: "레이어 (PencilKit)"
            }
        }

        var detail: String {
            switch self {
            case .direct:
                "필기가 PDF 페이지와 함께 그려져서 아무리 확대해도 선명해요. 보이는 그대로 PDF에 저장되고 다른 앱에서도 똑같이 보여요."
            case .layer:
                "PDF 위에 Apple 필기 캔버스를 덮어요. Apple 기본 도구(자, 올가미 등)를 그대로 쓰지만 확대하면 필기가 흐려져요."
            }
        }
    }

    var editMode: EditMode {
        didSet { UserDefaults.standard.set(editMode.rawValue, forKey: Keys.editMode) }
    }

    /// 손가락으로도 필기 (켜면 스크롤은 두 손가락)
    var fingerDrawing: Bool {
        didSet { UserDefaults.standard.set(fingerDrawing, forKey: Keys.fingerDrawing) }
    }

    /// 두 손가락 탭: 실행 취소, 세 손가락 탭: 다시 실행
    var tapToUndo: Bool {
        didSet { UserDefaults.standard.set(tapToUndo, forKey: Keys.tapToUndo) }
    }

    /// 형광펜으로 거의 곧게 그으면 곧은 선으로 펴 줌 (수평에 가까우면 수평으로)
    var straightHighlighter: Bool {
        didSet { UserDefaults.standard.set(straightHighlighter, forKey: Keys.straightHighlighter) }
    }

    private enum Keys {
        static let editMode = "editMode"
        static let fingerDrawing = "fingerDrawing"
        static let tapToUndo = "tapToUndo"
        static let straightHighlighter = "straightHighlighter"
    }

    private init() {
        let defaults = UserDefaults.standard
        editMode = EditMode(rawValue: defaults.string(forKey: Keys.editMode) ?? "") ?? .direct
        fingerDrawing = defaults.bool(forKey: Keys.fingerDrawing)
        tapToUndo = defaults.object(forKey: Keys.tapToUndo) as? Bool ?? true
        straightHighlighter = defaults.object(forKey: Keys.straightHighlighter) as? Bool ?? true
        #if DEBUG
        // 시뮬레이터 점검용: 마우스(손가락)로 그리기
        if ProcessInfo.processInfo.arguments.contains("-BNFingerDraw") { fingerDrawing = true }
        #endif
    }
}
