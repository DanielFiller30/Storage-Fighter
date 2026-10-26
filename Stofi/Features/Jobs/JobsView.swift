import AnalysisKit
import CleanupKit
import ScannerKit
import SwiftUI

/// Scheduled clean-ups. A job prepares a selection at its time; removing always needs your confirmation.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CleanupJob?
    @State private var jobToDelete: CleanupJob?

    var body: some View {
        let scheduler = model.jobs
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard(title: "Scheduled Clean-ups", systemImage: "calendar.badge.clock") {
                    Text("At the chosen time, or when space gets low, Stofi measures the selected categories and prepares a selection. Nothing is removed automatically: you review it and confirm in the usual dialog. Jobs run while Stofi is open; missed times are caught up once.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("New Job…", systemImage: "plus") { editing = CleanupJob(name: "", categories: []) }
                        .buttonStyle(.borderedProminent)
                }

                if !scheduler.ready.isEmpty {
                    Text("Ready for review").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    ForEach(scheduler.ready) { ReadyJobCard(readyJob: $0) }
                }

                if !scheduler.jobs.isEmpty {
                    Text("Jobs").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    ForEach(scheduler.jobs) { job in
                        JobRow(job: job, onEdit: { editing = job }, onDelete: { jobToDelete = job })
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $editing) { job in
            JobEditor(job: job) { saved in
                scheduler.save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog("Delete this job?", isPresented: Binding(get: { jobToDelete != nil }, set: { if !$0 { jobToDelete = nil } }),
                            presenting: jobToDelete) { job in
            Button("Delete Job", role: .destructive) { scheduler.delete(job) }
        } message: { _ in
            Text("Only the schedule is deleted, no files.")
        }
    }
}

private struct ReadyJobCard: View {
    @Environment(AppModel.self) private var model
    let readyJob: JobScheduler.ReadyJob

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checklist").font(.title3).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: readyJob.jobName).font(.headline)
                Text("\(readyJob.candidates.count.formattedCount) items · \(readyJob.totalSize.formattedBytes) · prepared \(readyJob.preparedAt, format: .relative(presentation: .named))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if case .lowSpace = readyJob.trigger {
                    Label("Prepared because space is low", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Dismiss") { model.jobs.dismiss(readyJob) }
            Button("Review and Confirm…") { model.review(readyJob) }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .stofiGlass(cornerRadius: 16)
        .accessibilityElement(children: .contain)
    }
}

private struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: CleanupJob
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let scheduler = model.jobs
        HStack(alignment: .top, spacing: 12) {
            Toggle("Enabled", isOn: Binding(get: { job.isEnabled }, set: { scheduler.setEnabled($0, for: job) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Enable \(job.name)"))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: job.name).font(.headline)
                Text(verbatim: categoryTitles).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(verbatim: job.triggerDescription).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let next = job.nextScheduledRun(after: .now) {
                        Text("Next: \(next, format: .dateTime.weekday().day().month().hour().minute())")
                    }
                    if let last = job.lastPrepared {
                        Text("Last prepared: \(last, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            if scheduler.preparing.contains(job.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Prepare Now") { scheduler.prepareNow(job) }
                    .disabled(job.categories.isEmpty)
            }
            Menu {
                Button("Edit…", action: onEdit)
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(16)
        .stofiGlass(cornerRadius: 16)
    }

    private var categoryTitles: String {
        let titles = Dictionary(uniqueKeysWithValues: JobCategories.all(profiles: model.profiles.available).map { ($0.id, $0.title) })
        return job.categories.compactMap { titles[$0] }.formatted(.list(type: .and))
    }
}

extension CleanupJob {
    /// E.g. “Weekly on Monday at 09:00 · when space is low · older than 30 days”.
    var triggerDescription: String {
        var parts: [String] = []
        if let schedule {
            let time = String(format: "%02d:%02d", schedule.hour, schedule.minute)
            switch schedule.frequency {
            case .daily:
                parts.append(String(localized: "Daily at \(time)"))
            case .weekly:
                let weekday = Calendar.current.weekdaySymbols[schedule.weekday - 1]
                parts.append(String(localized: "Weekly on \(weekday) at \(time)"))
            case .monthly:
                parts.append(String(localized: "Monthly on day \(schedule.dayOfMonth) at \(time)"))
            }
        }
        switch lowSpaceLevel {
        case .low: parts.append(String(localized: "when space is low"))
        case .critical: parts.append(String(localized: "when space is critical"))
        case .normal, nil: break
        }
        if let minimumAgeDays { parts.append(String(localized: "older than \(minimumAgeDays) days")) }
        return parts.joined(separator: " · ")
    }
}

private struct JobEditor: View {
    @Environment(AppModel.self) private var model
    @State var job: CleanupJob
    let onSave: (CleanupJob) -> Void
    let onCancel: () -> Void

    @State private var usesSchedule = true
    @State private var usesAge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $job.name, prompt: Text("e.g. Weekly developer clean-up"))
                }
                Section("Categories") {
                    ForEach(JobCategories.all(profiles: model.profiles.available)) { entry in
                        Toggle(entry.title, isOn: Binding(
                            get: { job.categories.contains(entry.id) },
                            set: { isOn in
                                if isOn { job.categories.append(entry.id) } else { job.categories.removeAll { $0 == entry.id } }
                            }))
                    }
                }
                Section("When") {
                    Toggle("On a schedule", isOn: $usesSchedule)
                    if usesSchedule, let schedule = Binding($job.schedule) {
                        Picker("Repeat", selection: schedule.frequency) {
                            Text("Daily").tag(CleanupJob.Schedule.Frequency.daily)
                            Text("Weekly").tag(CleanupJob.Schedule.Frequency.weekly)
                            Text("Monthly").tag(CleanupJob.Schedule.Frequency.monthly)
                        }
                        if schedule.wrappedValue.frequency == .weekly {
                            Picker("Weekday", selection: schedule.weekday) {
                                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                            }
                        }
                        if schedule.wrappedValue.frequency == .monthly {
                            Stepper("Day \(schedule.wrappedValue.dayOfMonth) of the month", value: schedule.dayOfMonth, in: 1...28)
                        }
                        DatePicker("Time", selection: timeBinding(schedule), displayedComponents: .hourAndMinute)
                    }
                    Picker("When space is low", selection: $job.lowSpaceLevel) {
                        Text("No").tag(CapacityLevel?.none)
                        Text("Low").tag(CapacityLevel?.some(.low))
                        Text("Critical").tag(CapacityLevel?.some(.critical))
                    }
                }
                Section("Filter") {
                    Toggle("Only items older than", isOn: $usesAge)
                    if usesAge {
                        Stepper("\(job.minimumAgeDays ?? 30) days", value: Binding(
                            get: { job.minimumAgeDays ?? 30 }, set: { job.minimumAgeDays = $0 }), in: 1...3_650)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Nothing is removed without your confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(normalized) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            usesSchedule = job.schedule != nil || job.lowSpaceLevel == nil
            if job.schedule == nil { job.schedule = .init(frequency: .weekly) }
            usesAge = job.minimumAgeDays != nil
        }
    }

    private var normalized: CleanupJob {
        var result = job
        result.name = job.name.trimmingCharacters(in: .whitespaces)
        if !usesSchedule { result.schedule = nil }
        if !usesAge { result.minimumAgeDays = nil }
        return result
    }

    private var isValid: Bool {
        let result = normalized
        return !result.name.isEmpty && !result.categories.isEmpty && (result.schedule != nil || result.lowSpaceLevel != nil)
    }

    private func timeBinding(_ schedule: Binding<CleanupJob.Schedule>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: schedule.wrappedValue.hour, minute: schedule.wrappedValue.minute,
                                  second: 0, of: .now) ?? .now
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            schedule.wrappedValue.hour = components.hour ?? 9
            schedule.wrappedValue.minute = components.minute ?? 0
        }
    }
}
