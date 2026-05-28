import SwiftUI

/// Browse, create, edit, and delete recurring schedules.
///
/// Backend at `/api/schedules` is the source of truth. We don't persist
/// locally — every device sees the same canonical list. List is paged
/// implicitly (server returns all today; if schedules grow we'll add a
/// limit/cursor in Phase B or later).
struct SchedulesView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var schedules: [HermesVoiceAPI.Schedule] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showingCreate = false
    @State private var editing: HermesVoiceAPI.Schedule?

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()

                ScrollView {
                    if let error {
                        Text(error)
                            .font(HVFont.captionTiny)
                            .foregroundStyle(HVColor.dangerSoft)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }

                    if schedules.isEmpty && !loading {
                        emptyState
                    } else {
                        scheduleList
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }

                if loading && schedules.isEmpty {
                    ProgressView().tint(HVColor.amber).controlSize(.large)
                }
            }
            .navigationTitle("SCHEDULES")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SCHEDULES")
                        .font(HVFont.title)
                        .tracking(0.8)
                        .foregroundStyle(HVColor.amber)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .font(HVFont.body.weight(.semibold))
                        .foregroundStyle(HVColor.amber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(HVColor.amber)
                    }
                    .accessibilityLabel("Create schedule")
                }
            }
            .toolbarBackground(HVColor.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { await load() }
            .sheet(isPresented: $showingCreate) {
                ScheduleEditView(mode: .create, onSave: { _ in
                    Task { await load() }
                })
                .environmentObject(settings)
            }
            .sheet(item: $editing) { existing in
                ScheduleEditView(mode: .edit(existing), onSave: { _ in
                    Task { await load() }
                })
                .environmentObject(settings)
            }
        }
        .tint(HVColor.amber)
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(HVColor.bronze)
            Text("No schedules yet")
                .font(HVFont.body.weight(.semibold))
                .foregroundStyle(HVColor.cream)
            Text("Tap + to create a recurring message. Once voice creation ships, you'll also be able to say \"every 5 min give me the weather\" to Hermes directly.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 80)
    }

    private var scheduleList: some View {
        VStack(spacing: 0) {
            Text("\(schedules.count) ACTIVE")
                .font(HVFont.captionTiny.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(HVColor.creamDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            VStack(spacing: 0) {
                ForEach(Array(schedules.enumerated()), id: \.element.id) { idx, s in
                    ScheduleRow(
                        schedule: s,
                        onTap: { editing = s },
                        onToggle: { newValue in
                            Task { await togglePause(s, enabled: newValue) }
                        }
                    )
                    if idx < schedules.count - 1 {
                        Rectangle().fill(HVColor.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12).fill(HVColor.creamSurface)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            schedules = try await api.listSchedules()
            settings.markReachable()
            error = nil
        } catch {
            self.error = "Couldn't load schedules: \(error.localizedDescription)"
        }
    }

    private func togglePause(
        _ schedule: HermesVoiceAPI.Schedule, enabled: Bool
    ) async {
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            let updated = try await api.updateSchedule(id: schedule.id, enabled: enabled)
            if let idx = schedules.firstIndex(where: { $0.id == updated.id }) {
                schedules[idx] = updated
            }
        } catch {
            self.error = "Couldn't update: \(error.localizedDescription)"
        }
    }
}

// MARK: - Row

private struct ScheduleRow: View {
    let schedule: HermesVoiceAPI.Schedule
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(HVFont.body.weight(.semibold))
                            .foregroundStyle(schedule.enabled ? HVColor.cream : HVColor.creamFaint)
                        Spacer(minLength: 0)
                        Text(cadenceLabel)
                            .font(HVFont.captionTiny.weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(HVColor.bronze)
                    }

                    HStack(alignment: .top, spacing: 4) {
                        Text("›").foregroundStyle(HVColor.amber)
                        Text(schedule.prompt)
                            .font(HVFont.captionTiny)
                            .foregroundStyle(schedule.enabled ? HVColor.creamDim : HVColor.creamFaint)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text(nextFireLabel)
                            .font(HVFont.micro)
                            .foregroundStyle(HVColor.creamDim)
                        if schedule.consecutiveFails > 0 {
                            Text("· \(schedule.consecutiveFails) recent fail\(schedule.consecutiveFails == 1 ? "" : "s")")
                                .font(HVFont.micro)
                                .foregroundStyle(HVColor.danger)
                        }
                    }
                }

                Toggle("", isOn: Binding(
                    get: { schedule.enabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .tint(HVColor.amber)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private var displayName: String {
        schedule.displayName?.isEmpty == false
            ? schedule.displayName!
            : "Schedule"
    }

    private var cadenceLabel: String {
        Self.formatCadence(seconds: schedule.cadenceSeconds)
    }

    private var nextFireLabel: String {
        guard schedule.enabled else { return "paused" }
        let date = Date(timeIntervalSince1970: schedule.nextFireAt)
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "due now" }
        if interval < 60 { return "next in \(Int(interval))s" }
        if interval < 3600 { return "next in \(Int(interval / 60))m" }
        if interval < 86_400 { return "next in \(Int(interval / 3600))h" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        return "next at \(fmt.string(from: date))"
    }

    static func formatCadence(seconds: Int) -> String {
        switch seconds {
        case ..<60:   return "EVERY \(seconds)s"
        case ..<3600:
            let m = seconds / 60
            return "EVERY \(m) MIN"
        case 3600:    return "HOURLY"
        case ..<86_400:
            let h = seconds / 3600
            return "EVERY \(h)H"
        case 86_400:  return "DAILY"
        default:
            let d = seconds / 86_400
            return "EVERY \(d)D"
        }
    }
}

// MARK: - Edit / Create sheet

enum ScheduleEditMode {
    case create
    case edit(HermesVoiceAPI.Schedule)
}

struct ScheduleEditView: View {
    let mode: ScheduleEditMode
    let onSave: (HermesVoiceAPI.Schedule) -> Void

    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var displayName: String = ""
    @State private var cadenceSeconds: Int = 300  // default 5 min
    @State private var enabled: Bool = true
    @State private var saving = false
    @State private var error: String?

    private static let cadenceOptions: [(label: String, seconds: Int)] = [
        ("1 min",  60),
        ("5 min",  300),
        ("15 min", 900),
        ("30 min", 1800),
        ("Hourly", 3600),
        ("2 h",    7200),
        ("6 h",    21_600),
        ("Daily",  86_400),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()
                Form {
                    Section {
                        TextField("e.g. weather updates", text: $displayName)
                            .font(HVFont.body)
                            .foregroundStyle(HVColor.cream)
                            .listRowBackground(HVColor.creamSurface)
                    } header: {
                        sectionHeader("NAME")
                    }

                    Section {
                        Picker("", selection: $cadenceSeconds) {
                            ForEach(Self.cadenceOptions, id: \.seconds) { opt in
                                Text(opt.label).tag(opt.seconds)
                            }
                        }
                        .pickerStyle(.wheel)
                        .listRowBackground(HVColor.creamSurface)
                    } header: {
                        sectionHeader("CADENCE")
                    }

                    Section {
                        TextField("e.g. give me the weather", text: $prompt, axis: .vertical)
                            .font(HVFont.body)
                            .foregroundStyle(HVColor.cream)
                            .lineLimit(3...8)
                            .listRowBackground(HVColor.creamSurface)
                    } header: {
                        sectionHeader("PROMPT TO HERMES")
                    } footer: {
                        Text("Exactly what gets sent to Hermes each fire. Keep it focused — no preamble.")
                            .font(HVFont.captionTiny)
                            .foregroundStyle(HVColor.creamDim)
                    }

                    if case .edit = mode {
                        Section {
                            Toggle(isOn: $enabled) {
                                Text("Enabled")
                                    .font(HVFont.body)
                                    .foregroundStyle(HVColor.cream)
                            }
                            .tint(HVColor.amber)
                            .listRowBackground(HVColor.creamSurface)
                        }
                    }

                    if let error {
                        Section {
                            Text(error)
                                .font(HVFont.captionTiny)
                                .foregroundStyle(HVColor.dangerSoft)
                                .listRowBackground(HVColor.danger.opacity(0.08))
                        }
                    }

                    if case .edit(let existing) = mode {
                        Section {
                            Button(role: .destructive) {
                                Task { await delete(existing) }
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                    Text("Delete schedule")
                                }
                                .font(HVFont.body.weight(.semibold))
                                .foregroundStyle(HVColor.dangerSoft)
                            }
                            .listRowBackground(HVColor.danger.opacity(0.10))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(HVColor.bg)
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(navTitle)
                        .font(HVFont.title)
                        .tracking(0.8)
                        .foregroundStyle(HVColor.amber)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.creamDim)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().tint(HVColor.amber)
                        } else {
                            Text("Save")
                                .font(HVFont.body.weight(.semibold))
                                .foregroundStyle(canSave ? HVColor.amber : HVColor.creamFaint)
                        }
                    }
                    .disabled(!canSave || saving)
                }
            }
            .toolbarBackground(HVColor.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { hydrate() }
        }
        .tint(HVColor.amber)
        .preferredColorScheme(.dark)
    }

    private var navTitle: String {
        switch mode {
        case .create: return "NEW SCHEDULE"
        case .edit:   return "EDIT"
        }
    }

    private var canSave: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(HVFont.captionTiny.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(HVColor.bronze)
    }

    private func hydrate() {
        if case .edit(let existing) = mode {
            prompt = existing.prompt
            displayName = existing.displayName ?? ""
            cadenceSeconds = existing.cadenceSeconds
            enabled = existing.enabled
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let saved: HermesVoiceAPI.Schedule
            switch mode {
            case .create:
                saved = try await api.createSchedule(
                    cadenceSeconds: cadenceSeconds,
                    prompt: trimmedPrompt,
                    displayName: trimmedName.isEmpty ? nil : trimmedName
                )
            case .edit(let existing):
                saved = try await api.updateSchedule(
                    id: existing.id,
                    cadenceSeconds: cadenceSeconds,
                    prompt: trimmedPrompt,
                    displayName: trimmedName.isEmpty ? nil : trimmedName,
                    enabled: enabled
                )
            }
            onSave(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ existing: HermesVoiceAPI.Schedule) async {
        saving = true
        defer { saving = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            try await api.deleteSchedule(id: existing.id)
            onSave(existing)
            dismiss()
        } catch {
            self.error = "Couldn't delete: \(error.localizedDescription)"
        }
    }
}
