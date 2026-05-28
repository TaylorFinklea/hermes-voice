import SwiftUI

/// Full in-app transcript of the CURRENT conversation, rendered straight from
/// the in-memory `conversation.messages`. Reached by tapping the scrollback
/// rail — it keeps you inside the live session instead of bouncing out to the
/// all-sessions History browser (which round-trips the backend and can miss
/// the turn you just finished). For past sessions, use History → Conversation.
struct TranscriptView: View {
    @EnvironmentObject var conversation: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()
                if conversation.messages.isEmpty {
                    emptyState
                } else {
                    transcript
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("TRANSCRIPT")
                        .font(HVFont.title)
                        .tracking(0.8)
                        .foregroundStyle(HVColor.amber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(HVFont.captionTiny.weight(.semibold))
                        .foregroundStyle(HVColor.amber)
                }
            }
            .toolbarBackground(HVColor.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(conversation.messages) { msg in
                        TranscriptRow(message: msg).id(msg.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                // Land at the bottom — the most-recent turn is what you tapped
                // the scrollback to read in full.
                if let last = conversation.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 30))
                .foregroundStyle(HVColor.bronze)
            Text("No messages yet")
                .font(HVFont.body)
                .foregroundStyle(HVColor.creamDim)
        }
    }
}

/// Hero-styled row mirroring ConversationDetailView's MessageRow, but for the
/// in-memory `Message` type rather than a fetched HistoryMessage.
private struct TranscriptRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 4) {
                Text("›").foregroundStyle(HVColor.amber).font(HVFont.heroUser)
                Text(message.text)
                    .font(HVFont.heroUser)
                    .foregroundStyle(HVColor.cream)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 4) {
                Text("←").foregroundStyle(HVColor.gold).font(HVFont.heroReply)
                Text(message.text)
                    .font(HVFont.heroReply)
                    .foregroundStyle(HVColor.cream)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .toolCall:
            ToolChip(
                name: message.toolCall?.name ?? "tool",
                preview: message.toolCall?.preview ?? message.text,
                ok: message.toolCall?.ok ?? true
            )
        }
    }
}
