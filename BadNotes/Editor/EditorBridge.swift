//
//  EditorBridge.swift
//  BadNotes
//
//  편집기(UIKit)와 바깥 화면(SwiftUI 도구 막대, 상태 표시) 사이 연결.
//  직접 필기 모드와 레이어 모드가 같이 씀.
//

import Foundation
import Observation

@Observable
final class EditorBridge {
    var page = 0
    var pageCount = 0
    var canUndo = false
    var canRedo = false
    /// 아래로 스크롤하면 도구 막대를 숨김
    var chromeHidden = false
    /// 마지막 페이지 끝까지 내려왔는지 (페이지 추가 버튼을 보여 줌)
    var atLastPage = false
    /// 책처럼 넘기는 중인지 (아래 캡슐에 ‹ › 를 보여 줌)
    var isBook = false
    var canTurnBack = false
    var canTurnForward = false
    /// 이미지 도구로 페이지를 누름 → 바깥 화면이 사진 고르기를 띄움
    var imageRequest = 0
    /// 위 막대의 [#] → 바깥 화면이 페이지 이동 창을 띄움
    var jumpRequest = 0
    /// 지금 배율 (페이지 맞춤 = 100)
    var zoomPercent = 100
    var zoomLocked = false

    /// 지금 연결된 편집기 (모드를 바꿀 때 예전 편집기가 새 연결을 지우지 않게)
    @ObservationIgnored var owner: ObjectIdentifier?
    @ObservationIgnored var undoAction: (() -> Void)?
    @ObservationIgnored var redoAction: (() -> Void)?
    @ObservationIgnored var jumpAction: ((Int) -> Void)?
    /// 문서에 페이지가 들어온 뒤 편집기에 알림
    @ObservationIgnored var pageAddedAction: ((Int) -> Void)?
    /// 텍스트 상자·메모지·사진 넣기
    @ObservationIgnored var insertAction: ((Insert) -> Void)?
    /// 책 보기에서 앞/뒤로 넘기기 (+1 / -1)
    @ObservationIgnored var turnAction: ((Int) -> Void)?
    /// 도구 막대에서 글자·메모지 모양을 바꿈 → 고른 상자에 적용
    @ObservationIgnored var restyleAction: (() -> Void)?
    /// 배율 바꾸기: nil = 페이지 맞춤, 숫자 = 맞춤 대비 %
    @ObservationIgnored var zoomAction: ((Double?) -> Void)?

    enum Insert {
        case text(PageElement.Fill)
        case sticky
        case image(Data)
    }

    func undo() { undoAction?() }
    func redo() { redoAction?() }
    func jump(to page: Int) { jumpAction?(page) }
    func pageAdded(_ page: Int) { pageAddedAction?(page) }
    func insert(_ what: Insert) { insertAction?(what) }
    func turn(_ delta: Int) { turnAction?(delta) }
    func restyle() { restyleAction?() }
    func requestJump() { jumpRequest += 1 }
    func zoom(_ percent: Double?) { zoomAction?(percent) }

    func attach(_ editor: AnyObject) {
        owner = ObjectIdentifier(editor)
        canUndo = false
        canRedo = false
        chromeHidden = false
    }

    func detach(_ editor: AnyObject) {
        guard owner == ObjectIdentifier(editor) else { return }
        owner = nil
        undoAction = nil
        redoAction = nil
        jumpAction = nil
        pageAddedAction = nil
        insertAction = nil
        turnAction = nil
        restyleAction = nil
        zoomAction = nil
        isBook = false
        canUndo = false
        canRedo = false
    }
}
