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
        /// 기본. BadNotes 필기 엔진 (필기가 PDF 페이지와 같이 그려져서 확대해도 선명함)
        case direct
        /// 옵션. Apple PencilKit 캔버스 + Apple 기본 도구. 페이지를 캔버스 아래에 깔고 같이 확대해서 선명함.
        /// (예전 '레이어' 모드 자리라서 저장값은 그대로 "layer")
        case pencilKit = "layer"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .direct: "BadNotes 필기 도구 (기본)"
            case .pencilKit: "Apple 필기 도구 (PencilKit)"
            }
        }

        var detail: String {
            switch self {
            case .direct:
                "BadNotes가 직접 그리는 펜·형광펜·지우개·올가미·텍스트. 아무리 확대해도 선명하고, 보이는 그대로 PDF에 저장돼요."
            case .pencilKit:
                "Apple이 만든 도구(펜·마커·연필·만년필·수채화·크레용·지우개·올가미·자)를 그대로 써요. 확대해도 선명하고, 저장은 똑같이 PDF 안에 돼요. 텍스트 상자·메모지·사진은 [+]에서 넣어요."
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

    /// 책처럼 한 장(가로면 두 장)씩 넘기기. 끄면 세로로 이어서 스크롤
    var pageTurn: Bool {
        didSet { UserDefaults.standard.set(pageTurn, forKey: Keys.pageTurn) }
    }

    /// 가로 화면에서 두 쪽을 양옆으로 펼쳐 보기
    var twoUpLandscape: Bool {
        didSet { UserDefaults.standard.set(twoUpLandscape, forKey: Keys.twoUpLandscape) }
    }

    private enum Keys {
        static let pageTurn = "pageTurn"
        static let twoUpLandscape = "twoUpLandscape"
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
        pageTurn = defaults.object(forKey: Keys.pageTurn) as? Bool ?? true
        twoUpLandscape = defaults.object(forKey: Keys.twoUpLandscape) as? Bool ?? true
        #if DEBUG
        // 시뮬레이터 점검용: 마우스(손가락)로 그리기
        if ProcessInfo.processInfo.arguments.contains("-BNFingerDraw") { fingerDrawing = true }
        // 시뮬레이터 점검용: Apple 필기 도구 모드로 열기 (저장은 안 함)
        if ProcessInfo.processInfo.arguments.contains("-BNAppleTools") { editMode = .pencilKit }
        #endif
    }
}
