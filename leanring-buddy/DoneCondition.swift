//
//  DoneCondition.swift
//  leanring-buddy
//
//  A session step's "done" that local code tests from structure, never from
//  the model (v0 Guided/Doing sessions spec §4). Which conditions actually
//  discriminate LinkedIn's steps is measured by `scripts/done-conditions.py`.
//

import Foundation

/// Names are app-written text: matched exactly, as the harness resolver does.
nonisolated struct DoneElement: Equatable, Sendable { var role: String; var name: String; var selected: Bool?; var valueLength: Int? }
nonisolated struct DoneSnapshot: Equatable, Sendable { var windowTitle: String; var elements: [DoneElement] }

nonisolated enum DoneCondition: Equatable, Sendable {
    case windowTitleContains(String)
    case elementPresent(role: String, name: String)
    case elementSelected(role: String, name: String)
    case elementAbsent(role: String, name: String)
    case textFieldNonEmpty(label: String)

    static func holds(_ condition: DoneCondition, in snapshot: DoneSnapshot) -> Bool {
        func find(_ role: String, _ name: String) -> DoneElement? {
            snapshot.elements.first { $0.role == role && $0.name == name }
        }
        switch condition {
        case .windowTitleContains(let text): return snapshot.windowTitle.contains(text)
        case .elementPresent(let role, let name): return find(role, name) != nil
        case .elementSelected(let role, let name): return find(role, name)?.selected == true
        case .elementAbsent(let role, let name): return find(role, name) == nil
        case .textFieldNonEmpty(let label):
            return snapshot.elements.contains { $0.name == label && ($0.valueLength ?? 0) > 0 }
        }
    }
}
