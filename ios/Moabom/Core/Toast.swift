import SwiftUI

@MainActor
final class Toast: ObservableObject {
    static let shared = Toast()
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let hasUndo: Bool
        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }
    @Published private(set) var current: Item?
    private var undoAction: (() async -> Void)?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, undo: (() async -> Void)? = nil) {
        undoAction = undo
        withAnimation(.spring(duration: 0.3)) { current = Item(message: message, hasUndo: undo != nil) }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: undo == nil ? 2_200_000_000 : 5_000_000_000)
            if !Task.isCancelled { hide() }
        }
    }

    func runUndo() {
        let a = undoAction
        hide()
        if let a { Task { await a() } }
    }

    func hide() {
        undoAction = nil
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
    }
}

struct ToastOverlay: View {
    @ObservedObject var toast = Toast.shared

    var body: some View {
        VStack {
            Spacer()
            if let t = toast.current {
                HStack(spacing: 14) {
                    Text(t.message).font(.subheadline.weight(.medium))
                    if t.hasUndo {
                        Button("되돌리기") { toast.runUndo() }
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.1)))
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
            }
        }
        .allowsHitTesting(toast.current != nil)
        .frame(maxWidth: .infinity)
    }
}
