import SwiftUI

struct CompactCalendarView: View {
    @ObservedObject var service: AppleCalendarService

    private var nextEvent: CalendarEventItem? {
        service.accessState == .authorized ? service.nextEvent : nil
    }

    var body: some View {
        HStack(spacing: 9) {
            dateTile

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subline)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.notchMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            if let nextEvent {
                Text(nextEvent.shortTime)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.notchAccent)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Mini calendar tile showing the next event's date (or today when there
    /// is nothing upcoming), replacing the plain calendar glyph. The square
    /// scales down when the compact bar is configured shorter than usual so
    /// it never overflows the container.
    private var dateTile: some View {
        let date = nextEvent?.startDate ?? Date()
        let connected = service.accessState == .authorized
        return VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.narrow).locale(AppLocale.chinese)).uppercased())
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                .foregroundStyle(connected ? Color.notchAccent : Color.notchMuted)
            Text(String(Calendar.current.component(.day, from: date)))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 24, maxHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.notchAccent.opacity(connected ? 0.14 : 0.07))
        )
        .accessibilityHidden(true)
    }

    private var headline: String {
        switch service.accessState {
        case .authorized:
            return nextEvent?.title ?? "近期没有日程"
        case .notDetermined:
            return "连接“日历”"
        case .requesting:
            return "正在连接…"
        case .denied, .restricted:
            return "日历访问权限已关闭"
        }
    }

    private var subline: String {
        switch service.accessState {
        case .authorized:
            guard let nextEvent else { return "未来 14 天没有日程" }
            return "\(nextEvent.dayLabel) · \(nextEvent.calendarTitle)"
        case .notDetermined:
            return "点按以授予权限"
        case .requesting:
            return "正在等待授权"
        case .denied, .restricted:
            return "请在“系统设置”中允许访问"
        }
    }

    private var accessibilityText: String {
        if let nextEvent {
            return "下一个日程：\(nextEvent.title)，\(nextEvent.dayLabel) \(nextEvent.shortTime)"
        }
        return "日历：\(headline)，\(subline)"
    }
}
