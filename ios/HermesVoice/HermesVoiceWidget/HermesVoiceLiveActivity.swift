import ActivityKit
import SwiftUI
import WidgetKit

// Brand-styled Live Activity for in-flight Hermes turns. Renders on the lock
// screen and in the Dynamic Island. State comes from HermesActivityAttributes
// (shared with the app target). Uses HVColor / HVFont from the shared
// Brand.swift, also compiled into this target.
struct HermesVoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(HVColor.bg)
                .activitySystemActionForegroundColor(HVColor.amber)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseGlyph(phase: context.state.phase)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture,
                         countsDown: false)
                        .font(HVFont.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint(context.state.phase))
                        .frame(maxWidth: 54)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.phase.label)
                            .font(HVFont.chipTiny)
                            .tracking(0.8)
                            .foregroundStyle(tint(context.state.phase))
                        if !context.state.detail.isEmpty {
                            Text(prefix(context.state.phase) + context.state.detail)
                                .font(HVFont.caption)
                                .foregroundStyle(HVColor.cream)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                PhaseGlyph(phase: context.state.phase)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture,
                     countsDown: false)
                    .font(HVFont.captionTiny.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint(context.state.phase))
                    .frame(maxWidth: 44)
            } minimal: {
                PhaseGlyph(phase: context.state.phase)
            }
            .widgetURL(URL(string: "hermesvoice://turn"))
            .keylineTint(HVColor.amber)
        }
    }

    private func tint(_ phase: HermesActivityAttributes.Phase) -> Color {
        phase == .speaking ? HVColor.gold : HVColor.bronze
    }
    private func prefix(_ phase: HermesActivityAttributes.Phase) -> String {
        phase == .speaking ? "←  " : "›  "
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: HermesActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("HERMES")
                        .font(HVFont.chip)
                        .tracking(1.0)
                        .foregroundStyle(HVColor.amber)
                    StatePill(phase: state.phase)
                }
                if !state.detail.isEmpty {
                    Text(prefixGlyph + state.detail)
                        .font(HVFont.bodyDim)
                        .foregroundStyle(HVColor.cream)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                PhaseGlyph(phase: state.phase).font(.system(size: 18))
                Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                    .font(HVFont.captionTiny.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HVColor.creamDim)
                    .frame(maxWidth: 50)
            }
        }
        .padding(14)
    }

    private var prefixGlyph: String { state.phase == .speaking ? "←  " : "›  " }
}

private struct StatePill: View {
    let phase: HermesActivityAttributes.Phase

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(phase.label)
                .font(HVFont.chipTiny)
                .tracking(0.6)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.16)))
    }

    private var color: Color { phase == .speaking ? HVColor.gold : HVColor.bronze }
}

private struct PhaseGlyph: View {
    let phase: HermesActivityAttributes.Phase

    var body: some View {
        Image(systemName: phase == .speaking ? "waveform" : "ellipsis")
            .foregroundStyle(phase == .speaking ? HVColor.gold : HVColor.bronze)
    }
}
