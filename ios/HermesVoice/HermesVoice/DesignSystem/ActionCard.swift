import SwiftUI

// Structured response cards (calendar today; lists/files/devices later).
//
// Action cards render when an assistant reply can be expressed as a list of
// rows more cleanly than as prose. The component itself works on a small
// abstract data type — detection lives in `ActionCard.detect`, which today
// pattern-matches the assistant text for HH:MM-prefixed lines. When the
// backend grows a structured tool-output field, swap the detector to use
// that and the rendering stays unchanged.

enum ActionCard: Equatable {
    case calendar(items: [CalendarItem])

    struct CalendarItem: Identifiable, Equatable {
        let id = UUID()
        let time: String   // "09:00"
        let title: String
        let meta: String   // "15min · Google Meet" — optional context
    }

    /// Scan recent messages for a tool call + assistant reply that look like
    /// a calendar list. Currently triggered when:
    ///   - the latest tool call name contains "calendar", AND
    ///   - the latest assistant text contains 2+ lines starting with HH:MM
    ///
    /// Returns nil if no clean parse — caller falls back to plain text.
    static func detect(in messages: [Message]) -> ActionCard? {
        guard let assistant = messages.last(where: { $0.role == .assistant }) else {
            return nil
        }
        let hasCalendarTool = messages.contains { msg in
            msg.role == .toolCall && (msg.toolCall?.name.lowercased().contains("calendar") ?? false)
        }
        guard hasCalendarTool else { return nil }

        let items = parseTimeLines(in: assistant.text)
        return items.count >= 2 ? .calendar(items: items) : nil
    }

    private static let timeLine = #/^\s*(\d{1,2}:\d{2})\s*[—–\-:]\s*(.+?)\s*$/#

    private static func parseTimeLines(in text: String) -> [CalendarItem] {
        text.split(separator: "\n").compactMap { line -> CalendarItem? in
            guard let m = line.firstMatch(of: timeLine) else { return nil }
            let time = String(m.1)
            let rest = String(m.2)
            let parts = rest.components(separatedBy: " · ")
            let title = parts.first ?? rest
            let meta = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""
            return CalendarItem(time: time, title: title, meta: meta)
        }
    }
}

struct ActionCardView: View {
    let card: ActionCard

    var body: some View {
        switch card {
        case .calendar(let items):
            CalendarCard(items: items)
        }
    }
}

private struct CalendarCard: View {
    let items: [ActionCard.CalendarItem]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(HVColor.bronze)
                Text("CALENDAR · TODAY")
                    .font(HVFont.captionTiny.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(HVColor.bronze)
                Spacer()
                Text("\(items.count) events")
                    .font(HVFont.micro)
                    .foregroundStyle(HVColor.creamDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.15))
            .overlay(alignment: .bottom) {
                Rectangle().fill(HVColor.hairline).frame(height: 0.5)
            }

            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.time)
                        .font(HVFont.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(HVColor.amber)
                        .frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(HVFont.body.weight(.medium))
                            .foregroundStyle(HVColor.cream)
                        if !item.meta.isEmpty {
                            Text(item.meta)
                                .font(HVFont.captionTiny)
                                .foregroundStyle(HVColor.creamDim)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HVColor.creamDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if idx < items.count - 1 {
                    Rectangle().fill(HVColor.hairline).frame(height: 0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12).fill(HVColor.creamSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(HVColor.hairline, lineWidth: 0.5)
        )
    }
}
