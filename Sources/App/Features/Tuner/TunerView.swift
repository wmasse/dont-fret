import SwiftUI
import Charts

struct Tuning: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var midi: [Int]
    var labels: [String] { midi.enumerated().map { i, m in i == 5 ? Theory.name(m % 12).lowercased() : Theory.name(m % 12) } }

    static let all: [Tuning] = [
        Tuning(name: "Standard", midi: [40, 45, 50, 55, 59, 64]),
        Tuning(name: "Drop D", midi: [38, 45, 50, 55, 59, 64]),
        Tuning(name: "Half Step Down", midi: [39, 44, 49, 54, 58, 63]),
        Tuning(name: "Open G", midi: [38, 43, 50, 55, 59, 62]),
        Tuning(name: "Open D", midi: [38, 45, 50, 54, 57, 62]),
        Tuning(name: "DADGAD", midi: [38, 45, 50, 55, 57, 62]),
    ]
}

struct TunerView: View {
    @EnvironmentObject var audio: AudioEngine
    @EnvironmentObject var progress: ProgressStore
    @State private var tuning = Tuning.all[0]
    @State private var lockedString: Int? = nil
    @State private var counted = false

    var body: some View {
        Page {
            PageHeader(title: "Tuner & Chord Detector", subtitle: "Uses your Mac's microphone. Pluck one string at a time to tune, or strum a chord to identify it.") {
                MicStatusView()
            }
            if let err = audio.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(Theme.font(13, .medium)).foregroundStyle(Theme.danger)
            }
            HStack(alignment: .top, spacing: 20) {
                tunerCard
                detectorCard.frame(width: 400)
            }
        }
        .onAppear { audio.acquire() }
        .onDisappear { audio.release() }
        .onChange(of: audio.pitch) { _, p in
            if p != nil && !counted { counted = true; progress.data.tunerUses += 1 }
        }
    }

    // MARK: tuner

    private var reading: (note: String, octave: Int, cents: Double, freq: Double, string: Int?)? {
        guard let f = audio.pitch, f > 50, f < 1400 else { return nil }
        let m = Theory.midi(frequency: f)
        if let s = lockedString {
            let target = Double(tuning.midi[s])
            return (Theory.name(tuning.midi[s] % 12), tuning.midi[s] / 12 - 1, (m - target) * 100, f, s)
        }
        // nearest string within 4 semitones, else nearest chromatic note
        let nearest = tuning.midi.enumerated().min { abs(Double($0.element) - m) < abs(Double($1.element) - m) }!
        if abs(Double(nearest.element) - m) < 2.5 {
            return (Theory.name(nearest.element % 12), nearest.element / 12 - 1, (m - Double(nearest.element)) * 100, f, nearest.offset)
        }
        let r = Int(m.rounded())
        return (Theory.name(r % 12), r / 12 - 1, (m - Double(r)) * 100, f, nil)
    }

    private var tunerCard: some View {
        let r = reading
        let cents = r?.cents ?? 0
        let inTune = r != nil && abs(cents) < 5
        let tint: Color = r == nil ? Theme.textFaint : (inTune ? Theme.success : (abs(cents) < 15 ? Theme.warn : Theme.danger))
        return VStack(spacing: 22) {
            HStack {
                Menu {
                    ForEach(Tuning.all) { t in Button(t.name) { tuning = t; lockedString = nil } }
                } label: { Label("Tuning: \(tuning.name)", systemImage: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Segmented(options: [-1, 0, 1, 2, 3, 4, 5], selection: Binding(get: { lockedString ?? -1 }, set: { lockedString = $0 < 0 ? nil : $0 })) { i in
                    i < 0 ? "Auto" : tuning.labels[i]
                }
            }
            VStack(spacing: 6) {
                Gauge(cents: max(-50, min(50, cents)), tint: tint, active: r != nil)
                    .frame(height: 190)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(r?.note ?? "–").font(.system(size: 84, weight: .heavy))
                        .foregroundStyle(r == nil ? Theme.textFaint : Theme.text)
                    if let o = r?.octave { Text("\(o)").font(Theme.font(24, .bold)).foregroundStyle(Theme.textFaint) }
                }
                Text(r.map { String(format: "%.1f Hz · %+d¢", $0.freq, Int($0.cents.rounded())) } ?? "Pluck a string")
                    .font(Theme.font(14, .medium)).foregroundStyle(Theme.textDim).monospacedDigit()
            }
            Text(status(r)).font(Theme.font(20, .bold)).foregroundStyle(tint)
                .animation(.easeOut(duration: 0.15), value: inTune)
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    let active = r?.string == i
                    Button {
                        GuitarSynth.shared.pluck(midi: tuning.midi[i])
                    } label: {
                        VStack(spacing: 3) {
                            Text(tuning.labels[i]).font(Theme.font(20, .heavy))
                            Text("\(6 - i)").font(Theme.font(10, .semibold)).opacity(0.6)
                        }
                        .foregroundStyle(active ? Theme.onAccent : Theme.text)
                        .frame(width: 58, height: 62)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(active ? AnyShapeStyle(inTune ? Theme.greenGradient : Theme.accentGradient) : AnyShapeStyle(Theme.surface2)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .help("Play reference \(tuning.labels[i])")
                }
            }
            Text("Click a string to hear its reference pitch.").font(Theme.font(12)).foregroundStyle(Theme.textFaint)
        }
        .card(padding: 24, radius: 22)
    }

    private func status(_ r: (note: String, octave: Int, cents: Double, freq: Double, string: Int?)?) -> String {
        guard let r else { return audio.isListening ? "Listening…" : "Microphone is off" }
        if abs(r.cents) < 5 { return "In tune ✓" }
        return r.cents < 0 ? "Tune up ↑  \(Int(-r.cents))¢ flat" : "Tune down ↓  \(Int(r.cents))¢ sharp"
    }

    // MARK: chord detector

    private var detectorCard: some View {
        let det = audio.detected
        let notes = det?.symbol.pitchClasses ?? []
        return VStack(alignment: .leading, spacing: 18) {
            Text("What am I playing?").font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.accent)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(det?.name ?? "–").font(.system(size: 64, weight: .heavy)).foregroundStyle(det == nil ? Theme.textFaint : Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(det?.symbol.longName.capitalized ?? "Strum any chord").font(Theme.font(14)).foregroundStyle(Theme.textDim)
                    if let d = det {
                        Text("\(Int(max(0, min(1, d.score)) * 100))% match · \(ChordLibrary.level(of: d.name) == 1 ? "Simple" : (ChordLibrary.level(of: d.name) == 2 ? "Intermediate" : "Advanced")) chord")
                            .font(Theme.font(12, .semibold)).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer()
                if let d = det { ChordDiagram(name: d.name, width: 100) }
            }
            // chroma bars
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<12, id: \.self) { i in
                    VStack(spacing: 5) {
                        GeometryReader { g in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(notes.contains(i) ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface3))
                                    .frame(height: max(3, g.size.height * CGFloat(audio.chroma[i])))
                            }
                        }
                        Text(Theory.name(i)).font(Theme.font(10, .bold)).foregroundStyle(notes.contains(i) ? Theme.text : Theme.textFaint)
                    }
                }
            }
            .frame(height: 120)
            .animation(.linear(duration: 0.08), value: audio.chroma)
            if audio.candidates.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Other possibilities").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim)
                    ForEach(audio.candidates.dropFirst().prefix(3)) { c in
                        HStack {
                            ChordChip(name: c.name, size: 13)
                            Spacer()
                            ProgressView(value: Double(max(0, min(1, c.score)))).frame(width: 120).tint(Theme.info)
                        }
                    }
                }
            }
            Text("Detects major, minor, power, 7th, maj7, m7, sus, add9, 6, 9, dim, aug and more. Simple chords win close calls.")
                .font(Theme.font(11)).foregroundStyle(Theme.textFaint)
        }
        .card(padding: 24, radius: 22)
    }
}

