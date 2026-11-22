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

    /// 지금 연결된 편집기 (모드를 바꿀 때 예전 편집기가 새 연결을 지우지 않게)
    @ObservationIgnored var owner: ObjectIdentifier?
    @ObservationIgnored var undoAction: (() -> Void)?
    @ObservationIgnored var redoAction: (() -> Void)?
    @ObservationIgnored var jumpAction: ((Int) -> Void)?
    /// 문서에 페이지가 들어온 뒤 편집기에 알림
    @ObservationIgnored var pageAddedAction: ((Int) -> Void)?

    func undo() { undoAction?() }
    func redo() { redoAction?() }
    func jump(to page: Int) { jumpAction?(page) }
    func pageAdded(_ page: Int) { pageAddedAction?(page) }

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
        canUndo = false
        canRedo = false
    }
}