struct Gauge: View {
    var cents: Double
    var tint: Color
    var active: Bool
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let center = CGPoint(x: w / 2, y: h)
            let radius = min(w / 2, h) - 10
            ZStack {
                Canvas { ctx, _ in
                    for c in stride(from: -50, through: 50, by: 5) {
                        let a = Angle.degrees(-90 + Double(c) * 1.4).radians
                        let major = c % 25 == 0
                        let r1 = radius - (major ? 26 : 14)
                        var p = Path()
                        p.move(to: CGPoint(x: center.x + cos(a) * r1, y: center.y + sin(a) * r1))
                        p.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
                        let col: Color = c == 0 ? Theme.success : Theme.text.opacity(major ? 0.5 : 0.18)
                        ctx.stroke(p, with: .color(col), lineWidth: c == 0 ? 4 : (major ? 2.5 : 1.5))
                    }
                    // in-tune zone
                    var zone = Path()
                    zone.addArc(center: center, radius: radius + 8, startAngle: .degrees(-90 - 7), endAngle: .degrees(-90 + 7), clockwise: false)
                    ctx.stroke(zone, with: .color(Theme.success.opacity(0.6)), lineWidth: 5)
                }
                // needle
                Capsule()
                    .fill(active ? tint : Theme.textFaint)
                    .frame(width: 5, height: radius - 6)
                    .shadow(color: tint.opacity(active ? 0.7 : 0), radius: 10)
                    .rotationEffect(.degrees(cents * 1.4), anchor: .bottom)
                    .position(x: center.x, y: center.y - (radius - 6) / 2)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: cents)
                Circle().fill(Theme.surface3).frame(width: 22, height: 22).position(center)
                Text("−50¢").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textFaint).position(x: center.x - radius * 0.9, y: h - 8)
                Text("+50¢").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textFaint).position(x: center.x + radius * 0.9, y: h - 8)
            }
        }
    }
}

// MARK: - Progress

struct StatsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore

    var body: some View {
        let days = progress.lastDays(7)
        let played = progress.data.songs.filter { $0.value.plays > 0 }
        Page {
            PageHeader(title: "Progress", subtitle: "Level \(progress.level) \(progress.skill.title) · \(progress.data.xp.formatted()) XP total") { EmptyView() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                StatTile(icon: "sparkles", value: "Lv \(progress.level)", label: "\(progress.xpToNext) XP to next level", tint: Theme.accent)
                StatTile(icon: "flame.fill", value: "\(progress.streak)", label: "Day streak", tint: Theme.accent2)
                StatTile(icon: "clock.fill", value: "\(Int(progress.totalMinutes))m", label: "Total practice", tint: Theme.info)
                StatTile(icon: "music.note.list", value: "\(played.count)", label: "Songs played", tint: Theme.violet)
                StatTile(icon: "hand.raised.fill", value: "\(progress.masteredChords.count)", label: "Chords mastered", tint: Theme.success)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { weekCard(days).frame(minWidth: 420); bestCard(played).frame(width: 340) }
                VStack(spacing: 18) { weekCard(days); bestCard(played) }
            }
            accuracyCard
            achievementsCard
            masteryCard
        }
    }

    private func weekCard(_ days: [(label: String, minutes: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "This week", subtitle: "Minutes practised per day · goal \(progress.dailyGoal) min")
            Chart {
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                    BarMark(x: .value("Day", d.label), y: .value("Minutes", d.minutes))
                        .foregroundStyle(Theme.accentGradient)
                        .cornerRadius(6)
                }
                RuleMark(y: .value("Goal", progress.dailyGoal))
                    .foregroundStyle(Theme.success.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel().foregroundStyle(Theme.textFaint) } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.textDim) } }
            .frame(height: 220)
            .accessibilityLabel("Minutes practised this week")
        }
        .card(padding: 22, radius: 20)
    }

    private func bestCard(_ played: [String: SongRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Best songs")
            if played.isEmpty {
                Text("Play a song to see your scores here.").font(Theme.font(13)).foregroundStyle(Theme.textDim)
            }
            ForEach(played.sorted { $0.value.bestScore > $1.value.bestScore }.prefix(6), id: \.key) { id, r in
                if let s = progress.song(id: id) {
                    Button { app.openSong(s) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(seed: s.id, title: s.title, genre: s.genre, size: 36).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text("\(r.bestScore.formatted()) pts · \(Int(r.bestAccuracy * 100))%").font(Theme.font(11)).foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                            StarRow(stars: r.stars, size: 10)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 22, radius: 20)
    }

    private struct WeekPoint: Identifiable { var week: Date; var acc: Double; var id: Date { week } }

    private var accuracyCard: some View {
        let attempts = progress.data.songs.values.flatMap(\.history)
        let cal = Calendar.current
        let grouped = Dictionary(grouping: attempts) { cal.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? $0.date }
        let points = grouped.map { WeekPoint(week: $0.key, acc: $0.value.map(\.accuracy).reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.week < $1.week }.suffix(12)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Accuracy over time", subtitle: "Average accuracy of the songs you played, week by week")
            if points.count < 2 {
                Text(attempts.isEmpty ? "Play a few songs and your accuracy trend will appear here." : "Keep playing — the trend appears after your second week.")
                    .font(Theme.font(13)).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            } else {
                Chart(Array(points)) { w in
                    AreaMark(x: .value("Week", w.week, unit: .weekOfYear), y: .value("Accuracy", w.acc * 100))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Week", w.week, unit: .weekOfYear), y: .value("Accuracy", w.acc * 100))
                        .foregroundStyle(Theme.accent).interpolationMethod(.monotone)
                    PointMark(x: .value("Week", w.week, unit: .weekOfYear), y: .value("Accuracy", w.acc * 100))
                        .foregroundStyle(Theme.accent)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine().foregroundStyle(Theme.stroke)
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }.foregroundStyle(Theme.textFaint)
                    }
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Theme.textDim) } }
                .frame(height: 180)
                .accessibilityLabel("Accuracy over time chart")
            }
        }
        .card(padding: 22, radius: 20)
    }

    private var achievementsCard: some View {
        let got = progress.data.achievements
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Achievements", subtitle: "\(got.count) of \(Achievement.all.count) unlocked")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(Achievement.all) { a in achievementTile(a, date: got[a.id]) }
            }
        }
        .card(padding: 22, radius: 20)
    }

    private func achievementTile(_ a: Achievement, date: Date?) -> some View {
        let on = date != nil
        return HStack(spacing: 12) {
            ZStack {
                if on { Circle().fill(Theme.accentGradient) } else { Circle().fill(Theme.track) }
                Image(systemName: on ? a.icon : "lock.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(on ? Color.white : Theme.textFaint)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(Theme.font(13, .bold)).foregroundStyle(on ? Theme.text : Theme.textDim)
                Text(date.map { "Unlocked \($0.formatted(date: .abbreviated, time: .omitted))" } ?? a.detail)
                    .font(Theme.font(11)).foregroundStyle(Theme.textFaint).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(on ? Theme.accent.opacity(0.08) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Theme.accent.opacity(0.35) : Theme.stroke))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(a.title), \(on ? "unlocked" : "locked"). \(a.detail)")
    }

    private var masteryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Chord mastery", subtitle: "Green = mastered. Mastery fades if you don't practise. Click a chord to drill it.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(ChordLibrary.shapes) { s in
                    let m = progress.mastery(s.name)
                    Button { app.practice(chords: [s.name]) } label: {
                        VStack(spacing: 6) {
                            Text(s.name).font(Theme.font(15, .bold)).foregroundStyle(Theme.text)
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { i in Capsule().fill(i < m ? Theme.success : Theme.track).frame(height: 4) }
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(m >= 3 ? Theme.success.opacity(0.12) : Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(m >= 3 ? Theme.success.opacity(0.4) : Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(s.name), mastery \(m) of 5. Practise")
                }
            }
        }
    }
}
